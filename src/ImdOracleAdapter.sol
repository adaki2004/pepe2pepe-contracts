// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";

/// @title IdentityMD panel-result adapter for Pepediction
/// @notice Verify an existing IdentityMD v1 final attestation against exact funded market terms.
/// @dev Panel agents contribute answers/evidence; this adapter authenticates one configured final signer.
///      It does not verify independent worker signatures, executed quorum, source truth or dispute resolution.
///      Consumer EIP-712 domain is this adapter on its deployed chain, not the custody contract address.
contract ImdOracleAdapter is EIP712, IOracleAdapter {
    /// @dev Existing IdentityMD v1 wire message. Field order/types must match ATTESTATION_TYPEHASH exactly.
    struct Attestation {
        /// @dev Nonzero request UUID encoded as sixteen raw bytes left-aligned in bytes32.
        bytes32 requestId;
        /// @dev Source chain, which may differ from the EIP-712 consumer chain.
        uint256 chainId;
        /// @dev keccak256 of the canonical question document, including fixed Pepediction definitions.
        bytes32 questionHash;
        /// @dev Existing Oracle type code; this adapter requires 3, meaning uint256.
        uint8 answerType;
        /// @dev Exactly one ABI word encoding 0=NO, 1=YES or 2=VOID.
        bytes answer;
        /// @dev Ancillary signed numeric figure; not used to determine the market outcome.
        uint256 figure;
        /// @dev Inclusive source-window start block, bounded to an exactly representable JSON integer.
        uint64 fromBlock;
        /// @dev Inclusive source-window end block, at or after fromBlock.
        uint64 toBlock;
        /// @dev Nonzero signed block context; not independently reproduced as a panel fact on-chain.
        bytes32 blockHash;
        /// @dev Nonzero panel-job UUID, encoded with the same left alignment as requestId.
        bytes32 panelJobId;
        /// @dev Signature issuance Unix time, no earlier than Ask Oracle and no later than the current block.
        uint64 issuedAt;
        /// @dev Inclusive last valid Unix time for this proof; does not expire the market itself.
        uint64 expiresAt;
    }

    /// @notice Signer is zero or the source chain is outside the supported positive JSON integer range.
    error InvalidConfiguration();
    /// @notice Request, wire fields, temporal validity, window or outcome encoding is invalid.
    error InvalidProof();
    /// @notice Exact text/context does not reconstruct the market's expected signed question.
    error WrongQuestion();
    /// @notice The recovered ECDSA signer is not the immutable trusted Oracle attester.
    /// @dev Malformed signatures may instead revert with OpenZeppelin ECDSA errors.
    error InvalidSignature();

    /// @notice EIP-712 struct type hash for the existing IdentityMD v1 attestation message.
    bytes32 public constant ATTESTATION_TYPEHASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint64 issuedAt,uint64 expiresAt)"
    );
    /// @notice Largest integer that survives JSON/JavaScript number encoding without precision loss.
    uint256 public constant MAX_JSON_INTEGER = 9_007_199_254_740_991;
    /// @notice Fixed signed instructions specifying outcome encoding and semantic invalidity.
    /// @dev Instructions bind meaning but do not cryptographically prove that the panel followed them.
    string public constant OUTCOME_ENCODING =
        "0=NO;1=YES;2=VOID. Answer the exact question under resolution_rules and the declared observation times. Material contradictions or an unanswerable question mean VOID. Missing evidence alone is not NO.";
    /// @notice Nonempty Oracle definition used when the creator supplied no additional rules.
    /// @dev The market's original rules hash still commits to the creator's empty string.
    string public constant DEFAULT_RULES =
        "No additional creator rules; use the exact question and declared observation times.";

    /// @notice Trusted final ECDSA attester, not the request initiator, transaction relayer or reward distributor.
    address public immutable oracleSigner;
    /// @notice Source chain committed in the Oracle message/document; consumer chain is block.chainid.
    uint256 public immutable sourceChainId;
    /// @notice Immutable commitment to adapter version, signer, source chain and fixed outcome/rules text.
    bytes32 public immutable override policyHash;

    /// @notice Deploy an immutable verification policy for current and future referencing markets.
    /// @dev Uses EIP-712 name "IdentityMD Oracle", version "1" and this adapter as verifyingContract.
    ///      Supports direct ECDSA recovery, not a mutable ERC1271 signer registry.
    /// @param signer Independently configured nonzero Oracle attester address; not trusted merely from an API.
    /// @param sourceChain Positive source chain ID at most MAX_JSON_INTEGER.
    constructor(address signer, uint256 sourceChain) EIP712("IdentityMD Oracle", "1") {
        if (signer == address(0) || sourceChain == 0 || sourceChain > MAX_JSON_INTEGER) {
            revert InvalidConfiguration();
        }
        oracleSigner = signer;
        sourceChainId = sourceChain;
        policyHash = keccak256(
            abi.encode(
                "PEPEDICTION_IMD_PANEL_V2_NO_URI", signer, sourceChain, OUTCOME_ENCODING, DEFAULT_RULES
            )
        );
    }

    /// @notice Authenticate one NO, YES or VOID result for the supplied market and canonical request.
    /// @dev Proof is abi.encode(Attestation, exactQuestion, exactRules, exactMetadataURI, signature).
    ///      Exact text commitments, reconstructed question hash, UUID/window/time validity and ECDSA domain
    ///      are checked. This view does not consume the request; custody enforces terminal replay protection.
    ///      Context must come from the intended custody contract; a successful standalone view is not finalization.
    /// @param context Immutable market terms read by the custody contract.
    /// @param request Current external request recorded by custody; a replaced UUID is no longer valid.
    /// @param proof Existing final Oracle attestation plus its signature and exact committed text preimages.
    /// @return Stored Outcome.No, Outcome.Yes or Outcome.Void, translating wire values by adding one.
    function verify(
        MarketTypes.OracleContext calldata context,
        MarketTypes.OracleRequest calldata request,
        bytes calldata proof
    ) external view override returns (MarketTypes.Outcome) {
        (
            Attestation memory a,
            string memory question,
            string memory rules,
            string memory uri,
            bytes memory sig
        ) = abi.decode(proof, (Attestation, string, string, string, bytes));
        if (
            request.requestId == bytes32(0) || a.requestId != request.requestId
                || a.questionHash != request.questionHash || a.chainId != sourceChainId || a.answerType != 3
                || a.answer.length != 32 || a.fromBlock > a.toBlock || a.toBlock > MAX_JSON_INTEGER
                || a.blockHash == bytes32(0) || a.panelJobId == bytes32(0)
                || bytes16(a.panelJobId << 128) != bytes16(0) || a.issuedAt < context.oracleRequestAt
                || a.issuedAt > block.timestamp || a.expiresAt < a.issuedAt || a.expiresAt < block.timestamp
                || bytes16(a.requestId << 128) != bytes16(0)
        ) revert InvalidProof();
        if (
            keccak256(bytes(question)) != context.questionTextHash
                || keccak256(bytes(rules)) != context.resolutionRulesHash
                || keccak256(bytes(uri)) != context.metadataURIHash
                || keccak256(bytes(questionDocument(context, question, rules, uri, a.fromBlock, a.toBlock)))
                    != a.questionHash
        ) revert WrongQuestion();
        if (ECDSA.recover(attestationDigest(a), sig) != oracleSigner) revert InvalidSignature();
        uint256 value = abi.decode(a.answer, (uint256));
        if (value > 2) revert InvalidProof();
        return MarketTypes.Outcome(value + 1);
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

    /// @notice Calculate the exact EIP-712 digest signed for this deployed adapter and consumer chain.
    /// @dev Hashing does not validate fields, signature, expiry or market binding; call verify for those checks.
    /// @param a Existing IdentityMD attestation with dynamic answer bytes hashed according to EIP-712.
    /// @return Domain-separated signing digest; excludes the signature itself.
    function attestationDigest(Attestation memory a) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ATTESTATION_TYPEHASH,
                    a.requestId,
                    a.chainId,
                    a.questionHash,
                    a.answerType,
                    keccak256(a.answer),
                    a.figure,
                    a.fromBlock,
                    a.toBlock,
                    a.blockHash,
                    a.panelJobId,
                    a.issuedAt,
                    a.expiresAt
                )
            )
        );
    }
}
