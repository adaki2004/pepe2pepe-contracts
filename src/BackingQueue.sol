// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {OfferSupport} from "./OfferSupport.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {OfferTypes as O} from "./OfferTypes.sol";
import {MarketTypes as T} from "./MarketTypes.sol";
import {MarketStorage} from "./MarketStorage.sol";
import {FixedOddsMath} from "./FixedOddsMath.sol";

/// @title Append-only FIFO backing accounting
/// @notice Immutable linked code; runs only against the calling market's storage under its guard.
/// @dev Matching advances a prefix implicit in the market's maker pool. It never iterates over
///      filled owners. A ticket can be refunded/claimed independently of preceding tickets.
library BackingQueue {
    using SafeCast for uint256;

    error InvalidLot();
    error AmountTooSmall();
    error PoolCapExceeded();
    error BackingNotFound();
    error AlreadyClaimed();
    error NothingToClaim();
    error NoCapacity();
    error NoEarlyExit();
    error TooManyBackings();

    /// @notice New ownership and queue position, enough to index without a per-deposit RPC read.
    event BackingAdded(
        uint256 indexed marketId,
        uint256 indexed backingId,
        address indexed owner,
        uint256 collateral,
        uint256 feeReserve,
        uint16 feeBps,
        uint256 startLot,
        uint256 endLot,
        uint256 fullFeePrefix
    );

    event BackingRefunded(
        uint256 indexed marketId,
        uint256 indexed backingId,
        address indexed owner,
        uint256 collateral,
        uint256 feeReserveRefund,
        uint256 unmatchedFee,
        uint256 serviceRefund,
        uint64 feeVersion
    );

    /// @notice Quote one new opposite-side deposit at current taker and ticket-specific maker rates.
    function quoteMatch(O.Book storage o, MarketStorage.Market storage m, uint256 stake, uint16 rate)
        external
        view
        returns (
            uint256 maker,
            uint256 takerFee,
            uint256 makerFee,
            uint256 debit,
            uint256 payout,
            uint256 remainingAvailable,
            uint256 remainingReserve
        )
    {
        (uint256 a, uint256 b) = lots(o.makerProbabilityBps);
        if (stake < m.minTrade) revert AmountTooSmall();
        if (stake % b != 0) revert InvalidLot();
        maker = stake / b * a;
        uint256 matched = m.pools[uint256(o.makerSide)];
        uint256 available = uint256(o.tickets[o.tickets.length - 1].end) * a - matched - o.returnedCollateral;
        if (maker == 0 || maker > available) revert NoCapacity();
        takerFee = FixedOddsMath.fee(stake, rate);
        uint256 cumulativeFee = feeThrough(o, (matched + maker) / a, a);
        makerFee = cumulativeFee - feeThrough(o, matched / a, a);
        debit = stake + takerFee;
        payout = stake + maker;
        remainingAvailable = available - maker;
        remainingReserve = uint256(o.totalFeeReserve) - cumulativeFee - o.consumedFeeReserve;
    }

    /// @notice Consume and pay one unused ticket while the caller's reentrancy guard is held.
    function refundAndPay(
        O.Book storage o,
        MarketStorage.Market storage m,
        uint256 id,
        uint256 index,
        mapping(address => mapping(address => uint256)) storage credits,
        mapping(address => uint256) storage liability,
        address infrastructure,
        uint64 version
    ) external returns (uint256 amount) {
        if (block.timestamp < m.closeAt) revert NoEarlyExit();
        (O.Backing memory v, uint256 fee, uint256 reserveRefund, uint256 serviceRefund) = refund(o, m, index);
        uint256 unused = v.collateral - v.matchedCollateral;
        if (fee != 0) credits[m.asset][infrastructure] += fee;
        amount = unused + reserveRefund + serviceRefund;
        if (amount != 0) OfferSupport.pay(liability, m.asset, v.owner, amount);
        emit BackingRefunded(id, index, v.owner, unused, reserveRefund, fee, serviceRefund, version);
    }

    /// @notice Reduce an implied price to exact atomic-unit maker/taker lots.
    function lots(uint16 probability) internal pure returns (uint256 a, uint256 b) {
        uint256 x = probability;
        uint256 y = 10_000 - probability;
        a = x;
        b = y;
        while (b != 0) {
            uint256 r = a % b;
            a = b;
            b = r;
        }
        return (x / a, y / a);
    }

    /// @notice Append at the tail; a returning wallet never inherits its earlier priority.
    /// @dev Funding/side/STOP checks and exact token movement belong to custody. Explicit casts
    ///      bound packed values; maxPool covers the full maker+taker exposure of all tickets.
    function append(
        O.Book storage o,
        MarketStorage.Market storage m,
        uint256 id,
        address owner,
        uint256 collateral,
        uint16 rate
    ) external returns (uint256 reserve) {
        (uint256 a, uint256 b) = lots(o.makerProbabilityBps);
        if (collateral % a != 0) revert InvalidLot();
        uint256 index = o.tickets.length;
        if (index >= 50) revert TooManyBackings();
        uint256 start = index == 0 ? 0 : o.tickets[index - 1].end;
        uint256 end = start + collateral / a;
        if (end > uint256(m.maxPool) / (a + b)) revert PoolCapExceeded();
        if ((end - uint256(m.pools[uint256(o.makerSide)]) / a) * b < m.minTrade) revert AmountTooSmall();
        uint256 fullFee = FixedOddsMath.fee(collateral, rate);
        reserve = fullFee + Math.min(FixedOddsMath.fee(collateral, o.unmatchedFeeBps), o.unmatchedFeeCap);
        uint256 prefix = fullFee + (index == 0 ? 0 : o.tickets[index - 1].fullFeePrefix);
        o.tickets.push(O.Ticket(owner, rate, 0, end.toUint128(), prefix.toUint128()));
        o.totalFeeReserve = (uint256(o.totalFeeReserve) + reserve).toUint128();
        if (owner != m.creator) o.wallets[owner].backer = true;
        emit BackingAdded(id, index, owner, collateral, reserve, rate, start, end, prefix);
    }

    /// @notice Cumulative earned maker fees at a matched-lot prefix, O(log ticket count).
    /// @dev Each partial ticket is rounded once cumulatively, never once per taker fill.
    function feeThrough(O.Book storage o, uint256 filled, uint256 a) public view returns (uint256) {
        if (filled == 0) return 0;
        uint256 lo;
        uint256 hi = o.tickets.length;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (o.tickets[mid].end < filled) lo = mid + 1;
            else hi = mid;
        }
        if (lo == o.tickets.length) revert PoolCapExceeded();
        uint256 start = lo == 0 ? 0 : o.tickets[lo - 1].end;
        uint256 prefix = lo == 0 ? 0 : o.tickets[lo - 1].fullFeePrefix;
        return prefix + FixedOddsMath.fee((filled - start) * a, o.tickets[lo].feeBps);
    }

    /// @notice Return one ticket's bounded view without scanning any other owner's positions.
    function backing(O.Book storage o, uint256 index, uint256 matchedMaker)
        public
        view
        returns (O.Backing memory v)
    {
        if (index >= o.tickets.length) revert BackingNotFound();
        O.Ticket storage t = o.tickets[index];
        (uint256 a,) = lots(o.makerProbabilityBps);
        uint256 start = index == 0 ? 0 : o.tickets[index - 1].end;
        uint256 filled = matchedMaker / a;
        uint256 matchedLots = filled <= start ? 0 : Math.min(filled, t.end) - start;
        uint256 collateral = (uint256(t.end) - start) * a;
        v = O.Backing({
            owner: t.owner,
            feeBps: t.feeBps,
            startLot: start,
            endLot: t.end,
            collateral: collateral,
            matchedCollateral: matchedLots * a,
            feeReserve: FixedOddsMath.fee(collateral, t.feeBps)
                + Math.min(FixedOddsMath.fee(collateral, o.unmatchedFeeBps), o.unmatchedFeeCap),
            matchedFee: FixedOddsMath.fee(matchedLots * a, t.feeBps),
            unusedClaimed: t.flags & 1 != 0,
            winningClaimed: t.flags & 2 != 0
        });
    }

    /// @notice Compute the aggregate ABI view from minimal private storage and matched pools.
    function offer(O.Book storage o, MarketStorage.Market storage m)
        external
        view
        returns (O.Offer memory v)
    {
        (uint256 a,) = lots(o.makerProbabilityBps);
        v.makerSide = o.makerSide;
        v.makerProbabilityBps = o.makerProbabilityBps;
        v.makerFeeBps = o.makerFeeBps;
        v.creationTradingFeeBps = o.creationTradingFeeBps;
        v.unmatchedFeeBps = o.unmatchedFeeBps;
        v.holderDiscount = o.holderDiscount;
        v.serviceReleased = o.serviceReleased;
        v.serviceRecipient = o.serviceRecipient;
        v.backingCount = o.tickets.length;
        v.totalMakerPosted = uint256(o.tickets[v.backingCount - 1].end) * a;
        v.matchedMaker = m.pools[uint256(o.makerSide)];
        v.matchedTaker = m.pools[1 - uint256(o.makerSide)];
        v.makerAvailable = v.totalMakerPosted - v.matchedMaker - o.returnedCollateral;
        v.makerFeesPaid = feeThrough(o, v.matchedMaker / a, a);
        v.makerFeeReserve = uint256(o.totalFeeReserve) - v.makerFeesPaid - o.consumedFeeReserve;
        v.unmatchedFeeCap = o.unmatchedFeeCap;
        v.closedUnmatched = block.timestamp >= m.closeAt && v.matchedMaker == 0;
        v.unusedReturned = v.makerAvailable == 0 && v.makerFeeReserve == 0
            && (v.serviceReleased || o.tickets[0].flags & 1 != 0);
    }

    /// @notice Consume one unused entitlement. Caller enforces STOP, accrues unmatched credit and pays owner.
    /// @return v Ticket snapshot before consumption.
    /// @return fee Incremental capped unmatched fee across this wallet's refunded principal.
    /// @return reserveRefund Remaining ticket reserve less this fee.
    /// @return serviceRefund Creator's full service escrow only for ticket zero and globally no matches.
    function refund(O.Book storage o, MarketStorage.Market storage m, uint256 index)
        private
        returns (O.Backing memory v, uint256 fee, uint256 reserveRefund, uint256 serviceRefund)
    {
        v = backing(o, index, m.pools[uint256(o.makerSide)]);
        if (v.unusedClaimed) revert AlreadyClaimed();
        o.tickets[index].flags |= 1;
        uint256 unused = v.collateral - v.matchedCollateral;
        uint256 previous = o.wallets[v.owner].principal;
        if (unused != 0) {
            o.wallets[v.owner].principal = (previous + unused).toUint128();
            fee = Math.min(FixedOddsMath.fee(previous + unused, o.unmatchedFeeBps), o.unmatchedFeeCap)
                - Math.min(FixedOddsMath.fee(previous, o.unmatchedFeeBps), o.unmatchedFeeCap);
        }
        uint256 remainingReserve = v.feeReserve - v.matchedFee;
        o.returnedCollateral = (uint256(o.returnedCollateral) + unused).toUint128();
        o.consumedFeeReserve = (uint256(o.consumedFeeReserve) + remainingReserve).toUint128();
        reserveRefund = remainingReserve - fee;
        if (index == 0 && !o.serviceReleased) serviceRefund = m.serviceFee;
    }

    /// @notice Gross entitlement of one ticket after result, without any claim-order dependency.
    function claimable(O.Book storage o, MarketStorage.Market storage m, uint256 index)
        public
        view
        returns (uint256 amount)
    {
        O.Backing memory v = backing(o, index, m.pools[uint256(o.makerSide)]);
        if (v.winningClaimed || m.outcome == T.Outcome.Unresolved) return 0;
        if (m.outcome == T.Outcome.Void) return v.matchedCollateral;
        if (uint256(m.outcome) - 1 != uint256(o.makerSide)) return 0;
        (uint256 a, uint256 b) = lots(o.makerProbabilityBps);
        return v.matchedCollateral / a * (a + b);
    }

    /// @notice Fixed return for an aggregate opposite-side position; matched stakes are exact taker lots.
    function takerClaimable(O.Book storage o, MarketStorage.Market storage m, O.TakerPosition storage p)
        external
        view
        returns (uint256)
    {
        if (p.claimed || m.outcome == T.Outcome.Unresolved) return 0;
        if (m.outcome == T.Outcome.Void) return p.stake;
        if (uint256(m.outcome) - 1 == uint256(o.makerSide)) return 0;
        (uint256 a, uint256 b) = lots(o.makerProbabilityBps);
        return uint256(p.stake) / b * (a + b);
    }

    /// @notice Consume a ticket's terminal entitlement before custody transfers to its recorded owner.
    function claim(O.Book storage o, MarketStorage.Market storage m, uint256 index)
        external
        returns (address owner, uint256 amount)
    {
        if (index >= o.tickets.length) revert BackingNotFound();
        if (o.tickets[index].flags & 2 != 0) revert AlreadyClaimed();
        amount = claimable(o, m, index);
        if (amount == 0) revert NothingToClaim();
        o.tickets[index].flags |= 2;
        owner = o.tickets[index].owner;
        m.poolRemaining -= amount.toUint128();
    }
}
