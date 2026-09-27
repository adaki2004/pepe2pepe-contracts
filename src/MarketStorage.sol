// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MarketTypes} from "./MarketTypes.sol";

/// @title Packed internal storage for FIFO fixed-odds custody
/// @notice Public ABI records remain MarketTypes.Market; this layout is not an upgrade layout.
/// @dev Funded economics and Oracle policy stay per market; protocol recipients are global.
library MarketStorage {
    /// @dev Monetary fields use checked uint128 bounds; asset configuration rejects larger limits.
    ///      NFT IDs keep their full width. Dates and flags share slots with addresses.
    struct Market {
        address creator;
        uint64 closeAt;
        MarketTypes.Outcome outcome;
        MarketTypes.FinalizationKind finalizationKind;
        address asset;
        uint64 assetVersion;
        address oracleAdapter;
        uint256 tokenId;
        uint64 oracleRequestAt;
        uint64 observationStart;
        uint64 observationEnd;
        uint64 platformVersion;
        bytes32 termsHash;
        bytes32 questionTextHash;
        bytes32 resolutionRulesHash;
        bytes32 metadataHash;
        bytes32 metadataURIHash;
        // Read from the adapter on each creation, preserving mutable-adapter semantics.
        bytes32 oraclePolicyHash;
        uint128 serviceFee;
        uint128 poolRemaining;
        uint128 minTrade;
        uint128 maxPool;
        uint128[2] pools;
        // Frozen totals/remaining winning stake are derived from immutable matched pools.
    }
}
