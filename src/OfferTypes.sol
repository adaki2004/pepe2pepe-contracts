// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {MarketTypes} from "./MarketTypes.sol";

/// @title Fully funded fixed-odds offer records
/// @notice Amounts are exact collateral units. Fees are additional to at-risk stake.
library OfferTypes {
    /// @dev Opposite-side bettors have one aggregate stake and one final claim, packed together.
    struct TakerPosition {
        uint128 stake;
        bool claimed;
    }

    /// @dev Packed immutable funding ticket. Endpoints count exact maker lots, not token amounts.
    ///      Flags: bit 0 = unused refund consumed; bit 1 = final matched entitlement consumed.
    struct Ticket {
        address owner;
        uint16 feeBps;
        uint8 flags;
        uint128 end;
        uint128 fullFeePrefix;
    }

    /// @dev One slot per non-creator backer/refunding wallet. The principal is cumulative unused
    ///      collateral already refunded, making the unmatched fee cap independent of claim order.
    struct WalletRefund {
        uint128 principal;
        bool backer;
    }

    /// @dev Private accounting, separate from the ABI view. No per-match writes to every ticket,
    ///      available collateral, total posted collateral or cumulative earned maker fees.
    struct Book {
        address serviceRecipient;
        uint16 makerProbabilityBps;
        uint16 makerFeeBps;
        uint16 creationTradingFeeBps;
        uint16 unmatchedFeeBps;
        MarketTypes.Side makerSide;
        bool holderDiscount;
        bool serviceReleased;
        uint128 unmatchedFeeCap;
        uint128 totalFeeReserve;
        uint128 returnedCollateral;
        uint128 consumedFeeReserve;
        Ticket[] tickets;
        mapping(address => WalletRefund) wallets;
    }

    /// @notice One owned contribution, including its current match/refund/claim state.
    struct Backing {
        address owner;
        uint16 feeBps;
        uint256 startLot;
        uint256 endLot;
        uint256 collateral;
        uint256 matchedCollateral;
        uint256 feeReserve;
        uint256 matchedFee;
        bool unusedClaimed;
        bool winningClaimed;
    }

    /// @dev Immutable creator-selected offer economics, committed with the existing question terms.
    struct CreateOffer {
        MarketTypes.Side makerSide;
        /// @dev Implied probability of makerSide, 1..9999 basis points; not an objective probability.
        uint16 makerProbabilityBps;
        uint256 makerCollateral;
        /// @dev Opt in to NFT ownership validation; false permits creation without an NFT.
        bool holderDiscount;
    }

    /// @dev Offer-only state; getMarket retains common terms, matched pools and settlement context.
    struct Offer {
        MarketTypes.Side makerSide;
        uint16 makerProbabilityBps;
        uint16 makerFeeBps;
        /// @dev Historical ordinary rate at creation, not the current rate for a new taker deposit.
        uint16 creationTradingFeeBps;
        uint16 unmatchedFeeBps;
        bool holderDiscount;
        bool unusedReturned;
        bool closedUnmatched;
        bool serviceReleased;
        /// @dev Fixed recipient earning service credit at the first match; never at creation.
        address serviceRecipient;
        uint256 makerAvailable;
        uint256 makerFeeReserve;
        /// @dev View-only totals derived from getMarket pools; not independently written to storage.
        uint256 matchedMaker;
        uint256 matchedTaker;
        uint256 makerFeesPaid;
        uint256 totalMakerPosted;
        uint256 unmatchedFeeCap;
        /// @dev Append-only contribution count; ticket 0 belongs to the original creator.
        uint256 backingCount;
    }
}
