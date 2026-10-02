// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IImdAttestationVerifier} from "./interfaces/IImdAttestationVerifier.sol";

/// @title Stable IdentityMD Oracle adapter with delayed, versioned codecs
/// @notice Authenticates bound Oracle results without upgrading market custody or this adapter.
/// @dev Governance may add immutable codecs after 48 hours; a malicious codec can lie about which
///      fields its hash authenticates. This is explicitly governed verification, not trustless truth.
///      No delegatecall, token transfers or payout authority. See docs/VERSIONED_ORACLE_ADAPTER.md.
contract VersionedImdOracleAdapter is IOracleAdapter, Ownable2Step {
    /// @dev Published immutable-code binding for an installed version; disabling is permanent.
    struct Verifier {
        address implementation;
        bytes32 codeHash;
        bytes32 schemaHash;
        bool enabled;
    }

    /// @dev Proposed codec frozen until activation or cancellation; replacing a proposal restarts the delay.
    struct Proposal {
        address implementation;
        bytes32 codeHash;
        bytes32 schemaHash;
        uint64 activateAfter;
    }

    error InvalidConfiguration();
    error InvalidProof();
    error WrongQuestion();
    error InvalidSignature();
    error InsufficientQuorum();
    error UnsupportedVersion(uint32 version);
    error VersionAlreadyInstalled(uint32 version);
    error ActivationNotReady();
    error VerifierCodeChanged();

    /// @notice Delay for every codec added after constructor installation; cannot be shortened.
    uint64 public constant ACTIVATION_DELAY = 2 days;
    /// @notice Floor for the signed requested panel size, not a claim that every seat replied.
    uint16 public constant MIN_PANEL_SIZE = 100;
    /// @notice Signed quorum must be at least 67 AND strictly greater than two thirds of panelSize.
    uint16 public constant MIN_QUORUM = 67;
    /// @notice Largest exact JSON/JavaScript integer permitted for source chain and window.
    uint256 public constant MAX_JSON_INTEGER = 9_007_199_254_740_991;
    /// @notice Maximum encoded evidence size; current complete v2 proof is well below this limit.
    uint256 public constant MAX_PROOF_BYTES = 65_536;
    /// @notice Fixed signed definitions, preserved byte-for-byte from the existing adapter.
    string public constant OUTCOME_ENCODING =
        "0=NO;1=YES;2=VOID. Answer the exact question under resolution_rules and the declared observation times. Material contradictions or an unanswerable question mean VOID. Missing evidence alone is not NO.";
    /// @notice Definition used for creators who supplied empty additional rules.
    string public constant DEFAULT_RULES =
        "No additional creator rules; use the exact question and declared observation times.";

    /// @notice Immutable Oracle ECDSA attester; neither the owner nor the relay wallet can replace it.
    address public immutable oracleSigner;
    /// @notice Oracle evidence chain, independent of the chain on which this adapter settles.
    uint256 public immutable sourceChainId;
    /// @notice Commitment to immutable core rules AND the documented delayed-codec governance model.
    bytes32 public immutable override policyHash;
    /// @notice Installed codecs; a nonzero implementation permanently occupies its version number.
    mapping(uint32 version => Verifier) public verifiers;
    /// @notice Pending additions, publicly inspectable throughout the delay.
    mapping(uint32 version => Proposal) public proposals;

    /// @notice A future version was proposed; no proof for it is accepted before activation.
    event VerifierProposed(
        uint32 indexed version,
        address indexed implementation,
        bytes32 codeHash,
        bytes32 schemaHash,
        uint64 activateAfter
    );
    /// @notice A pending addition was cancelled by the owner.
    event VerifierProposalCancelled(uint32 indexed version);
    /// @notice A codec became usable at this stable adapter address.
    event VerifierActivated(
        uint32 indexed version, address indexed implementation, bytes32 codeHash, bytes32 schemaHash
    );
    /// @notice An installed codec was permanently disabled; its version cannot be reused.
    event VerifierDisabled(uint32 indexed version);

    /// @notice Deploy the stable policy and install the reviewed v2 codec immediately.
    /// @param admin Initial governance owner; transfer uses Ownable2Step. Prefer a multisig.
    /// @param signer Immutable trusted final Oracle signer, independent from admin/relayer.
    /// @param sourceChain Positive, exactly representable source chain ID.
    /// @param initialV2 Reviewed immutable ImdAttestationV2 deployment, not a proxy.
    constructor(address admin, address signer, uint256 sourceChain, address initialV2) Ownable(admin) {
        if (signer == address(0) || sourceChain == 0 || sourceChain > MAX_JSON_INTEGER) {
            revert InvalidConfiguration();
        }
        oracleSigner = signer;
        sourceChainId = sourceChain;
        policyHash = keccak256(
            abi.encode(
                "PEPE2PEPE_IMD_GOVERNED_CODECS_V1",
                signer,
                sourceChain,
                ACTIVATION_DELAY,
                MIN_PANEL_SIZE,
                MIN_QUORUM,
                "QUORUM_STRICTLY_GREATER_THAN_TWO_THIRDS",
                "APPEND_ONLY_VERSIONS_PERMANENT_DISABLE_TWO_STEP_OWNER",
                OUTCOME_ENCODING,
                DEFAULT_RULES
            )
        );
        Verifier memory v = _inspect(2, initialV2);
        verifiers[2] = v;
        emit VerifierActivated(2, initialV2, v.codeHash, v.schemaHash);
    }

    /// @notice Explicit proof-envelope capability marker for clients; this is not a signature version.
    function proofFormat() external pure returns (bytes32) {
        return keccak256("PEPE2PEPE_IMD_VERSIONED_PROOF_V1");
    }

    /// @notice Propose a new signature version; cannot replace any previously installed version.
    /// @dev Owner-only. A fresh proposal for an uninstalled version restarts its complete 48-hour delay.
    /// @param version Decimal EIP-712 version; v1 is forbidden because it has no signed quorum fields.
    /// @param implementation Reviewed immutable codec implementing the exact published schema.
    function proposeVerifier(uint32 version, address implementation) external onlyOwner {
        if (verifiers[version].implementation != address(0)) revert VersionAlreadyInstalled(version);
        Verifier memory v = _inspect(version, implementation);
        uint64 eta = uint64(block.timestamp + ACTIVATION_DELAY);
        proposals[version] = Proposal(implementation, v.codeHash, v.schemaHash, eta);
        emit VerifierProposed(version, implementation, v.codeHash, v.schemaHash, eta);
    }

    /// @notice Cancel a pending addition; does not disable any active codec.
    /// @param version Pending signature version to cancel.
    function cancelVerifier(uint32 version) external onlyOwner {
        if (proposals[version].implementation == address(0)) revert UnsupportedVersion(version);
        delete proposals[version];
        emit VerifierProposalCancelled(version);
    }

    /// @notice Activate the exact proposed codec after its delay; anyone may execute this scheduled action.
    /// @dev Rechecks bytecode and schema. This grants no caller settlement or governance privileges.
    /// @param version Proposed signature version whose full delay has elapsed.
    function activateVerifier(uint32 version) external {
        Proposal memory p = proposals[version];
        if (p.implementation == address(0) || block.timestamp < p.activateAfter) revert ActivationNotReady();
        if (verifiers[version].implementation != address(0)) revert VersionAlreadyInstalled(version);
        Verifier memory v = _inspect(version, p.implementation);
        if (v.codeHash != p.codeHash || v.schemaHash != p.schemaHash) revert VerifierCodeChanged();
        delete proposals[version];
        verifiers[version] = v;
        emit VerifierActivated(version, p.implementation, v.codeHash, v.schemaHash);
    }

    /// @notice Immediately and permanently stop accepting a compromised/incorrect codec.
    /// @dev Owner-only emergency action; cannot change any finalized market or recover money directly.
    /// @param version Installed, enabled signature version to disable forever.
    function disableVerifier(uint32 version) external onlyOwner {
        if (!verifiers[version].enabled) revert UnsupportedVersion(version);
        verifiers[version].enabled = false;
        emit VerifierDisabled(version);
    }

    /// @inheritdoc IOracleAdapter
    /// @dev Proof is abi.encode(uint32 version, bytes attestation, string question, string rules,
    ///      string metadataURI, bytes signature). Custody supplies context and current request.
    function verify(
        MarketTypes.OracleContext calldata context,
        MarketTypes.OracleRequest calldata request,
        bytes calldata proof
    ) external view override returns (MarketTypes.Outcome) {
        if (proof.length > MAX_PROOF_BYTES) revert InvalidProof();
        (
            uint32 version,
            bytes memory payload,
            string memory question,
            string memory rules,
            string memory uri,
            bytes memory sig
        ) = abi.decode(proof, (uint32, bytes, string, string, string, bytes));
        (IImdAttestationVerifier.Attestation memory a, bytes32 structHash) = _decode(version, payload);
        if (
            request.requestId == bytes32(0) || a.requestId != request.requestId
                || a.questionHash != request.questionHash || a.chainId != sourceChainId || a.answerType != 3
                || a.answer.length != 32 || a.fromBlock > a.toBlock || a.toBlock > MAX_JSON_INTEGER
                || a.blockHash == bytes32(0) || a.panelJobId == bytes32(0)
                || bytes16(a.panelJobId << 128) != bytes16(0) || bytes16(a.requestId << 128) != bytes16(0)
                || a.issuedAt < context.oracleRequestAt || a.issuedAt > block.timestamp
                || a.expiresAt <= a.issuedAt || a.expiresAt < block.timestamp
        ) revert InvalidProof();
        if (
            a.panelSize < MIN_PANEL_SIZE || a.quorum < MIN_QUORUM || a.quorum > a.panelSize
                || uint256(a.quorum) * 3 <= uint256(a.panelSize) * 2 || a.agreed < a.quorum
                || a.agreed > a.panelSize
        ) revert InsufficientQuorum();
        if (
            keccak256(bytes(question)) != context.questionTextHash
                || keccak256(bytes(rules)) != context.resolutionRulesHash
                || keccak256(bytes(uri)) != context.metadataURIHash
                || keccak256(bytes(questionDocument(context, question, rules, uri, a.fromBlock, a.toBlock)))
                    != a.questionHash
        ) revert WrongQuestion();
        if (ECDSA.recover(_digest(version, structHash), sig) != oracleSigner) revert InvalidSignature();
        uint256 value = abi.decode(a.answer, (uint256));
        if (value > 2) revert InvalidProof();
        return MarketTypes.Outcome(value + 1);
    }

    /// @notice Exact EIP-712 domain separator for this router, current consumer chain and numeric version.
    /// @dev Does not imply that the version is registered or enabled.
    function domainSeparator(uint32 version) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("IdentityMD Oracle"),
                keccak256(bytes(Strings.toString(version))),
                block.chainid,
                address(this)
            )
        );
    }

    /// @notice Hash a supported attestation at this router; does not validate context, quorum or expiry.
    /// @param version Enabled version whose codec decodes the payload.
    /// @param payload ABI-encoded attestation; no market text or signature.
    function attestationDigest(uint32 version, bytes calldata payload) external view returns (bytes32) {
        (, bytes32 structHash) = _decode(version, payload);
        return _digest(version, structHash);
    }

    function _digest(uint32 version, bytes32 structHash) private view returns (bytes32) {
        return keccak256(abi.encodePacked(hex"1901", domainSeparator(version), structHash));
    }

    function _decode(uint32 version, bytes memory payload)
        private
        view
        returns (IImdAttestationVerifier.Attestation memory a, bytes32 structHash)
    {
        Verifier memory v = verifiers[version];
        if (!v.enabled) revert UnsupportedVersion(version);
        if (v.implementation.codehash != v.codeHash) revert VerifierCodeChanged();
        return IImdAttestationVerifier(v.implementation).decodeAndHash(payload);
    }

    function _inspect(uint32 version, address implementation) private view returns (Verifier memory) {
        if (version < 2 || implementation.code.length == 0) revert InvalidConfiguration();
        IImdAttestationVerifier codec = IImdAttestationVerifier(implementation);
        bytes32 schema = codec.schemaHash();
        if (codec.signatureVersion() != version || schema == bytes32(0)) revert InvalidConfiguration();
        return Verifier(implementation, implementation.codehash, schema, true);
    }

    /// @notice Exact canonical JSON for questionDocument() in the existing Oracle API (protocol v1).
    /// @dev Fixed sorted keys and panel evidence; large definition values are decimal strings.
    ///      This builder validates the window but does not authenticate context or check text preimages;
    ///      verify performs those checks and custody validates UTF-8/length during creation.
    /// @param c Immutable market context to commit in the definitions.
    /// @param question Exact funded question; serialized without normalization.
    /// @param rules Exact additional creator rules; empty selects the fixed nonempty DEFAULT_RULES definition.
    /// @dev The fourth argument is retained for caller compatibility but is not included in the public request.
    ///      verify still checks that URI preimage against the market commitment.
    /// @param fromBlock Explicit source-window start used by the recorded Oracle request.
    /// @param toBlock Explicit source-window end, ordered and at most MAX_JSON_INTEGER.
    /// @return Canonical UTF-8 JSON whose keccak256 must equal the Oracle questionHash.
    function questionDocument(
        MarketTypes.OracleContext memory c,
        string memory question,
        string memory rules,
        string memory,
        uint64 fromBlock,
        uint64 toBlock
    ) public view returns (string memory) {
        if (fromBlock > toBlock || toBlock > MAX_JSON_INTEGER) revert InvalidProof();
        string memory definitions = string.concat(
            '{"close_at":"',
            Strings.toString(c.closeAt),
            '","consumer_chain_id":"',
            Strings.toString(block.chainid),
            '","market_contract":"',
            Strings.toHexString(c.marketContract),
            '","market_id":"',
            Strings.toString(c.marketId),
            '","market_terms_hash":"',
            Strings.toHexString(uint256(c.termsHash), 32),
            '","metadata_hash":"',
            Strings.toHexString(uint256(c.metadataHash), 32),
            '","observation_end":"',
            Strings.toString(c.observationEnd),
            '","observation_start":"',
            Strings.toString(c.observationStart),
            '","oracle_request_at":"',
            Strings.toString(c.oracleRequestAt),
            '","outcome_encoding":"',
            OUTCOME_ENCODING,
            '","resolution_rules":"',
            Strings.escapeJSON(bytes(rules).length == 0 ? DEFAULT_RULES : rules),
            '"}'
        );
        return string.concat(
            '{"answerType":"uint256","chainId":',
            Strings.toString(sourceChainId),
            ',"definitions":',
            definitions,
            ',"evidence":"panel","question":"',
            Strings.escapeJSON(question),
            '","v":1,"window":{"fromBlock":',
            Strings.toString(fromBlock),
            ',"toBlock":',
            Strings.toString(toBlock),
            "}}"
        );
    }
}
