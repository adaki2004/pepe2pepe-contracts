// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {
    ReentrancyGuardTransient as ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {BackingQueue} from "./BackingQueue.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {OfferTypes} from "./OfferTypes.sol";
import {MarketStorage} from "./MarketStorage.sol";
import {OfferSupport} from "./OfferSupport.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";

/// @title Pepe2Pepe fully funded fixed-odds custody
/// @notice Anyone can fund one side; opposite-side bettors accept fixed, fully backed payouts.
/// @dev Fresh non-upgradeable custody. Legacy market and IMD adapter implementations stay separate.
///      Both sides are locked: unmatched backing funds return only after STOP, matched funds after result.
///      Existing role-gated Oracle/recovery paths and recipient addresses are preserved.
///      Fees are funded in addition to stake. NFT creator discount is home-chain only, never attested by BE.
contract Pepe2PepeMarket is AccessControlDefaultAdminRules, ReentrancyGuard {
    using SafeCast for uint256;
    /// @notice Permission to record canonical Oracle requests; does not authorize YES/NO finalization.
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    /// @notice Permission to relay verified outcomes until publicFinalization is permanently enabled.
    bytes32 public constant FINALIZER_ROLE = keccak256("FINALIZER_ROLE");
    /// @notice Trusted emergency request replacement and cancellation authority; cannot directly choose YES/NO.
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    /// @notice Trusted authority to choose YES/NO/VOID before finalization; independently revocable.
    /// @dev This power can defeat an Oracle proposal. Grant only to an explicitly trusted operator.
    bytes32 public constant RESULT_OVERRIDE_ROLE = keccak256("RESULT_OVERRIDE_ROLE");
    /// @notice Capability marker for clients; absent on earlier non-upgradeable deployments.
    uint256 public constant OPERATOR_OUTCOME_VERSION = 1;
    /// @notice Capability marker for clients; earlier non-upgradeable deployments do not expose this getter.
    uint256 public constant ORACLE_REQUEST_RECOVERY_VERSION = 1;
    /// @notice Permission to stop/resume new markets and additions, without blocking eligible exits or claims.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @notice Maximum creation-to-Ask-Oracle interval; does not limit the wait for an answer.
    uint256 internal constant MAX_SCHEDULE_HORIZON = 60 days;
    /// @notice Question length limit measured in decoded UTF-16 code units.
    uint256 internal constant MAX_QUESTION_UNITS = 2000;
    /// @notice Additional-rules limit matching a value in the existing Oracle definitions schema.
    uint256 internal constant MAX_RULES_UNITS = 512;
    /// @notice Maximum UTF-8 byte length of creation, request and emergency-reason URIs.
    uint256 internal constant MAX_URI_BYTES = 512;
    /// @notice Maximum admin-configurable fee: 500 basis points, or 5% added to net stake.
    uint16 public constant MAX_TRADING_FEE_BPS = 500;
    /// @notice Domain/version tag for the ordered ABI-encoded creation commitment.
    bytes32 public constant TERMS_VERSION = keccak256("PEPEDICTION_FIFO_FIXED_ODDS_TERMS_V1");

    /// @notice An asset, adapter, recipient or economic configuration is invalid.
    error InvalidConfiguration();
    /// @notice ETH funding must match exactly; ERC20 calls and withdrawals must send zero ETH.
    error InvalidNativeValue();
    /// @notice The entitled recipient rejected an ETH payment; all accounting is reverted.
    error NativeTransferFailed();
    /// @notice Current asset/platform versions differ from the creator's accepted versions.
    error ConfigurationChanged();
    /// @notice The asset is not enabled for new markets.
    error AssetDisabled();
    /// @notice The caller requesting the home-chain discount does not own the selected NFT.
    error NotNftOwner();
    /// @notice Timestamps violate creation/STOP/observation/Ask Oracle ordering or the scheduling horizon.
    error InvalidTimes();
    /// @notice Required text, metadata commitment, URI or beneficiary is invalid.
    error InvalidTerms();
    /// @notice Creator collateral, reserved fees and service escrow exceed the creator's authorized maximum.
    error CreationCostExceeded();
    /// @notice The market ID has never been created.
    error MarketNotFound();
    /// @notice The market already has an irreversible NO, YES or VOID outcome.
    error MarketFinalized();
    /// @notice A claim requires a terminal outcome but the market is unresolved.
    error MarketNotFinalized();
    /// @notice STOP has been reached; no new matches or top-ups are allowed.
    error TradingClosed();
    /// @notice New market creation and additions are currently paused.
    error DepositsPaused();
    /// @notice A net deposit is below the market minimum or cannot offer a minimum-sized opposite bet.
    error AmountTooSmall();
    /// @notice The proposed net addition exceeds this market's snapshotted pool cap.
    error PoolCapExceeded();
    /// @notice The net stake/payout is below the caller's transaction minimum.
    error OutputBelowMinimum();
    /// @notice The transaction's user-specified inclusion deadline has passed.
    error TransactionExpired();
    /// @notice Ask Oracle time has not been reached.
    error OracleNotDue();
    /// @notice The external request ID, question hash or request metadata commitment is invalid.
    error InvalidRequest();
    /// @notice This market already has its single canonical request.
    error RequestAlreadyRecorded();
    /// @notice This adapter/request pair is already assigned to a market.
    error RequestAlreadyUsed();
    /// @notice The operator's expected current request differs from the market's actual request.
    error RequestChanged();
    /// @notice Ordinary finalization requires a recorded request.
    error NoRequest();
    /// @notice The adapter returned Unresolved or a VOID-only call received another outcome.
    error InvalidOutcome();
    /// @notice The requested wallet entitlement or aggregate credit is zero.
    error NothingToClaim();
    /// @notice This wallet or ticket entitlement has already been consumed.
    error AlreadyClaimed();
    /// @notice Observed token balance changes do not match the exact promised transfer amount.
    error UnsupportedTokenBehavior();
    /// @notice This asset's contract balance cannot cover all outstanding obligations.
    error InsolventAsset();
    /// @notice Verified proof relay has already been permanently opened to the public.
    error PublicFinalizationAlreadyEnabled();

    /// @notice Global protocol destinations changed; adapter changes affect only future markets.
    /// @param version New monotonic platform version.
    /// @param oracleAdapter Default adapter for subsequent creations.
    /// @param recipients Current global financial destinations; no operational roles are granted.
    /// @param feeSplit Shares of collected trading fees used by subsequent trades in every market.
    /// @param tradingFeeBps Ordinary fee on new funding, in basis points (0–500).
    event PlatformConfigured(
        uint64 indexed version,
        address indexed oracleAdapter,
        MarketTypes.Recipients recipients,
        MarketTypes.FeeSplit feeSplit,
        uint16 tradingFeeBps
    );
    /// @notice Future-market collateral defaults or service fee changed.
    /// @param asset ERC20 address, or address(0) for native ETH.
    /// @param config Complete new configuration, including its version and creation-enabled flag.
    event AssetConfigured(address indexed asset, MarketTypes.AssetConfig config);
    /// @notice The global creation/addition pause changed.
    /// @param paused True to stop new funding, false to resume it.
    event DepositsPauseChanged(bool paused);
    /// @notice Valid ordinary Oracle proofs may now be relayed by anyone; emergency VOID stays gated.
    event PublicFinalizationEnabled();
    /// @notice A creator funded immutable terms, personal collateral, fee reserve and refundable service escrow.
    /// @dev Exact text is emitted for indexing. Read getMarket once for fixed observation/funding fields; recipients are current globals.
    /// @param marketId New market ID, starting at one.
    /// @param tokenId Discount NFT ID, or NO_IDENTITY for a public creator.
    /// @param creator Original creating wallet and creator-fee beneficiary.
    /// @param asset Fixed ERC20 collateral, or address(0) for native ETH.
    /// @param assetVersion Asset defaults accepted for this market.
    /// @param platformVersion Platform defaults accepted for this market, even if defaults later change.
    /// @param closeAt Trading STOP.
    /// @param oracleRequestAt Earliest Oracle request and finalization time.
    /// @param seedAmount Always zero for fully creator-funded offers.
    /// @param serviceFee Refundable until first match; earned once thereafter.
    /// @param termsHash Complete ordered creation commitment.
    /// @param metadataHash Nonzero commitment to published creation metadata.
    /// @param question Exact funded question text.
    /// @param resolutionRules Exact creator rules; may be empty.
    /// @param metadataURI Exact creation metadata reference.
    event MarketCreated(
        uint256 indexed marketId,
        uint256 indexed tokenId,
        address indexed creator,
        address asset,
        uint64 assetVersion,
        uint64 platformVersion,
        uint64 closeAt,
        uint64 oracleRequestAt,
        uint256 seedAmount,
        uint256 serviceFee,
        bytes32 termsHash,
        bytes32 metadataHash,
        string question,
        string resolutionRules,
        string metadataURI
    );
    /// @notice A service linked one canonical external request to a market.
    /// @dev Does not establish payment, panel completion or factual correctness.
    /// @param marketId Market being settled.
    /// @param requestId Left-aligned external request UUID.
    /// @param caller Authorized request-recording operator.
    /// @param questionHash Canonical external question commitment expected in the proof.
    /// @param metadataHash Commitment to request/evidence metadata, distinct from creation metadata.
    /// @param metadataURI Durable request/evidence reference.
    event SettlementInitiated(
        uint256 indexed marketId,
        bytes32 indexed requestId,
        address indexed caller,
        bytes32 questionHash,
        bytes32 metadataHash,
        string metadataURI
    );
    /// @notice An emergency operator replaced a request without changing its exact question commitment.
    /// @dev The reason is public accountability, not proof of a technical failure. Prior IDs stay consumed.
    /// @param marketId Unresolved market being recovered.
    /// @param previousRequestId Revoked UUID; proofs for it can no longer finalize this market.
    /// @param requestId New, previously unused, left-aligned request UUID.
    /// @param caller Holder of EMERGENCY_ROLE who authorized recovery.
    /// @param questionHash Unchanged canonical question commitment, including rules and observation window.
    /// @param metadataHash Commitment to the replacement request's metadata.
    /// @param metadataURI Durable replacement metadata reference.
    /// @param reason Nonempty public explanation, at most 512 UTF-8 bytes.
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
    /// @notice One irreversible matched-bet outcome was recorded.
    /// @param marketId Finalized market.
    /// @param outcome NO, YES or VOID.
    /// @param kind Authenticated Oracle result, emergency cancellation or discretionary operator outcome.
    /// @param caller Transaction sender performing finalization, not necessarily the Oracle signer.
    /// @param requestId Recorded external UUID, or zero when exceptional finalization preceded request recording.
    /// @param pool Total pool frozen immediately before claims.
    /// @param winningPool Matched winning-side denominator; zero for VOID.
    event MarketFinalizedEvent(
        uint256 indexed marketId,
        MarketTypes.Outcome outcome,
        MarketTypes.FinalizationKind kind,
        address indexed caller,
        bytes32 requestId,
        uint256 pool,
        uint256 winningPool
    );
    /// @notice Public accountability record for a manual emergency cancellation.
    /// @param marketId Market cancelled into VOID.
    /// @param caller Holder of EMERGENCY_ROLE that acted.
    /// @param reasonHash Nonzero reason-document commitment; does not prove an emergency exists.
    /// @param reasonURI Durable reference to the reason.
    event EmergencyVoidReason(
        uint256 indexed marketId, address indexed caller, bytes32 reasonHash, string reasonURI
    );
    /// @notice Public explanation for a discretionary operator YES/NO/VOID decision.
    /// @param marketId Previously unresolved market finalized by the operator.
    /// @param caller Wallet exercising RESULT_OVERRIDE_ROLE.
    /// @param outcome Chosen terminal outcome; not represented as a verified Oracle answer.
    /// @param requestId Reviewed current request, possibly zero if admission failed.
    /// @param reason Plain public UTF-8 explanation; no external website is required.
    event OperatorOutcomeReason(
        uint256 indexed marketId,
        address indexed caller,
        MarketTypes.Outcome outcome,
        bytes32 requestId,
        string reason
    );
    /// @notice A winning payout or VOID refund was paid once to its entitled wallet.
    /// @param marketId Finalized market.
    /// @param beneficiary Position owner receiving all transferred tokens.
    /// @param caller Self-claimant or permissionless relayer; cannot redirect payment.
    /// @param amount Exact token units paid, without an additional fee.
    event WinningClaimed(
        uint256 indexed marketId, address indexed beneficiary, address indexed caller, uint256 amount
    );
    /// @notice A beneficiary withdrew its accumulated trading-fee and any platform dust credit.
    /// @param asset ERC20 or native ETH paid.
    /// @param beneficiary Credit owner and transaction sender.
    /// @param amount Exact aggregate amount paid; not proof of a later burn/buyback/distribution.
    event FeesClaimed(address indexed asset, address indexed beneficiary, uint256 amount);
    /// @notice The first accepted match earned the market's creation-snapshotted service credit.
    /// @param marketId Newly funded market.
    /// @param asset ERC20 or native ETH in which the credit is owed.
    /// @param beneficiary This market's settlementInitiator financial recipient.
    /// @param amount Service credit added, independent of external work.
    event SettlementCreditAccrued(
        uint256 indexed marketId, address indexed asset, address indexed beneficiary, uint256 amount
    );
    /// @notice A service beneficiary withdrew its accumulated unconditional credit.
    /// @param asset ERC20 or native ETH paid.
    /// @param beneficiary Credit owner and transaction sender.
    /// @param amount Exact aggregate credit paid.
    event SettlementCreditsClaimed(address indexed asset, address indexed beneficiary, uint256 amount);
    /// @notice An administrator increased an open market's capacity without moving any funds.
    /// @param marketId Market whose pool limit increased.
    /// @param previousMaxPool Previous net capacity in collateral atomic units, including all matchable open-offer exposure.
    /// @param newMaxPool New, strictly larger capacity; this is not a live USD valuation.
    event MarketPoolCapIncreased(uint256 indexed marketId, uint256 previousMaxPool, uint256 newMaxPool);

    /// @notice Immutable discount collection on identityChainId; not a public-creation gate.
    IERC721 public immutable identityNFT;
    /// @notice NFT home chain; remote deployments do not offer the V1 holder discount.
    uint256 public immutable identityChainId;
    /// @notice Fixed-odds capability marker; legacy parimutuel clients must not submit trades here.
    uint256 public constant FIXED_ODDS_VERSION = 2;
    /// @notice Independently owned same-side FIFO contributions and bounded claims.
    uint256 public constant FIFO_BACKING_VERSION = 1;
    /// @notice Lifetime starter-side deposit limit, including initial funding; taker count is uncapped.
    uint256 public constant MAX_BACKINGS = 50;
    /// @notice Token ID sentinel used by public creators not requesting the NFT discount.
    uint256 public constant NO_IDENTITY = type(uint256).max;
    /// @notice Future-offer holder creator fee; initially 0.5%, capped at the ordinary rate.
    uint16 public holderCreatorFeeBps = 50;
    /// @notice Future-market rate on each wallet's returned unmatched backing; initially 0.5%.
    uint16 public unmatchedFeeBps = 50;
    /// @notice Asset-specific maximum unmatched charge, snapshotted when creating an offer.
    mapping(address => uint256) public unmatchedFeeCaps;
    mapping(uint256 => OfferTypes.Book) private _offers;

    error InvalidOdds();
    error NoMatchedBet();
    error NoEarlyExit();
    error BackingPositionsRequired();
    error BackingNotFound();
    error InvalidBatch();
    error TooManyBackings();
    error DiscountUnavailable();
    error NoCapacity();
    error InvalidLot();
    error SelfMatch();

    /// @notice Complete immutable offer pricing and initial creator escrow.
    event OfferCreated(uint256 indexed marketId, OfferTypes.Offer offer);
    /// @notice A new owned queue ticket at unchanged odds, including the initial creator deposit.
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
    /// @notice Unused principal and reserve returned after STOP, with exact unmatched/service accounting.
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
    /// @notice One ticket's matched YES/NO winnings or VOID principal paid to its owner.
    event BackingClaimed(
        uint256 indexed marketId, uint256 indexed backingId, address indexed owner, uint256 amount
    );

    /// @notice Both matched stakes, earned fees and remaining maker capacity; no RPC required for indexing.
    event BetMatched(
        uint256 indexed marketId,
        address indexed bettor,
        uint256 takerStake,
        uint256 makerStake,
        uint256 takerFee,
        uint256 makerFee,
        uint256 noPool,
        uint256 yesPool,
        uint256 makerAvailable,
        uint256 makerFeeReserve,
        uint64 feeVersion
    );
    /// @notice New-creator fee defaults; existing creator funding retains its accepted rate.
    event OfferFeePolicyConfigured(
        uint64 indexed version, uint16 holderCreatorFeeBps, uint16 unmatchedFeeBps
    );
    /// @notice New-offer unmatched cap changes along with the asset's configuration version.
    event UnmatchedFeeCapConfigured(address indexed asset, uint64 indexed assetVersion, uint256 cap);

    /// @notice Next offer identifier; IDs begin at one.
    uint256 public nextMarketId = 1;
    /// @notice Current global recipient / fee / future-adapter configuration version.
    uint64 public platformVersion;
    /// @notice Adapter used only for newly created markets.
    address public defaultOracleAdapter;
    /// @notice Current protocol recipients for new accruals; seedReserve is retained but unused.
    MarketTypes.Recipients public defaultRecipients;
    /// @notice Current fee shares in basis points of the collected trading fee.
    /// @dev One packed slot; the platform receives the remainder after flooring other shares.
    MarketTypes.FeeSplit public feeSplit = MarketTypes.FeeSplit(9500, 0, 0, 0, 500);
    /// @notice Ordinary rate for new funding, initially 100 (1%), capped at 500 (5%).
    uint16 public tradingFeeBps = 100;
    /// @notice If true, creation/addition is blocked; eligible unused refunds, settlement and claims remain open.
    bool public depositsPaused;
    /// @notice If true, ordinary proof relay is permanently public; emergency power is unaffected.
    bool public publicFinalization;

    /// @notice Future-creation collateral defaults; each Market retains its accepted asset economics.
    mapping(address => MarketTypes.AssetConfig) public assetConfigs;
    // Public creation has no NFT slot lock. NFT ownership only selects a creator fee discount.
    /// @dev Market records. A zero creator identifies a nonexistent ID; use _market to enforce existence.
    mapping(uint256 => MarketStorage.Market) private _markets;
    /// @dev Per-market, per-wallet stakes and a shared self/relayed final-claim flag.
    mapping(uint256 => mapping(address => OfferTypes.TakerPosition)) private _positions;
    /// @notice Canonical external request for each market; zero fields before recording.
    mapping(uint256 => MarketTypes.OracleRequest) public oracleRequests;
    /// @notice Replay protection keyed by keccak256(abi.encode(adapter, requestId)).
    mapping(bytes32 => bool) public usedOracleRequests;
    /// @notice Unclaimed trading-fee and platform-dust credit, keyed by asset then beneficiary.
    mapping(address => mapping(address => uint256)) public feeCredits;
    /// @notice Earned service credits after a first match, keyed by asset then beneficiary.
    mapping(address => mapping(address => uint256)) public settlementCredits;
    /// @notice Total outstanding obligations, including all markets and fee/service credits, for each asset.
    mapping(address => uint256) public assetLiability;

    /// @notice Deploy fixed-odds custody with optional home-chain NFT fee benefits.
    /// @dev Grants admin finalizer/emergency/result-override/pauser roles and initiator SETTLEMENT_ROLE.
    ///      Default-admin transfer starts with a two-day acceptance delay; other operations are not timelocked.
    ///      Admin transfer does not automatically revoke operational roles from the former administrator.
    /// @param nft NFT home-chain collection used only for optional creator discounts.
    /// @param nftChain Home chain of nft; a remote deployment does not grant holder discounts.
    /// @param admin Initial default administrator and operational role holder; must be nonzero.
    /// @param adapter Initial Oracle adapter contract with a nonzero policyHash.
    /// @param recipients Nonzero financial recipients, none equal to this custody contract.
    constructor(
        address nft,
        uint256 nftChain,
        address admin,
        address adapter,
        MarketTypes.Recipients memory recipients
    ) AccessControlDefaultAdminRules(2 days, admin) {
        if (nft == address(0) || nftChain == 0 || (nftChain == block.chainid && nft.code.length == 0)) revert InvalidConfiguration();
        identityNFT = IERC721(nft);
        identityChainId = nftChain;
        _configurePlatform(adapter, recipients);
        _grantRole(SETTLEMENT_ROLE, recipients.settlementInitiator);
        _grantRole(FINALIZER_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
        _grantRole(RESULT_OVERRIDE_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @notice Set versioned collateral defaults for future markets; default admin only.
    /// @dev Existing snapshots/credits remain unchanged. Disabling creation does not disable existing trades.
    ///      Amounts are token units, not an on-chain USD valuation; token behavior must be reviewed separately.
    /// @param asset ERC20 contract, or address(0) for native ETH.
    /// @param enabled Whether new markets may select this asset.
    /// @param seedAmount Must be zero for P2P; retained in the configuration ABI for existing admin tooling.
    /// @param serviceFee Escrow released to its fixed recipient on the first match, refundable if never matched.
    /// @param minTrade Minimum net creation, backing or taker stake, at least two atomic units.
    /// @param maxPool Per-market matched pool plus fully offered capacity, including the prospective taker side.
    function configureAsset(
        address asset,
        bool enabled,
        uint256 seedAmount,
        uint256 serviceFee,
        uint256 minTrade,
        uint256 maxPool
    ) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (
            (asset != address(0) && asset.code.length == 0) || seedAmount != 0 || minTrade < 2
                || maxPool < minTrade || maxPool > type(uint128).max || serviceFee > type(uint128).max
        ) revert InvalidConfiguration();
        uint64 version = assetConfigs[asset].version + 1;
        assetConfigs[asset] =
            MarketTypes.AssetConfig(enabled, version, seedAmount, serviceFee, minTrade, maxPool);
        emit AssetConfigured(asset, assetConfigs[asset]);
    }

    /// @notice Update only the future creation service fee for an already configured asset.
    /// @dev Default admin only. Increments the asset version; existing markets/credits are unchanged.
    /// @param asset Previously configured collateral, including native ETH.
    /// @param amount New refundable creation service escrow in token atomic units; may be zero.
    function setSettlementFee(address asset, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        MarketTypes.AssetConfig storage config = assetConfigs[asset];
        if (config.version == 0 || amount > type(uint128).max) {
            revert InvalidConfiguration();
        }
        config.serviceFee = amount;
        ++config.version;
        emit AssetConfigured(asset, config);
    }

    /// @notice Raise an existing open market's pool capacity; default admin only.
    /// @dev Does not change funded stakes, seed, service credits, minTrade or the creation termsHash.
    ///      The commitment retains the initial cap; getMarket reports the latest capacity, and this
    ///      event records each increase. Capacity cannot be reduced or changed after STOP.
    /// @param id Open market to expand.
    /// @param expectedMaxPool Previously reviewed capacity; rejects a stale administration request.
    /// @param newMaxPool Strictly larger net pool capacity, including all matchable open-offer exposure, in collateral atomic units.
    function increaseMarketMaxPool(uint256 id, uint256 expectedMaxPool, uint256 newMaxPool)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        MarketStorage.Market storage m = _market(id);
        if (m.outcome != MarketTypes.Outcome.Unresolved) revert MarketFinalized();
        if (block.timestamp >= m.closeAt) revert TradingClosed();
        if (m.maxPool != expectedMaxPool) revert ConfigurationChanged();
        if (newMaxPool <= m.maxPool || newMaxPool > type(uint128).max) revert InvalidConfiguration();
        m.maxPool = uint128(newMaxPool);
        emit MarketPoolCapIncreased(id, expectedMaxPool, newMaxPool);
    }

    /// @notice Change global financial destinations and the future-market adapter; default admin only.
    /// @dev Increments platformVersion. Existing adapters and accrued credits stay fixed; roles do not change.
    ///      In particular, setting a new settlementInitiator recipient does not grant SETTLEMENT_ROLE.
    /// @param adapter New default adapter contract exposing a nonzero policyHash.
    /// @param recipients Global financial recipients; nonzero and different from this contract.
    function configurePlatform(address adapter, MarketTypes.Recipients calldata recipients)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        _configurePlatform(adapter, recipients);
    }

    /// @notice Select the adapter for future markets without changing any financial recipients.
    /// @dev Default admin only; existing markets keep their adapter and policy hash. Increments
    ///      platformVersion, invalidating stale creation reviews. This does not rotate an old adapter.
    /// @param expectedVersion Platform version reviewed by the administrator.
    /// @param adapter Contract exposing a nonzero policyHash; deployment and signer must be reviewed.
    function setDefaultOracleAdapter(uint64 expectedVersion, address adapter)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (expectedVersion != platformVersion) revert ConfigurationChanged();
        _configurePlatform(adapter, defaultRecipients);
    }

    /// @notice Reallocate earned trading fees at subsequent matches; accepted stake fee rates are unchanged.
    /// @dev Default admin only. Changes neither pools, funded seed/service amounts, nor existing
    ///      fee credits. Each trade emits the exact configuration version for event-only indexing.
    ///      Shares sum to 10,000; zero shares are allowed. Rounding residue remains with platform.
    /// @param expectedVersion Current platformVersion reviewed by the administrator; rejects stale edits.
    /// @param split New percentages in basis points of the collected fee, ordered as FeeSplit.
    function setFeeSplit(uint64 expectedVersion, MarketTypes.FeeSplit calldata split)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (expectedVersion != platformVersion) revert ConfigurationChanged();
        if (
            uint256(split.platform) + split.oracleDistributor + split.burnBuyback + split.creator
                    + split.infrastructureCost != 10_000
        ) revert InvalidConfiguration();
        feeSplit = split;
        _publishPlatformConfiguration();
    }

    /// @notice Set the ordinary fee for new creator funding and new taker deposits.
    /// @dev Default admin only. Does not reprice existing stakes, seed, service or accrued fees.
    ///      The caller's maxDebit protects each new bet against an unaccepted fee increase while pending.
    ///      Increments platformVersion and emits the full policy for event-only accounting.
    /// @param expectedVersion Reviewed platform version; rejects stale admin edits.
    /// @param newFeeBps New fee on top of matched stake, in basis points, inclusive range 0–500 (0%–5%).
    function setTradingFeeBps(uint64 expectedVersion, uint16 newFeeBps)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (expectedVersion != platformVersion) revert ConfigurationChanged();
        if (newFeeBps > MAX_TRADING_FEE_BPS) revert InvalidConfiguration();
        tradingFeeBps = newFeeBps;
        _publishPlatformConfiguration();
    }

    /// @notice Pause/resume creation, top-ups and matches; PAUSER_ROLE only.
    /// @dev After-STOP unused refunds, finalization and final/fee/service claims remain callable.
    /// @param paused True to block incoming market funding, false to resume.
    function setDepositsPaused(bool paused) external onlyRole(PAUSER_ROLE) {
        depositsPaused = paused;
        emit DepositsPauseChanged(paused);
    }

    /// @notice Irreversibly permits anyone to relay a valid proof. Emergency VOID stays role-gated.
    /// @dev Default admin only, one successful call. A proof and canonical recorded request remain required.
    function enablePublicFinalization() external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (publicFinalization) revert PublicFinalizationAlreadyEnabled();
        publicFinalization = true;
        emit PublicFinalizationEnabled();
    }

    /// @notice Create a public fully funded challenge at immutable odds; funds cannot exit before STOP.
    /// @dev p.tokenId must be NO_IDENTITY without a discount. Fees are reserved on top of creator stake.
    ///      First match earns service credit; creating alone does not. No mandatory protocol seed.
    /// @param p Existing exact question, timing, configuration and maximum-debit fields.
    /// @param offer Creator's chosen side, implied price, collateral and optional home-chain NFT discount.
    /// @return id New offer/market identifier.
    function createMarket(MarketTypes.CreateParams calldata p, OfferTypes.CreateOffer calldata offer)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (depositsPaused) revert DepositsPaused();
        MarketTypes.AssetConfig memory config = assetConfigs[p.asset];
        if (!config.enabled) revert AssetDisabled();
        if (p.expectedAssetVersion != config.version || p.expectedPlatformVersion != platformVersion) {
            revert ConfigurationChanged();
        }
        if (offer.makerProbabilityBps == 0 || offer.makerProbabilityBps >= 10_000) revert InvalidOdds();
        if (offer.makerCollateral < config.minTrade) revert AmountTooSmall();
        if (offer.holderDiscount) {
            if (block.chainid != identityChainId) revert DiscountUnavailable();
            if (identityNFT.ownerOf(p.tokenId) != msg.sender) revert NotNftOwner();
        } else if (p.tokenId != NO_IDENTITY) {
            revert InvalidTerms();
        }
        id = nextMarketId++;
        MarketStorage.Market storage m = _markets[id];
        OfferSupport.initializeMarket(m, p, config, defaultOracleAdapter, platformVersion);
        OfferTypes.Book storage o = _offers[id];
        o.makerSide = offer.makerSide;
        o.makerProbabilityBps = offer.makerProbabilityBps;
        o.holderDiscount = offer.holderDiscount;
        o.makerFeeBps =
            offer.holderDiscount ? uint16(Math.min(holderCreatorFeeBps, tradingFeeBps)) : tradingFeeBps;
        o.creationTradingFeeBps = tradingFeeBps;
        o.unmatchedFeeBps = unmatchedFeeBps;
        o.serviceRecipient = defaultRecipients.settlementInitiator;
        o.unmatchedFeeCap = unmatchedFeeCaps[p.asset].toUint128();
        OfferSupport.commitTerms(m, o, p, offer, config, id, address(identityNFT), identityChainId);
        emit MarketCreated(
            id,
            p.tokenId,
            msg.sender,
            p.asset,
            config.version,
            platformVersion,
            p.closeAt,
            p.oracleRequestAt,
            0,
            config.serviceFee,
            m.termsHash,
            p.metadataHash,
            p.question,
            p.resolutionRules,
            p.metadataURI
        );
        uint256 feeReserve = BackingQueue.append(o, m, id, msg.sender, offer.makerCollateral, o.makerFeeBps);
        uint256 total = offer.makerCollateral + feeReserve + config.serviceFee;
        if (total > p.maxCreationCost) revert CreationCostExceeded();
        assetLiability[p.asset] += total;
        _pullExact(p.asset, msg.sender, total);
        emit OfferCreated(id, BackingQueue.offer(o, m));
    }

    /// @notice Accept the opposite side at the offer's exact fixed price.
    /// @dev Stake is net at risk; fee is paid on top. No pre-settlement exit for either party.
    /// @param id Open offer.
    /// @param takerStake Exact opposing stake, a multiple of its atomic-unit lot.
    /// @param maxDebit Maximum stake plus fee accepted by the caller.
    /// @param minPayout Minimum gross winning return; rejects stale/unaccepted economics.
    /// @param deadline Last acceptable inclusion timestamp.
    /// @return payout Fixed gross return if the taker's side wins.
    function matchBet(uint256 id, uint256 takerStake, uint256 maxDebit, uint256 minPayout, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 payout)
    {
        MarketStorage.Market storage m = _market(id);
        OfferTypes.Book storage o = _offers[id];
        _requireOpen(m);
        if (block.timestamp > deadline) revert TransactionExpired();
        if (msg.sender == m.creator || o.wallets[msg.sender].backer) revert SelfMatch();
        (
            uint256 makerStake,
            uint256 takerFee,
            uint256 makerFee,
            uint256 debit,
            uint256 quotedPayout,
            uint256 available,
            uint256 reserve
        ) = BackingQueue.quoteMatch(o, m, takerStake, tradingFeeBps);
        payout = quotedPayout;
        if (debit > maxDebit || payout < minPayout) revert OutputBelowMinimum();
        uint256 makerSide = uint256(o.makerSide);
        _positions[id][msg.sender].stake += takerStake.toUint128();
        m.pools[makerSide] += makerStake.toUint128();
        m.pools[1 - makerSide] += takerStake.toUint128();
        uint64 version = platformVersion;
        _accrueTradingFee(m, makerFee + takerFee);
        if (!o.serviceReleased) {
            o.serviceReleased = true;
            settlementCredits[m.asset][o.serviceRecipient] += m.serviceFee;
            emit SettlementCreditAccrued(id, m.asset, o.serviceRecipient, m.serviceFee);
        }
        assetLiability[m.asset] += debit;
        _pullExact(m.asset, msg.sender, debit);
        emit BetMatched(
            id,
            msg.sender,
            takerStake,
            makerStake,
            takerFee,
            makerFee,
            m.pools[0],
            m.pools[1],
            available,
            reserve,
            version
        );
    }

    /// @notice Add your collateral to the tail at the unchanged odds; any wallet may back the starter side.
    /// @dev Opposite-side players cannot switch sides in this market. The creator retains its accepted
    ///      creation fee; other backers accept the current standard rate. Existing tickets never reprice.
    /// @param id Open market.
    /// @param collateral Exact maker-lot multiple, at least the minimum stake.
    /// @param maxDebit Maximum collateral plus reserved fees accepted by this caller.
    /// @param deadline Last acceptable inclusion timestamp.
    /// @return backingId Append-only ticket ID, independent even for repeated contributions by one owner.
    function topUpOffer(uint256 id, uint256 collateral, uint256 maxDebit, uint256 deadline)
        external
        payable
        nonReentrant
        returns (uint256 backingId)
    {
        MarketStorage.Market storage m = _market(id);
        OfferTypes.Book storage o = _offers[id];
        _requireOpen(m);
        if (block.timestamp > deadline) revert TransactionExpired();
        if (collateral < m.minTrade) revert AmountTooSmall();
        if (_positions[id][msg.sender].stake != 0) revert SelfMatch();
        backingId = o.tickets.length;
        uint16 rate = msg.sender == m.creator ? o.makerFeeBps : tradingFeeBps;
        uint256 reserve = BackingQueue.append(o, m, id, msg.sender, collateral, rate);
        uint256 debit = collateral + reserve;
        if (debit > maxDebit) revert OutputBelowMinimum();
        assetLiability[m.asset] += debit;
        _pullExact(m.asset, msg.sender, debit);
    }

    /// @notice Compatibility shortcut: return unused funds of the initial creator ticket (ID zero).
    /// @dev Later top-ups have independent tickets and must use refundBacking/refundBackings.
    function refundUnused(uint256 id) external nonReentrant returns (uint256) {
        return _refundBacking(id, 0);
    }

    /// @notice After STOP anyone may refund one ticket, exclusively to its recorded owner.
    /// @dev A ticket need not wait for the Oracle or for any other owner's refund.
    function refundBacking(uint256 id, uint256 backingId) external nonReentrant returns (uint256) {
        return _refundBacking(id, backingId);
    }

    /// @notice Refund up to 20 selected tickets atomically; each payout goes to that ticket's owner.
    function refundBackings(uint256 id, uint256[] calldata backingIds) external nonReentrant {
        if (backingIds.length == 0 || backingIds.length > 20) revert InvalidBatch();
        for (uint256 i; i < backingIds.length; ++i) {
            _refundBacking(id, backingIds[i]);
        }
    }

    /// @notice Claim a ticket's matched winnings or VOID refund; public relayers cannot redirect payment.
    function claimBacking(uint256 id, uint256 backingId) external nonReentrant returns (uint256) {
        return _claimBacking(id, backingId);
    }

    /// @notice Claim up to 20 selected winning/VOID tickets atomically to their recorded owners.
    function claimBackings(uint256 id, uint256[] calldata backingIds) external nonReentrant {
        if (backingIds.length == 0 || backingIds.length > 20) revert InvalidBatch();
        for (uint256 i; i < backingIds.length; ++i) {
            _claimBacking(id, backingIds[i]);
        }
    }

    /// @dev Consume unused principal/reserve and fee-cap allowance before interacting with a token or owner.
    function _refundBacking(uint256 id, uint256 index) private returns (uint256 amount) {
        return BackingQueue.refundAndPay(
            _offers[id],
            _market(id),
            id,
            index,
            feeCredits,
            assetLiability,
            defaultRecipients.infrastructureCost,
            platformVersion
        );
    }

    /// @dev Final matched accounting is independent of unused refunds and any earlier ticket's claim state.
    function _claimBacking(uint256 id, uint256 index) private returns (uint256 amount) {
        MarketStorage.Market storage m = _market(id);
        if (m.outcome == MarketTypes.Outcome.Unresolved) revert MarketNotFinalized();
        address owner;
        (owner, amount) = BackingQueue.claim(_offers[id], m, index);
        _pay(m.asset, owner, amount);
        emit BackingClaimed(id, index, owner, amount);
    }

    /// @notice Record the market's first canonical external Oracle request after Ask Oracle.
    /// @dev SETTLEMENT_ROLE only. Does not itself ask the network, pay x402 or accrue another service fee.
    ///      Only emergency recovery can replace it; IDs cannot be reused with this adapter. Verify the question hash
    ///      before recording: an incorrect commitment can block ordinary settlement and need emergency recovery.
    /// @param id Existing unresolved market whose oracleRequestAt has been reached.
    /// @param requestId Nonzero UUID, sixteen bytes left-aligned in bytes32.
    /// @param questionHash Nonzero hash of the exact market-bound canonical Oracle question document.
    /// @param metadataHash Nonzero request/evidence metadata commitment; separate from creation metadata.
    /// @param metadataURI Durable UTF-8 request/evidence reference; emitted, not stored as a string.
    function initiateSettlement(
        uint256 id,
        bytes32 requestId,
        bytes32 questionHash,
        bytes32 metadataHash,
        string calldata metadataURI
    ) external onlyRole(SETTLEMENT_ROLE) nonReentrant {
        MarketStorage.Market storage m = _market(id);
        _requireUnresolvedDue(m);
        OfferSupport.recordRequest(
            m, oracleRequests[id], usedOracleRequests, id, requestId, questionHash, metadataHash, metadataURI
        );
    }

    /// @notice EMERGENCY ONLY: attach a fresh request for the exact same question after a provider failure.
    /// @dev EMERGENCY_ROLE only, even when public finalization is enabled. Does not purchase a request,
    ///      accrue credit, alter pools, or change the original question hash. The chain cannot establish
    ///      that the provider failed: this role is trusted not to select requests for a preferred result.
    ///      The expected ID prevents stale operator actions. All prior IDs remain permanently consumed.
    ///      A racing ordinary finalization is final if mined first; if replacement is first, its old proof fails.
    /// @param id Existing unresolved market after Ask Oracle, with a recorded request.
    /// @param expectedRequestId Exact current UUID the operator intends to revoke.
    /// @param requestId New nonzero UUID, sixteen bytes left-aligned in bytes32.
    /// @param metadataHash Nonzero replacement request metadata commitment.
    /// @param metadataURI Durable UTF-8 metadata reference, at most MAX_URI_BYTES bytes.
    /// @param reason Nonempty public explanation, at most 512 UTF-8 bytes; never include secrets.
    function replaceOracleRequest(
        uint256 id,
        bytes32 expectedRequestId,
        bytes32 requestId,
        bytes32 metadataHash,
        string calldata metadataURI,
        string calldata reason
    ) external onlyRole(EMERGENCY_ROLE) nonReentrant {
        MarketStorage.Market storage m = _market(id);
        _requireUnresolvedDue(m);
        OfferSupport.replaceRequest(
            m,
            oracleRequests[id],
            usedOracleRequests,
            id,
            expectedRequestId,
            requestId,
            metadataHash,
            metadataURI,
            reason
        );
    }

    /// @notice Finalize NO, YES or VOID using this market's adapter and recorded request.
    /// @dev FINALIZER_ROLE required until publicFinalization. No payouts are pushed in this transaction.
    /// @param id Unresolved, Oracle-eligible market with a recorded request.
    /// @param proof Adapter-specific result proof; see ImdOracleAdapter.verify for the v1 encoding.
    function settleMarket(uint256 id, bytes calldata proof) external nonReentrant {
        _settle(id, proof, false);
    }

    /// @notice Finalize specifically VOID using an authenticated Oracle result.
    /// @dev Same ordinary proof/role policy as settleMarket; not an elapsed-time refund or emergency bypass.
    /// @param id Unresolved, Oracle-eligible market with a recorded request.
    /// @param proof Valid adapter proof that must decode to Void.
    function voidMarket(uint256 id, bytes calldata proof) external nonReentrant {
        _settle(id, proof, true);
    }

    /// @notice EMERGENCY ONLY: trusted operator cancellation if ordinary settlement cannot safely finish.
    /// @dev EMERGENCY_ROLE only, including after public proof relay is enabled. Requires Ask Oracle time,
    ///      but no proof/request. A reason is accountability, not proof that an emergency exists.
    ///      Enables matched-principal refunds; all prior earned fees remain paid.
    /// @param id Existing unresolved market to cancel; terminal results cannot be revised.
    /// @param reasonHash Nonzero commitment to a public reason document.
    /// @param reasonURI Nonempty UTF-8 reason reference of at most MAX_URI_BYTES bytes.
    function emergencyVoidMarket(uint256 id, bytes32 reasonHash, string calldata reasonURI)
        external
        onlyRole(EMERGENCY_ROLE)
        nonReentrant
    {
        MarketStorage.Market storage m = _market(id);
        _requireUnresolvedDue(m);
        if (reasonHash == bytes32(0)) revert InvalidTerms();
        _validateURI(reasonURI);
        _finalize(id, m, MarketTypes.Outcome.Void, MarketTypes.FinalizationKind.Emergency);
        emit EmergencyVoidReason(id, msg.sender, reasonHash, reasonURI);
    }

    /// @notice EXCEPTIONAL: choose YES/NO/VOID when ordinary Oracle resolution is incorrect or unavailable.
    /// @dev RESULT_OVERRIDE_ROLE only, even with public proof relay. Requires Ask Oracle time and
    ///      an unresolved market. Cannot rewrite any finalized outcome, including an unclaimed VOID.
    ///      No Oracle proof is asserted: Operator provenance and the reason are public. Normal
    ///      payout/refund math, paid fees and beneficiary rights remain unchanged. Revoking or
    ///      renouncing this role removes this power from that wallet, not from other role holders.
    /// @param id Existing unresolved market to finalize.
    /// @param outcome No, Yes or Void (Solidity encoding 1, 2 or 3, not the Oracle wire encoding).
    /// @param expectedRequestId Reviewed current request; zero is allowed before request recording.
    /// @param reason Public nonempty explanation, at most MAX_URI_BYTES UTF-8 bytes, without NUL.
    function overrideMarketOutcome(
        uint256 id,
        MarketTypes.Outcome outcome,
        bytes32 expectedRequestId,
        string calldata reason
    ) external onlyRole(RESULT_OVERRIDE_ROLE) nonReentrant {
        MarketStorage.Market storage m = _market(id);
        _requireUnresolvedDue(m);
        if (outcome == MarketTypes.Outcome.Unresolved) revert InvalidOutcome();
        if (oracleRequests[id].requestId != expectedRequestId) revert RequestChanged();
        _validateURI(reason);
        // Keep the public explanation representable in downstream JSON/PostgreSQL text.
        for (uint256 i; i < bytes(reason).length; ++i) {
            if (bytes(reason)[i] == 0) revert InvalidTerms();
        }
        _finalize(id, m, outcome, MarketTypes.FinalizationKind.Operator);
        emit OperatorOutcomeReason(id, msg.sender, outcome, expectedRequestId, reason);
    }

    /// @notice Claim msg.sender's opposite-side winning payout or matched-stake VOID refund.
    /// @dev No additional fee or expiry; losing/empty positions revert with NothingToClaim.
    /// @param id Terminal market with an unconsumed positive caller entitlement.
    /// @return Exact token amount paid to msg.sender.
    function claimWinning(uint256 id) external nonReentrant returns (uint256) {
        return _claim(id, msg.sender);
    }

    /// @notice Permissionlessly relay an opposite-side wallet's winning payout or VOID refund.
    /// @dev Always pays beneficiary, never the relayer. Shares the same claim flag as claimWinning.
    /// @param id Terminal market with an unconsumed positive beneficiary entitlement.
    /// @param beneficiary Nonzero position owner whose entitlement is claimed; cannot redirect its funds.
    /// @return Exact token amount paid to beneficiary.
    function claimWinningFor(uint256 id, address beneficiary) external nonReentrant returns (uint256) {
        if (beneficiary == address(0)) revert InvalidTerms();
        return _claim(id, beneficiary);
    }

    /// @notice Withdraw all of msg.sender's accrued trading-fee credit in one asset.
    /// @dev Credit ownership, not an operational role or current NFT ownership, authorizes this claim.
    /// @param asset ERC20 with a positive feeCredits balance for msg.sender.
    /// @return amount Exact accumulated credit paid to msg.sender.
    function claimFees(address asset) external nonReentrant returns (uint256 amount) {
        amount = feeCredits[asset][msg.sender];
        if (amount == 0) revert NothingToClaim();
        feeCredits[asset][msg.sender] = 0;
        _pay(asset, msg.sender, amount);
        emit FeesClaimed(asset, msg.sender, amount);
    }

    /// @notice Withdraw all of msg.sender's earned first-match service credits in one asset.
    /// @dev Earned on first match, claimable before/after Oracle work. Recipient ownership controls withdrawal.
    /// @param asset ERC20 with a positive settlementCredits balance for msg.sender.
    /// @return amount Exact accumulated credit paid to msg.sender.
    function claimSettlementCredits(address asset) external nonReentrant returns (uint256 amount) {
        amount = settlementCredits[asset][msg.sender];
        if (amount == 0) revert NothingToClaim();
        settlementCredits[asset][msg.sender] = 0;
        _pay(asset, msg.sender, amount);
        emit SettlementCreditsClaimed(asset, msg.sender, amount);
    }

    /// @notice Read immutable terms and current accounting/finalization state.
    /// @param id Existing market ID; nonexistent IDs revert.
    /// @return Fixed market economics, CURRENT global recipients and mutable accounting/finalization.
    function getMarket(uint256 id) external view returns (MarketTypes.Market memory) {
        return OfferSupport.readMarket(_market(id), defaultRecipients, _offers[id].holderDiscount);
    }

    /// @notice Read one opposite-side wallet position; backers must use getBacking instead.
    /// @dev Stake fields remain historical after a final claim; inspect claimed or claimable before paying.
    /// @param id Existing market ID.
    /// @param wallet Position owner; an untouched wallet returns zero stakes and claimed=false.
    /// @return p NO/YES matched stakes and final-entitlement consumption flag.
    function getPosition(uint256 id, address wallet) public view returns (MarketTypes.Position memory p) {
        MarketStorage.Market storage m = _market(id);
        if (wallet == m.creator || _offers[id].wallets[wallet].backer) revert BackingPositionsRequired();
        OfferTypes.TakerPosition storage position = _positions[id][wallet];
        p.stakes[1 - uint256(_offers[id].makerSide)] = position.stake;
        p.claimed = position.claimed;
    }

    /// @notice Quote creator reserve at accepted future-offer defaults; funding is stake + reserve + service.
    /// @param asset Configured asset.
    /// @param collateral Creator stake.
    /// @param holderDiscount Whether a valid home-chain NFT discount will be requested.
    /// @return reserve Conservative fee funding, with unused balance returned after STOP.
    /// @return total Total creation debit, excluding chain gas.
    function quoteCreation(address asset, uint256 collateral, bool holderDiscount)
        external
        view
        returns (uint256 reserve, uint256 total)
    {
        if (holderDiscount && block.chainid != identityChainId) revert DiscountUnavailable();
        uint16 rate = holderDiscount ? uint16(Math.min(holderCreatorFeeBps, tradingFeeBps)) : tradingFeeBps;
        return OfferSupport.quoteCreation(
            collateral, rate, unmatchedFeeBps, unmatchedFeeCaps[asset], assetConfigs[asset].serviceFee
        );
    }

    /// @notice Read offer pricing, escrow and matched totals alongside getMarket.
    function getOffer(uint256 id) external view returns (OfferTypes.Offer memory) {
        return BackingQueue.offer(_offers[id], _market(id));
    }

    /// @notice Read one starter-side ticket; use the indexed owner field to discover a wallet's tickets.
    function getBacking(uint256 id, uint256 backingId) external view returns (OfferTypes.Backing memory) {
        MarketStorage.Market storage m = _market(id);
        return BackingQueue.backing(_offers[id], backingId, m.pools[uint256(_offers[id].makerSide)]);
    }

    /// @notice Final amount payable on a backing ticket, excluding its independent unused refund.
    function backingClaimable(uint256 id, uint256 backingId) external view returns (uint256) {
        return BackingQueue.claimable(_offers[id], _market(id), backingId);
    }

    /// @notice Exact match arithmetic using the current fee for this new taker deposit.
    /// @dev Does not grant a reservation or waive STOP/pause/creator restrictions.
    function quoteMatch(uint256 id, address wallet, uint256 takerStake)
        public
        view
        returns (uint256 makerStake, uint256 takerFee, uint256 makerFee, uint256 debit, uint256 payout)
    {
        wallet;
        (makerStake, takerFee, makerFee, debit, payout,,) =
            BackingQueue.quoteMatch(_offers[id], _market(id), takerStake, tradingFeeBps);
    }

    /// @notice Set the cap for future offers, versioning the asset configuration.
    function setUnmatchedFeeCap(address asset, uint64 expectedVersion, uint256 cap)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        MarketTypes.AssetConfig storage c = assetConfigs[asset];
        if (c.version == 0 || c.version != expectedVersion) revert ConfigurationChanged();
        if (cap > type(uint128).max) revert InvalidConfiguration();
        unmatchedFeeCaps[asset] = cap;
        ++c.version;
        emit AssetConfigured(asset, c);
        emit UnmatchedFeeCapConfigured(asset, c.version, cap);
    }

    /// @notice Configure future-offer holder and unmatched rates, each bounded to 0..5%.
    function setOfferFeePolicy(uint64 expectedVersion, uint16 holderRate, uint16 unmatchedRate)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (expectedVersion != platformVersion) revert ConfigurationChanged();
        if (holderRate > MAX_TRADING_FEE_BPS || unmatchedRate > MAX_TRADING_FEE_BPS) {
            revert InvalidConfiguration();
        }
        holderCreatorFeeBps = holderRate;
        unmatchedFeeBps = unmatchedRate;
        _publishPlatformConfiguration();
    }

    /// @dev Pause only prevents new funding, never after-STOP unused refunds or final claims.
    function _requireOpen(MarketStorage.Market storage m) private view {
        if (m.outcome != MarketTypes.Outcome.Unresolved) revert MarketFinalized();
        if (block.timestamp >= m.closeAt) revert TradingClosed();
        if (depositsPaused) revert DepositsPaused();
    }

    /// @notice Calculate the wallet's current final entitlement.
    /// @dev Returns zero while unresolved, for losers/empty positions or after consumption.
    ///      A positive result does not guarantee the ERC20 issuer will permit the transfer.
    /// @param id Existing market ID.
    /// @param wallet Owner of the matched position; unused maker collateral is accounted separately.
    /// @return Winning payout or combined remaining-net-stake VOID refund in atomic units.
    function claimable(uint256 id, address wallet) public view returns (uint256) {
        MarketStorage.Market storage m = _market(id);
        if (wallet == m.creator || _offers[id].wallets[wallet].backer) revert BackingPositionsRequired();
        return BackingQueue.takerClaimable(_offers[id], m, _positions[id][wallet]);
    }

    /// @notice Read the exact market context needed to construct and verify the external signed question.
    /// @param id Existing market ID.
    /// @return Contract/market identity and immutable terms/text/metadata/time commitments.
    function oracleContext(uint256 id) public view returns (MarketTypes.OracleContext memory) {
        return OfferSupport.context(_market(id), id);
    }

    /// @dev Validate and version future defaults; called by construction and the admin entry point.
    /// @param adapter Contract exposing a nonzero policy hash.
    /// @param r Current global financial destinations, validated individually.
    function _configurePlatform(address adapter, MarketTypes.Recipients memory r) private {
        if (adapter.code.length == 0 || IOracleAdapter(adapter).policyHash() == bytes32(0)) {
            revert InvalidConfiguration();
        }
        _checkRecipient(r.platform);
        _checkRecipient(r.oracleDistributor);
        _checkRecipient(r.burnBuyback);
        _checkRecipient(r.seedReserve);
        _checkRecipient(r.settlementInitiator);
        _checkRecipient(r.infrastructureCost);
        defaultOracleAdapter = adapter;
        defaultRecipients = r;
        _publishPlatformConfiguration();
    }

    /// @dev Publish recipients, shares and rate together so an indexer never has to guess a missing fee policy.
    function _publishPlatformConfiguration() private {
        ++platformVersion;
        emit PlatformConfigured(
            platformVersion, defaultOracleAdapter, defaultRecipients, feeSplit, tradingFeeBps
        );
        emit OfferFeePolicyConfigured(platformVersion, holderCreatorFeeBps, unmatchedFeeBps);
    }

    /// @dev Reject zero/self destinations; destinations may otherwise overlap or be smart wallets.
    /// @param recipient Proposed financial beneficiary.
    function _checkRecipient(address recipient) private view {
        if (recipient == address(0) || recipient == address(this)) revert InvalidConfiguration();
    }

    /// @dev Obtain a storage record and reject never-created IDs.
    /// @param id Market identifier.
    /// @return m Existing market storage reference.
    function _market(uint256 id) private view returns (MarketStorage.Market storage m) {
        m = _markets[id];
        if (m.creator == address(0)) revert MarketNotFound();
    }

    /// @dev Validate nonempty bounded UTF-8, not URI availability, scheme safety or document contents.
    /// @param uri Exact metadata/reason reference to validate without rewriting.
    function _validateURI(string memory uri) private pure {
        OfferSupport.validateURI(uri);
    }

    /// @dev Shared precondition for request recording, ordinary finalization and emergency VOID.
    /// @param m Existing market that must remain unresolved and have reached oracleRequestAt.
    function _requireUnresolvedDue(MarketStorage.Market storage m) private view {
        if (m.outcome != MarketTypes.Outcome.Unresolved) revert MarketFinalized();
        if (block.timestamp < m.oracleRequestAt) revert OracleNotDue();
        if (m.pools[0] == 0 || m.pools[1] == 0) revert NoMatchedBet();
    }

    /// @dev Enforce relay authority, request binding and adapter authentication before terminal effects.
    /// @param id Market being finalized.
    /// @param proof Adapter-specific proof.
    /// @param mustBeVoid If true, reject a valid YES or NO proof.
    function _settle(uint256 id, bytes calldata proof, bool mustBeVoid) private {
        if (!publicFinalization) _checkRole(FINALIZER_ROLE);
        MarketStorage.Market storage m = _market(id);
        _requireUnresolvedDue(m);
        OfferSupport.settle(m, oracleRequests[id], id, proof, mustBeVoid);
    }

    /// @dev Caller must already check unresolved/due status and outcome authority. Freeze totals and
    ///      claim processing never changes a terminal outcome. There is no NFT slot lock.
    /// @param id Market being finalized.
    /// @param m Its existing storage record.
    /// @param outcome Terminal outcome chosen through an authorized finalization entry point.
    /// @param kind Oracle, Emergency or Operator provenance for the immutable result.
    function _finalize(
        uint256 id,
        MarketStorage.Market storage m,
        MarketTypes.Outcome outcome,
        MarketTypes.FinalizationKind kind
    ) private {
        OfferSupport.finalize(m, id, outcome, kind, oracleRequests[id].requestId);
    }

    /// @dev Shared self/relayed payout path. Consume entitlement and adjust pool accounting before transfer.
    /// @param id Finalized market.
    /// @param beneficiary Position owner and immutable transfer destination for this call.
    /// @return amount Exact paid entitlement; an empty/already-consumed claim reverts.
    function _claim(uint256 id, address beneficiary) private returns (uint256 amount) {
        MarketStorage.Market storage m = _market(id);
        if (m.outcome == MarketTypes.Outcome.Unresolved) revert MarketNotFinalized();
        OfferTypes.TakerPosition storage position = _positions[id][beneficiary];
        if (position.claimed) revert AlreadyClaimed();
        amount = claimable(id, beneficiary);
        if (amount == 0) revert NothingToClaim();
        position.claimed = true;
        m.poolRemaining -= amount.toUint128();
        _pay(m.asset, beneficiary, amount);
        emit WinningClaimed(id, beneficiary, msg.sender, amount);
    }

    /// @dev Split a once-rounded total by current basis-point shares; remainder to platform.
    ///      Caller separately adjusts matched pools and global asset liabilities.
    /// @param m Market supplying the asset and original creator; protocol destinations are global.
    /// @param fee Total rounded trading fee; no tokens are transferred here.
    function _accrueTradingFee(MarketStorage.Market storage m, uint256 fee) private {
        OfferSupport.accrueFee(feeCredits, defaultRecipients, feeSplit, m, fee);
    }

    /// @dev Linked implementation preserves exact-debit/exact-credit and aggregate-solvency checks.
    function _pullExact(address asset, address from, uint256 amount) private {
        OfferSupport.pullExact(assetLiability, asset, from, amount);
    }

    /// @dev Consume liability and transfer the exact entitlement under the caller's reentrancy guard.
    function _pay(address asset, address beneficiary, uint256 amount) private {
        OfferSupport.pay(assetLiability, asset, beneficiary, amount);
    }
}
