// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Version-specific IdentityMD attestation decoding
/// @notice A read-only codec; the stable adapter checks market binding, quorum and the signer.
/// @dev Every returned field MUST be authenticated by structHash. Registering a dishonest codec
///      can falsify that relationship, so codec registration remains a delayed governance trust.
interface IImdAttestationVerifier {
    /// @dev Common authenticated fields required by every supported wire version.
    struct Attestation {
        bytes32 requestId;
        uint256 chainId;
        bytes32 questionHash;
        uint8 answerType;
        bytes answer;
        uint256 figure;
        uint64 fromBlock;
        uint64 toBlock;
        bytes32 blockHash;
        bytes32 panelJobId;
        uint16 panelSize;
        uint16 quorum;
        uint16 agreed;
        uint64 issuedAt;
        uint64 expiresAt;
    }

    /// @notice Numeric EIP-712 domain version this codec implements.
    function signatureVersion() external pure returns (uint32);

    /// @notice EIP-712 type hash identifying the exact schema implemented by this codec.
    function schemaHash() external pure returns (bytes32);

    /// @notice Decode exact wire fields and hash their EIP-712 struct, excluding the domain/signature.
    /// @param payload ABI-encoded version-specific attestation, without market text or signature.
    /// @return attestation Common fields authenticated by the returned struct hash.
    /// @return structHash EIP-712 struct hash including ALL version-specific signed fields.
    function decodeAndHash(bytes calldata payload)
        external
        view
        returns (Attestation memory attestation, bytes32 structHash);
}
