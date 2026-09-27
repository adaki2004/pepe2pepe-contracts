// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @title Shared Pepediction market data
/// @notice ABI types used by custody, Oracle adapters and FE/BE clients.
/// @dev Money is denominated in the market asset's atomic units; times are Unix seconds.
///      Array index 0 means NO and index 1 means YES. These are accounting positions, not tokens.
library MarketTypes {
    /// @dev Tradable sides: No=0, Yes=1.
    enum Side {
        No,
        Yes
    }
    /// @dev Stored states: Unresolved=0, No=1, Yes=2, Void=3.
    ///      The Oracle wire uses 0=NO, 1=YES, 2=VOID; the adapter adds one.
    enum Outcome {
        Unresolved,
        No,
        Yes,
        Void
    }
    /// @dev Oracle=1, emergency cancellation=2, discretionary operator outcome=3.
    enum FinalizationKind {
        None,
        Oracle,
        Emergency,
        Operator
    }

    /// @dev Current global financial beneficiaries. These addresses do not grant operational roles.
    ///      EOAs or contracts such as a treasury multisig may be used. Addresses may coincide.
    struct Recipients {
        /// @dev Protocol treasury receiving its configured fee share plus fee-allocation rounding dust.
        address platform;
        /// @dev Reward distributor receiving its configured fee share for onward Oracle-worker rewards.
        ///      Distribution is external; this address is not necessarily the Oracle signer.
        address oracleDistributor;
        /// @dev Operator receiving its configured fee share for IMD burning or other-asset buybacks.
        ///      The market pays this address but does not execute or verify the burn/buyback.
        address burnBuyback;
        /// @dev Reserved destination retained in the shared ABI; FIFO V1 has no protocol seed.
        address seedReserve;
        /// @dev Service beneficiary fixed per market; earns its credit once at the first match.
        ///      The creator recovers the whole service escrow if there are no matches by STOP.
        ///      Initially granted SETTLEMENT_ROLE; later recipient updates do not grant roles.
        address settlementInitiator;
        /// @dev Receives the configured infrastructure share for hosting, RPC and databases.
        address infrastructureCost;
    }

    /// @dev Basis points of the collected trading fee, not basis points of the gross trade.
    ///      All five fields must sum to 10,000. Updated shares apply to subsequent trades in all
    ///      markets; earlier beneficiary credits remain unchanged. Allocation dust goes to platform.
    struct FeeSplit {
        uint16 platform;
        uint16 oracleDistributor;
        uint16 burnBuyback;
        uint16 creator;
        uint16 infrastructureCost;
    }

    /// @dev Administrator's versioned defaults for future markets in a collateral asset.
    struct AssetConfig {
        /// @dev Whether new markets may use this asset; false does not disable existing markets.
        bool enabled;
        /// @dev Monotonically increasing version checked against the creator's expected version.
        uint64 version;
        /// @dev Must be zero; retained only for shared configuration ABI compatibility.
        uint256 seedAmount;
        /// @dev Refundable service escrow, released on first match; zero is allowed.
        uint256 serviceFee;
        /// @dev Minimum net deposit for creation, same-side backing and opposing bets; at least two atomic units.
        uint256 minTrade;
        /// @dev Maximum fully matched exposure of all offered lots (both sides), bounded to uint128.
        uint256 maxPool;
    }

    /// @dev Creator-confirmed terms. Exact text is emitted and hashed; no post-funding edits are allowed.
    struct CreateParams {
        /// @dev Selected NFT for an optional home-chain creator discount; otherwise type(uint256).max.
        uint256 tokenId;
        /// @dev Allowlisted collateral; address(0) denotes native ETH.
        address asset;
        /// @dev STOP: no further backing or bets; unused ticket refunds become available.
        uint64 closeAt;
        /// @dev Earliest request/finalization/emergency time, no later than 60 days after creation.
        uint64 oracleRequestAt;
        /// @dev Beginning of the fact's observation interval; may equal observationEnd for a snapshot.
        uint64 observationStart;
        /// @dev End of observation, no later than oracleRequestAt; not an Oracle response deadline.
        uint64 observationEnd;
        /// @dev Asset configuration version the creator accepted in its transaction preview.
        uint64 expectedAssetVersion;
        /// @dev Adapter/recipient configuration version the creator accepted.
        uint64 expectedPlatformVersion;
        /// @dev Maximum creator collateral + fee reserve + service escrow; excludes chain gas.
        uint256 maxCreationCost;
        /// @dev Nonzero commitment to published creation metadata; backend verifies the referenced bytes.
        bytes32 metadataHash;
        /// @dev Durable creation-metadata reference, valid UTF-8 and at most 512 bytes.
        string metadataURI;
        /// @dev Exact nonempty UTF-8 question, at most 2,000 UTF-16 code units.
        string question;
        /// @dev Exact additional UTF-8 rules, at most 512 UTF-16 code units; empty is permitted.
        string resolutionRules;
    }

    /// @dev Immutable terms plus mutable accounting/finalization. All quantities exclude paid fees
    ///      unless a field explicitly describes fees. Backing ownership lives in separate FIFO tickets.
    struct Market {
        /// @dev Optional discount NFT; type(uint256).max for public creation. No active NFT slot lock.
        uint256 tokenId;
        /// @dev Original creating wallet and permanent recipient of this market's creator fee share.
        address creator;
        /// @dev Collateral token fixed at creation.
        address asset;
        /// @dev Adapter fixed at creation; future platform configuration does not replace it.
        address oracleAdapter;
        /// @dev Exclusive upper bound on trading time.
        uint64 closeAt;
        /// @dev Inclusive lower bound on requesting/finalizing; not a response timeout.
        uint64 oracleRequestAt;
        /// @dev Committed observation start, independent of the trading STOP.
        uint64 observationStart;
        /// @dev Committed observation end, no later than the Oracle request time.
        uint64 observationEnd;
        /// @dev Asset configuration version accepted at creation.
        uint64 assetVersion;
        /// @dev Platform configuration version accepted at creation; current recipients may change.
        uint64 platformVersion;
        /// @dev keccak256 of the complete ordered ABI-encoded creation commitment.
        bytes32 termsHash;
        /// @dev keccak256 of the question's exact UTF-8 bytes.
        bytes32 questionTextHash;
        /// @dev keccak256 of the creator's exact rules, including an empty string if supplied.
        bytes32 resolutionRulesHash;
        /// @dev Creator's nonzero published metadata commitment.
        bytes32 metadataHash;
        /// @dev keccak256 of the exact creation metadata URI bytes.
        bytes32 metadataURIHash;
        /// @dev Adapter's policy commitment snapshotted at creation.
        bytes32 oraclePolicyHash;
        /// @dev Current global destinations at read time; not immutable market terms.
        ///      Already accrued fee/service credits retain their original beneficiary.
        Recipients recipients;
        /// @dev Always zero in FIFO V1; retained for shared view ABI compatibility.
        uint256 seedPerSide;
        /// @dev Creation service escrow; getOffer.serviceReleased records whether it was earned at first match.
        uint256 serviceFee;
        /// @dev Snapshotted minimum net deposit; not a fee or a withdrawal floor.
        uint256 minTrade;
        /// @dev Current total net pool limit. Starts at the creation snapshot; admin may only raise it
        ///      before STOP. The creation commitment still records the original limit.
        uint256 maxPool;
        /// @dev NO/YES matched stakes only; excludes unused backing and is never reduced by claims.
        uint256[2] pools;
        /// @dev Matched collateral remaining for final claims, excluding unused backing and reserves.
        uint256 poolRemaining;
        /// @dev Derived sum of matched pools after finalization; zero while unresolved.
        uint256 frozenPool;
        /// @dev Derived winning-side matched pool after YES/NO finalization; zero otherwise.
        uint256 frozenWinningPool;
        /// @dev Derived remaining winning stake; exact lots leave no payout rounding dust. Zero for VOID.
        uint256 remainingWinningStake;
        /// @dev Zero while unresolved, then one irreversible terminal outcome.
        Outcome outcome;
        /// @dev Public record of ordinary Oracle versus emergency finalization.
        FinalizationKind finalizationKind;
        /// @dev Always false; FIFO V1 has no protocol seed entitlement.
        bool seedClaimed;
    }

    /// @dev Opposite-side wallet accounting; same-side participants use FIFO tickets instead.
    struct Position {
        /// @dev Matched opposite-side net stake, retained as a historical value after claim.
        uint256[2] stakes;
        /// @dev Consumes the opposite-side wallet payout or VOID refund; prevents duplicate claims.
        bool claimed;
    }

    /// @dev Current external request after Ask Oracle; emergency replacement preserves questionHash.
    struct OracleRequest {
        /// @dev Nonzero Oracle UUID, sixteen bytes left-aligned in bytes32.
        bytes32 requestId;
        /// @dev keccak256 of the exact canonical Oracle question document, including fixed definitions.
        bytes32 questionHash;
        /// @dev Commitment to request/evidence metadata; distinct from the market's creation metadata.
        bytes32 metadataHash;
    }

    /// @dev Trusted immutable market context passed by custody to the adapter for signed-question binding.
    struct OracleContext {
        /// @dev Consumer custody contract; the EIP-712 verifyingContract is separately the adapter.
        address marketContract;
        /// @dev Market identifier within that custody contract.
        uint256 marketId;
        /// @dev Complete ABI-encoded creation commitment.
        bytes32 termsHash;
        /// @dev Commitment to exact question bytes.
        bytes32 questionTextHash;
        /// @dev Commitment to exact creator rules, before any fixed empty-rules default.
        bytes32 resolutionRulesHash;
        /// @dev Creation metadata commitment; not request/evidence metadata.
        bytes32 metadataHash;
        /// @dev Commitment to the exact creation metadata URI.
        bytes32 metadataURIHash;
        /// @dev Trading STOP bound into the signed definitions.
        uint64 closeAt;
        /// @dev Earliest Oracle request and acceptable attestation issuance time.
        uint64 oracleRequestAt;
        /// @dev Beginning of the committed observation.
        uint64 observationStart;
        /// @dev End of the committed observation.
        uint64 observationEnd;
    }
}
