// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IImdAttestationVerifier} from "./interfaces/IImdAttestationVerifier.sol";

/// @title IdentityMD Oracle EIP-712 version 2 codec
/// @notice Stateless, immutable decoding/hashing for signatures that bind panelSize, quorum and agreed.
/// @dev Holds no funds, permissions, signer or domain. The calling adapter supplies its own domain
///      and validates the recovered signer and all common fields. This contract is not a proxy.
contract ImdAttestationV2 is IImdAttestationVerifier {
    /// @notice Exact deployed IdentityMD version 2 signed schema; field order is significant.
    bytes32 public constant TYPE_HASH = keccak256(
        "OracleAttestation(bytes32 requestId,uint256 chainId,bytes32 questionHash,uint8 answerType,bytes answer,uint256 figure,uint64 fromBlock,uint64 toBlock,bytes32 blockHash,bytes32 panelJobId,uint16 panelSize,uint16 quorum,uint16 agreed,uint64 issuedAt,uint64 expiresAt)"
    );

    /// @inheritdoc IImdAttestationVerifier
    function signatureVersion() external pure returns (uint32) {
        return 2;
    }

    /// @inheritdoc IImdAttestationVerifier
    function schemaHash() external pure returns (bytes32) {
        return TYPE_HASH;
    }

    /// @inheritdoc IImdAttestationVerifier
    function decodeAndHash(bytes calldata payload)
        external
        pure
        returns (Attestation memory a, bytes32 structHash)
    {
        a = abi.decode(payload, (Attestation));
        structHash = keccak256(
            abi.encode(
                TYPE_HASH,
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
                a.panelSize,
                a.quorum,
                a.agreed,
                a.issuedAt,
                a.expiresAt
            )
        );
    }
}
