// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedOddsMath} from "./FixedOddsMath.sol";
import {OfferTypes} from "./OfferTypes.sol";
import {MarketStorage} from "./MarketStorage.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {Utf8} from "./Utf8.sol";

/// @title Linked exact-transfer and input-validation implementation for fixed-odds custody
/// @notice Immutable linked code runs in custody's context, with the caller's reentrancy guard active.
/// @dev Cannot be upgraded, holds no assets of its own, and has no independent administration.
///      External library calls use DELEGATECALL; ledger references point into the calling custody.
library OfferSupport {
    using SafeERC20 for IERC20;
    error InvalidNativeValue();
    error NativeTransferFailed();
    error UnsupportedTokenBehavior();
    error InsolventAsset();
    error InvalidTimes();
    error InvalidTerms();

    error InvalidRequest();
    error NoRequest();
    error RequestChanged();
    error RequestAlreadyRecorded();
    error RequestAlreadyUsed();
    event SettlementInitiated(
        uint256 indexed marketId,
        bytes32 indexed requestId,
        address indexed caller,
        bytes32 questionHash,
        bytes32 metadataHash,
        string metadataURI
    );
    event OracleRequestReplaced(
        uint256 indexed marketId,
        bytes32 indexed previousRequestId,
        bytes32 indexed requestId,
        address caller,
        bytes32 questionHash,
        bytes32 metadataHash,
        string metadataURI,
        string reason
    );

    /// @notice Record an authenticated operator's first request. Caller enforces role and Ask eligibility.
    function recordRequest(
        MarketStorage.Market storage m,
        MarketTypes.OracleRequest storage request,
        mapping(bytes32 => bool) storage used,
        uint256 id,
        bytes32 requestId,
        bytes32 questionHash,
        bytes32 metadataHash,
        string calldata uri
    ) external {
        if (request.requestId != bytes32(0)) revert RequestAlreadyRecorded();
        if (questionHash == bytes32(0)) revert InvalidRequest();
        consumeRequest(used, m.oracleAdapter, requestId, metadataHash);
        validateURI(uri);
        request.requestId = requestId;
        request.questionHash = questionHash;
        request.metadataHash = metadataHash;
        emit SettlementInitiated(id, requestId, msg.sender, questionHash, metadataHash, uri);
    }

    /// @notice Replace only request identity/metadata, retaining exact question and all prior replay keys.
    /// @dev Caller enforces EMERGENCY_ROLE, unresolved state and Ask. This function grants no authority.
    function replaceRequest(
        MarketStorage.Market storage m,
        MarketTypes.OracleRequest storage request,
        mapping(bytes32 => bool) storage used,
        uint256 id,
        bytes32 expected,
        bytes32 next,
        bytes32 metadataHash,
        string calldata uri,
        string calldata reason
    ) external {
        if (request.requestId == bytes32(0)) revert NoRequest();
        if (request.requestId != expected) revert RequestChanged();
        consumeRequest(used, m.oracleAdapter, next, metadataHash);
        validateURI(uri);
        validateURI(reason);
        request.requestId = next;
        request.metadataHash = metadataHash;
        emit OracleRequestReplaced(
            id, expected, next, msg.sender, request.questionHash, metadataHash, uri, reason
        );
    }

    /// @dev A failed validation reverts the caller's entire transaction, including this replay reservation.
    function consumeRequest(
        mapping(bytes32 => bool) storage used,
        address adapter,
        bytes32 id,
        bytes32 metadataHash
    ) private {
        if (id == bytes32(0) || bytes16(id << 128) != bytes16(0) || metadataHash == bytes32(0)) {
            revert InvalidRequest();
        }
        bytes32 key = keccak256(abi.encode(adapter, id));
        if (used[key]) revert RequestAlreadyUsed();
        used[key] = true;
    }

    error InvalidOutcome();
    event MarketFinalizedEvent(
        uint256 indexed marketId,
        MarketTypes.Outcome outcome,
        MarketTypes.FinalizationKind kind,
        address indexed caller,
        bytes32 requestId,
        uint256 pool,
        uint256 winningPool
    );

    /// @notice Immutable Oracle input reconstructed from the custody-owned record.
    function context(MarketStorage.Market storage m, uint256 id)
        public
        view
        returns (MarketTypes.OracleContext memory)
    {
        return MarketTypes.OracleContext(
            address(this),
            id,
            m.termsHash,
            m.questionTextHash,
            m.resolutionRulesHash,
            m.metadataHash,
            m.metadataURIHash,
            m.closeAt,
            m.oracleRequestAt,
            m.observationStart,
            m.observationEnd
        );
    }

    /// @notice Verify and finalize an ordinary result. Custody must enforce its relay role and due state first.
    function settle(
        MarketStorage.Market storage m,
        MarketTypes.OracleRequest storage request,
        uint256 id,
        bytes calldata proof,
        bool onlyVoid
    ) external {
        if (request.requestId == bytes32(0)) revert NoRequest();
        MarketTypes.Outcome outcome = IOracleAdapter(m.oracleAdapter).verify(context(m, id), request, proof);
        if (outcome == MarketTypes.Outcome.Unresolved || (onlyVoid && outcome != MarketTypes.Outcome.Void)) {
            revert InvalidOutcome();
        }
        finalize(m, id, outcome, MarketTypes.FinalizationKind.Oracle, request.requestId);
    }

    /// @notice Freeze an authorized result without duplicating unchanged pool denominators in storage.
    /// @dev Caller has checked unresolved/due state and the relevant proof or operator role.
    function finalize(
        MarketStorage.Market storage m,
        uint256 id,
        MarketTypes.Outcome outcome,
        MarketTypes.FinalizationKind kind,
        bytes32 requestId
    ) public {
        m.poolRemaining = m.pools[0] + m.pools[1];
        m.outcome = outcome;
        m.finalizationKind = kind;
        uint256 winner = outcome == MarketTypes.Outcome.Void ? 0 : m.pools[uint256(outcome) - 1];
        emit MarketFinalizedEvent(id, outcome, kind, msg.sender, requestId, m.poolRemaining, winner);
    }

    /// @notice Allocate an earned fee to current destinations without moving funds or changing liability.
    /// @dev Allocation changes affect new accrual only; previously credited balances remain claimable.
    function accrueFee(
        mapping(address => mapping(address => uint256)) storage feeCredits,
        MarketTypes.Recipients storage defaultRecipients,
        MarketTypes.FeeSplit memory split,
        MarketStorage.Market storage m,
        uint256 fee
    ) external {
        uint256 burn = Math.mulDiv(fee, split.burnBuyback, 10_000);
        uint256 oracle = Math.mulDiv(fee, split.oracleDistributor, 10_000);
        uint256 creatorShare = Math.mulDiv(fee, split.creator, 10_000);
        uint256 infrastructure = Math.mulDiv(fee, split.infrastructureCost, 10_000);
        if (burn != 0) feeCredits[m.asset][defaultRecipients.burnBuyback] += burn;
        if (oracle != 0) feeCredits[m.asset][defaultRecipients.oracleDistributor] += oracle;
        if (creatorShare != 0) feeCredits[m.asset][m.creator] += creatorShare;
        if (infrastructure != 0) feeCredits[m.asset][defaultRecipients.infrastructureCost] += infrastructure;
        feeCredits[m.asset][defaultRecipients.platform] += fee - burn - oracle - creatorShare - infrastructure;
    }

    /// @notice Conservative funding quote; unused reserves remain owned by the funding wallet.
    function quoteCreation(
        uint256 collateral,
        uint16 rate,
        uint16 unmatchedRate,
        uint256 cap,
        uint256 service
    ) external pure returns (uint256 reserve, uint256 total) {
        reserve = FixedOddsMath.fee(collateral, rate)
            + Math.min(FixedOddsMath.fee(collateral, unmatchedRate), cap);
        total = collateral + reserve + service;
    }

    /// @notice Commit immutable wording, initial economics, identity policy and consumer domain.
    /// @dev Must be called after initialization, once only, before publishing the funded offer.
    function commitTerms(
        MarketStorage.Market storage m,
        OfferTypes.Book storage o,
        MarketTypes.CreateParams calldata p,
        OfferTypes.CreateOffer calldata offer,
        MarketTypes.AssetConfig calldata config,
        uint256 id,
        address nft,
        uint256 nftChain
    ) external {
        bytes32 wording = keccak256(
            abi.encode(
                p.tokenId,
                m.questionTextHash,
                m.resolutionRulesHash,
                m.metadataHash,
                m.metadataURIHash,
                p.closeAt,
                p.oracleRequestAt,
                p.observationStart,
                p.observationEnd
            )
        );
        bytes32 economics = keccak256(
            abi.encode(
                p.asset,
                offer.makerSide,
                offer.makerProbabilityBps,
                offer.makerCollateral,
                offer.holderDiscount,
                config,
                o.makerFeeBps,
                o.creationTradingFeeBps,
                o.unmatchedFeeBps,
                o.unmatchedFeeCap,
                o.serviceRecipient,
                m.platformVersion
            )
        );
        m.termsHash = keccak256(
            abi.encode(
                keccak256("PEPEDICTION_FIFO_FIXED_ODDS_TERMS_V1"),
                block.chainid,
                address(this),
                nft,
                nftChain,
                id,
                msg.sender,
                wording,
                economics,
                m.oracleAdapter,
                m.oraclePolicyHash
            )
        );
    }

    /// @notice Write the common immutable creation terms in the caller's new market record.
    /// @dev The caller validates versions, eligibility and funds. Calls only for a fresh market ID.
    function initializeMarket(
        MarketStorage.Market storage m,
        MarketTypes.CreateParams calldata p,
        MarketTypes.AssetConfig calldata config,
        address adapter,
        uint64 version
    ) external {
        validateCreation(p);
        if (p.tokenId != type(uint256).max) m.tokenId = p.tokenId;
        m.creator = msg.sender;
        m.asset = p.asset;
        m.oracleAdapter = adapter;
        m.serviceFee = SafeCast.toUint128(config.serviceFee);
        m.minTrade = SafeCast.toUint128(config.minTrade);
        m.maxPool = SafeCast.toUint128(config.maxPool);
        m.closeAt = p.closeAt;
        m.oracleRequestAt = p.oracleRequestAt;
        m.observationStart = p.observationStart;
        m.observationEnd = p.observationEnd;
        m.assetVersion = config.version;
        m.platformVersion = version;
        m.questionTextHash = keccak256(bytes(p.question));
        m.resolutionRulesHash = keccak256(bytes(p.resolutionRules));
        m.metadataHash = p.metadataHash;
        m.metadataURIHash = keccak256(bytes(p.metadataURI));
        m.oraclePolicyHash = IOracleAdapter(adapter).policyHash();
    }

    /// @notice ABI view built from compact state; no redundant frozen/seed quantities are stored.
    function readMarket(
        MarketStorage.Market storage m,
        MarketTypes.Recipients storage recipients,
        bool discount
    ) external view returns (MarketTypes.Market memory v) {
        v.tokenId = discount ? m.tokenId : type(uint256).max;
        v.creator = m.creator;
        v.asset = m.asset;
        v.oracleAdapter = m.oracleAdapter;
        v.closeAt = m.closeAt;
        v.oracleRequestAt = m.oracleRequestAt;
        v.observationStart = m.observationStart;
        v.observationEnd = m.observationEnd;
        v.assetVersion = m.assetVersion;
        v.platformVersion = m.platformVersion;
        v.termsHash = m.termsHash;
        v.questionTextHash = m.questionTextHash;
        v.resolutionRulesHash = m.resolutionRulesHash;
        v.metadataHash = m.metadataHash;
        v.metadataURIHash = m.metadataURIHash;
        v.oraclePolicyHash = m.oraclePolicyHash;
        v.recipients = recipients;
        v.serviceFee = m.serviceFee;
        v.minTrade = m.minTrade;
        v.maxPool = m.maxPool;
        v.pools = [uint256(m.pools[0]), uint256(m.pools[1])];
        v.outcome = m.outcome;
        v.finalizationKind = m.finalizationKind;
        uint256 total = v.pools[0] + v.pools[1];
        v.poolRemaining = m.outcome == MarketTypes.Outcome.Unresolved ? total : m.poolRemaining;
        if (m.outcome != MarketTypes.Outcome.Unresolved) v.frozenPool = total;
        if (m.outcome == MarketTypes.Outcome.Yes || m.outcome == MarketTypes.Outcome.No) {
            v.frozenWinningPool = v.pools[uint256(m.outcome) - 1];
            v.remainingWinningStake = Math.mulDiv(m.poolRemaining, v.frozenWinningPool, total);
        }
    }

    /// @notice Validate the exact question, schedule and metadata without normalization.
    /// @param p Creator-provided terms. Market/offer and token-ownership checks remain in custody.
    function validateCreation(MarketTypes.CreateParams calldata p) internal view {
        if (
            p.closeAt <= block.timestamp || p.closeAt >= p.observationEnd
                || p.oracleRequestAt < p.observationEnd || p.observationStart > p.observationEnd
                || p.oracleRequestAt > block.timestamp + 60 days
        ) revert InvalidTimes();
        if (bytes(p.question).length == 0 || p.metadataHash == bytes32(0)) revert InvalidTerms();
        rejectNull(p.question);
        rejectNull(p.resolutionRules);
        Utf8.validate(p.question, 2000);
        Utf8.validate(p.resolutionRules, 512);
        validateURI(p.metadataURI);
    }

    /// @notice Require bounded nonempty UTF-8 metadata/reason text, without rewriting it.
    /// @param uri Exact text; its availability and factual contents are not asserted.
    function validateURI(string memory uri) public pure {
        if (bytes(uri).length == 0 || bytes(uri).length > 512) revert InvalidTerms();
        rejectNull(uri);
        Utf8.validate(uri, 512);
    }

    /// @dev PostgreSQL text/JSONB cannot represent NUL. Check every byte, including
    ///      text consumed by Utf8's full-word ASCII path; never replace committed bytes.
    function rejectNull(string memory text) private pure {
        bytes memory value = bytes(text);
        for (uint256 i; i < value.length; ++i) {
            if (value[i] == 0) revert InvalidTerms();
        }
    }

    /// @dev Caller increases ledgers first; require exact sender debit, exact custody credit and solvency.
    ///      Reverts roll back the entire funding operation, including fee credits and NFT locks.
    /// @param assetLiability Custody ledger, already updated for incoming funding.
    /// @param asset Approved ERC20 or native ETH.
    /// @param from Wallet whose allowance funds the operation.
    /// @param amount Exact gross funding expected in atomic units.
    function pullExact(
        mapping(address => uint256) storage assetLiability,
        address asset,
        address from,
        uint256 amount
    ) external {
        if (asset == address(0)) {
            if (msg.value != amount) revert InvalidNativeValue();
            if (address(this).balance < assetLiability[asset]) revert InsolventAsset();
            return;
        }
        if (msg.value != 0) revert InvalidNativeValue();
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        uint256 senderBefore = token.balanceOf(from);
        token.safeTransferFrom(from, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 senderAfter = token.balanceOf(from);
        if (
            afterBalance < beforeBalance || afterBalance - beforeBalance != amount
                || senderAfter > senderBefore || senderBefore - senderAfter != amount
        ) {
            revert UnsupportedTokenBehavior();
        }
        if (afterBalance < assetLiability[asset]) revert InsolventAsset();
    }

    /// @dev Caller consumes the relevant component entitlement first. Check solvency, reduce global
    ///      liability and transfer exactly amount; unsupported or blocked transfers revert all effects.
    /// @param assetLiability Custody ledger reduced by the exact payment.
    /// @param asset ERC20 or native ETH being paid.
    /// @param beneficiary Entitled wallet/fixed recipient, never an arbitrary relayer-selected destination.
    /// @param amount Exact claim or unused-funds refund amount in atomic units.
    function pay(
        mapping(address => uint256) storage assetLiability,
        address asset,
        address beneficiary,
        uint256 amount
    ) external {
        if (asset == address(0)) {
            if (address(this).balance < assetLiability[asset]) revert InsolventAsset();
            assetLiability[asset] -= amount;
            (bool success,) = payable(beneficiary).call{value: amount}("");
            if (!success) revert NativeTransferFailed();
            return;
        }
        IERC20 token = IERC20(asset);
        uint256 beforeBalance = token.balanceOf(address(this));
        if (beforeBalance < assetLiability[asset]) revert InsolventAsset();
        uint256 recipientBefore = token.balanceOf(beneficiary);
        assetLiability[asset] -= amount;
        token.safeTransfer(beneficiary, amount);
        uint256 afterBalance = token.balanceOf(address(this));
        uint256 recipientAfter = token.balanceOf(beneficiary);
        if (
            afterBalance > beforeBalance || beforeBalance - afterBalance != amount
                || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount
        ) {
            revert UnsupportedTokenBehavior();
        }
    }
}
