// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PlugCampaigns
 * @notice Permissionless, USDC-funded pay-per-sale affiliate campaigns for AI agents on Arc, v2.
 * @dev Every offer is sponsored: agents MUST disclose its sponsored nature to buyers.
 *      All monetary values are raw USDC units (6 decimals); 1 USDC is 1_000_000 units.
 *      The constructor token is trusted to be standard, non-fee-on-transfer USDC.
 *      Token decimals are an integration assumption, not checked on-chain.
 *      Campaign and order IDs start at zero and are never reused. There is no owner,
 *      admin, pause mechanism, or upgrade path. The advertiser IS the seller.
 *      The seller receives the full purchase price; commissions use its separate budget.
 *      A purchase records token payment, not off-chain fulfillment or attribution
 *      authenticity. Buyers supply the agent operator's address as the referrer.
 *
 *      A zero protection window preserves v1 instant settlement and creates no order.
 *      Otherwise the price is escrowed for up to the seller-selected protection window
 *      (at most 30 days). The buyer may confirm early or dispute before releaseAt.
 *      The seller has 3 days to contest a dispute; contest deliberately resets the
 *      deadline to a 14-day arbiter timeout so an absent arbiter cannot lock funds.
 *      At or after either deadline the buyer may claim a refund; arbiter resolution is
 *      barred at or after the 14-day deadline, leaving only buyer or seller refunds for
 *      Contested orders. These are callable deadlines, not automatic settlement.
 *      Open orders survive campaign closure and expiry.
 *      A refunded sale pays no commission because no sale proceeds were settled.
 *      Sales and commissionPaid count settled sales and delivered commissions only:
 *      instant purchases and released orders, never pending orders or refunds.
 *
 *      Trust model (read before funding a campaign):
 *      - The seller selects a public arbiter; agents should judge that arbiter's trustworthiness.
 *        For protected orders the arbiter cannot be advertiser, buyer, or commission recipient.
 *        An arbiter can decide a contested order only strictly before its disputeDeadline.
 *        At or after that deadline only buyer or seller refunds can settle it.
 *        Buyer confirmation is not allowed once contested.
 *      - A seller buying from itself through a referrer only moves its own money:
 *        price returns to the seller and commission re-routes its own budget.
 *        A third party farming commission pays the full price to receive at most 50%.
 *      - All campaign budgets, reserved commissions, protected prices, and owed refunds are
 *        pooled at this contract's address. If USDC blocklists it, payouts fail and buyer
 *        refunds remain owed until delivery succeeds. There is no pause or rescue path by design.
 *      - Undeliverable commissions do not revert a sale. They return to an active
 *        campaign's budget, or to its seller after closure; failed seller returns remain
 *        credited to budgetRemaining, even for a closed campaign. Anyone may retry via
 *        withdrawClosedBudget; funds always go to the advertiser, and failed delivery
 *        reverts to preserve the credit without touching reserved commissions or prices.
 *      - A blocklisted advertiser still makes instant purchases and endCampaign refunds
 *        revert. A protected release instead refunds the buyer if seller price delivery
 *        fails; this release fallback also records an undeliverable buyer refund as owedRefunds.
 *        A blocklisted buyer's refund is held as owedRefunds until claimOwedRefund succeeds.
 *      - With standard USDC and no unsolicited token transfers, after each transaction:
 *        usdc.balanceOf(address(this)) == sum(campaign.budgetRemaining) + reservedCommission
 *        + escrowedPrice + owedRefunds.
 *        Direct token donations can create surplus; they cannot be prevented by this contract.
 */
contract PlugCampaigns is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Campaign configuration and cumulative settlement accounting.
    /// @dev Expiry does not automatically change active; endCampaign closes and refunds it.
    ///      Existing v1 fields retain their order. Zero protection ignores and clears arbiter.
    ///      sales and commissionPaid count settled sales and delivered commissions only.
    struct Campaign {
        address advertiser;
        string title;
        string offerUrl;
        uint256 price;
        uint16 commissionBps;
        uint256 budgetRemaining;
        uint64 endTime;
        bool active;
        uint256 sales;
        uint256 commissionPaid;
        uint64 protectionWindow;
        address arbiter;
        uint256 pendingOrders;
        uint256 refundedCount;
    }

    /// @notice Order lifecycle states, in their stable numeric order.
    enum Status { Pending, Disputed, Contested, Released, Refunded }

    /// @notice Protected purchase terms and current settlement state.
    /// @dev commission is the reserved amount, not historical delivered earnings.
    ///      disputeDeadline is zero until disputed, then reset on contest.
    struct Order {
        uint256 campaignId;
        address buyer;
        address referrer;
        uint256 price;
        uint256 commission;
        uint64 releaseAt;
        uint64 disputeDeadline;
        Status status;
    }

    /// @notice USDC used for both purchase payments and campaign escrow.
    IERC20 public immutable usdc;

    /// @notice Maximum title length in bytes, not Unicode characters.
    uint256 public constant MAX_TITLE_LENGTH = 128;
    /// @notice Maximum offer URL length in bytes; URL contents are not validated.
    uint256 public constant MAX_OFFER_URL_LENGTH = 512;
    /// @notice Maximum commission rate: 50% of the purchase price.
    uint16 public constant MAX_COMMISSION_BPS = 5000;
    /// @notice Maximum seller-selected buyer protection window.
    uint64 public constant MAX_PROTECTION_WINDOW = 30 days;
    /// @notice Time a seller has to contest a buyer dispute.
    uint64 public constant DISPUTE_PERIOD = 3 days;
    /// @notice Time after contest before the buyer can refund without arbiter cooperation.
    uint64 public constant ARBITER_TIMEOUT = 14 days;
    /// @notice Sentinel returned by instant buys; no order exists with this ID.
    uint256 public constant NO_ORDER = type(uint256).max;

    Campaign[] private _campaigns;
    Order[] private _orders;
    mapping(address => uint256[]) private _buyerOrders;
    mapping(uint256 => uint256[]) private _campaignOrders;

    /// @notice Total purchase prices held for all unsettled protected orders.
    uint256 public escrowedPrice;
    /// @notice Total commissions reserved for all unsettled protected orders.
    uint256 public reservedCommission;
    /// @notice Total finalized buyer refunds held until delivery succeeds.
    uint256 public owedRefunds;
    mapping(uint256 => uint256) private _refundOwed;
    /// @notice Lifetime commissions actually delivered to each referrer, in raw USDC units.
    /// @dev Historical accounting, not a withdrawable balance; refunds never increase it.
    mapping(address => uint256) public referrerEarnings;

    /// @notice The required token address was zero.
    error ZeroAddress();
    /// @notice Campaign price must be positive.
    error InvalidPrice();
    /// @notice Commission rate exceeds MAX_COMMISSION_BPS.
    error InvalidCommissionBps(uint16 commissionBps);
    /// @notice A new campaign must expire strictly in the future.
    error InvalidEndTime(uint64 endTime);
    /// @notice The title exceeds MAX_TITLE_LENGTH bytes.
    error TitleTooLong(uint256 length);
    /// @notice The offer URL exceeds MAX_OFFER_URL_LENGTH bytes.
    error OfferUrlTooLong(uint256 length);
    /// @notice The supplied campaign ID has never been created.
    error CampaignNotFound(uint256 id);
    /// @notice A closed campaign cannot be modified or purchased from.
    error CampaignInactive(uint256 id);
    /// @notice Closed-budget withdrawals require an inactive campaign.
    error CampaignStillActive(uint256 id);
    /// @notice The closed campaign has no remaining budget to withdraw.
    error NothingToWithdraw(uint256 id);
    /// @notice Purchases are prohibited at or after endTime.
    error CampaignExpired(uint256 id);
    /// @notice Only the advertiser may perform this action before expiry.
    error Unauthorized(uint256 id, address caller);
    /// @notice Protection exceeds MAX_PROTECTION_WINDOW.
    error InvalidProtectionWindow(uint64 protectionWindow);
    /// @notice A protected campaign requires a nonzero arbiter other than its seller.
    error InvalidArbiter(address arbiter);
    /// @notice A campaign's arbiter cannot buy its protected offer.
    error ArbiterIsParty();
    /// @notice The supplied order ID has never been created.
    error OrderNotFound(uint256 orderId);
    /// @notice The order has no undelivered buyer refund to claim.
    error NothingOwed(uint256 orderId);
    /// @notice The order's current status does not permit the requested transition.
    error InvalidOrderStatus(uint256 orderId, Status status);
    /// @notice Only this order's buyer may perform the action.
    error NotBuyer(uint256 orderId, address caller);
    /// @notice Only this order's campaign seller may perform the action.
    error NotSeller(uint256 orderId, address caller);
    /// @notice Only this order's campaign arbiter may perform the action.
    error NotArbiter(uint256 orderId, address caller);
    /// @notice Permissionless release must wait until releaseAt.
    error ReleaseTooEarly(uint256 orderId, uint64 releaseAt);
    /// @notice Disputes must begin strictly before releaseAt.
    error DisputeTooLate(uint256 orderId, uint64 releaseAt);
    /// @notice Contest must occur strictly before the dispute deadline.
    error ContestTooLate(uint256 orderId, uint64 disputeDeadline);
    /// @notice Arbiter resolution must occur strictly before the dispute deadline.
    error ArbiterWindowClosed(uint256 orderId, uint64 disputeDeadline);
    /// @notice A buyer's timeout refund must wait until disputeDeadline.
    error RefundTooEarly(uint256 orderId, uint64 disputeDeadline);
    /// @notice Dispute reason exceeds 256 bytes.
    error ReasonTooLong(uint256 length);
    /// @notice A calculated Unix timestamp cannot be represented by uint64.
    error TimestampOverflow();

    /// @notice Emitted after a campaign's budget has been escrowed.
    /// @dev arbiter is zero for instant campaigns, regardless of the supplied argument.
    event CampaignCreated(
        uint256 indexed id,
        address indexed advertiser,
        uint256 price,
        uint16 commissionBps,
        uint256 budget,
        uint64 endTime,
        uint64 protectionWindow,
        address arbiter
    );

    /// @notice Emitted after additional USDC has been escrowed.
    event ToppedUp(uint256 indexed id, uint256 amount);

    /// @notice Emitted after an instant purchase settles.
    /// @dev Referrer is the supplied address, even when ineligible; commission is actual payment.
    event Purchase(
        uint256 indexed id,
        address indexed buyer,
        address indexed referrer,
        uint256 price,
        uint256 commission
    );

    /// @notice Emitted after closing a campaign and refunding only its unreserved budget.
    event CampaignEnded(uint256 indexed id, uint256 refund);
    /// @notice Emitted after a closed campaign's remaining budget is delivered to its advertiser.
    event ClosedBudgetWithdrawn(uint256 indexed id, uint256 amount);
    /// @notice Emitted when price and any eligible commission are escrowed for a new order.
    event OrderPlaced(
        uint256 indexed orderId,
        uint256 indexed campaignId,
        address indexed buyer,
        address referrer,
        uint256 price,
        uint256 commission,
        uint64 releaseAt
    );
    /// @notice Emitted after seller payment; commissionDelivered is the amount actually delivered.
    event OrderReleased(uint256 indexed orderId, uint256 price, uint256 commissionDelivered);
    /// @notice Emitted when a buyer opens a dispute with its bounded reason.
    event OrderDisputed(uint256 indexed orderId, string reason);
    /// @notice Emitted after finalizing a buyer refund, delivered or owed; commissionReturned is restored to budget or seller.
    event OrderRefunded(uint256 indexed orderId, uint256 price, uint256 commissionReturned);
    /// @notice Emitted when buyer refund delivery fails and the price remains owed.
    event RefundOwed(uint256 indexed orderId, address indexed buyer, uint256 amount);
    /// @notice Emitted after an owed refund is delivered to the order's buyer.
    event OwedRefundPaid(uint256 indexed orderId, address indexed buyer, uint256 amount);
    /// @notice Emitted when the seller escalates a dispute and starts the arbiter timeout.
    event OrderContested(uint256 indexed orderId);
    /// @notice Emitted for the arbiter's requested outcome; failed seller payment still refunds.
    event OrderResolved(uint256 indexed orderId, bool refundBuyer);

    /// @param usdc_ Standard USDC token address; must not be zero.
    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    /**
     * @notice Create a sponsored offer and escrow its commission budget.
     * @dev Caller becomes advertiser and seller and must approve this contract for budget.
     *      Zero budget, zero commission, and empty metadata are permitted.
     *      Effects precede token interaction; failed funding reverts all creation state.
     * @param title Display title, at most 128 bytes.
     * @param offerUrl Offer location, at most 512 bytes.
     * @param price Positive purchase price in raw USDC units.
     * @param commissionBps Commission rate in basis points, at most 5000.
     * @param budget Initial escrow in raw USDC units.
     * @param endTime Exclusive purchase deadline, in Unix seconds; must be in the future.
     * @param protectionWindow Buyer protection duration, zero through 30 days.
     * @param arbiter Public dispute arbiter; ignored and stored as zero if protectionWindow is zero.
     * @return id Zero-based, monotonically assigned campaign ID.
     */
    function createCampaign(
        string calldata title,
        string calldata offerUrl,
        uint256 price,
        uint16 commissionBps,
        uint256 budget,
        uint64 endTime,
        uint64 protectionWindow,
        address arbiter
    ) external nonReentrant returns (uint256 id) {
        if (price == 0) revert InvalidPrice();
        if (commissionBps > MAX_COMMISSION_BPS) revert InvalidCommissionBps(commissionBps);
        if (endTime <= block.timestamp) revert InvalidEndTime(endTime);
        if (bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong(bytes(title).length);
        if (bytes(offerUrl).length > MAX_OFFER_URL_LENGTH) revert OfferUrlTooLong(bytes(offerUrl).length);
        if (protectionWindow > MAX_PROTECTION_WINDOW) revert InvalidProtectionWindow(protectionWindow);
        if (protectionWindow == 0) {
            arbiter = address(0);
        } else if (arbiter == address(0) || arbiter == msg.sender) {
            revert InvalidArbiter(arbiter);
        }

        id = _campaigns.length;
        _campaigns.push();
        Campaign storage campaign = _campaigns[id];
        campaign.advertiser = msg.sender;
        campaign.title = title;
        campaign.offerUrl = offerUrl;
        campaign.price = price;
        campaign.commissionBps = commissionBps;
        campaign.budgetRemaining = budget;
        campaign.endTime = endTime;
        campaign.active = true;
        campaign.protectionWindow = protectionWindow;
        campaign.arbiter = arbiter;

        if (budget != 0) usdc.safeTransferFrom(msg.sender, address(this), budget);
        emit CampaignCreated(id, msg.sender, price, commissionBps, budget, endTime, protectionWindow, arbiter);
    }

    /**
     * @notice Add commission escrow to an active campaign as its advertiser.
     * @dev Allowed even after expiry while active; endCampaign refunds unused funds.
     *      Caller must approve this contract for amount. Zero amount is permitted.
     * @param id Existing, active campaign ID.
     * @param amount Additional budget in raw USDC units.
     */
    function topUp(uint256 id, uint256 amount) external nonReentrant {
        Campaign storage campaign = _getCampaign(id);
        if (msg.sender != campaign.advertiser) revert Unauthorized(id, msg.sender);
        if (!campaign.active) revert CampaignInactive(id);

        campaign.budgetRemaining += amount;

        if (amount != 0) usdc.safeTransferFrom(msg.sender, address(this), amount);
        emit ToppedUp(id, amount);
    }

    /**
     * @notice Buy instantly or escrow a protected order according to the campaign terms.
     * @dev Approve the full price first. Commission rounds down using overflow-safe mulDiv.
     *      Zero, this contract, buyer, seller, and protected arbiter referrers are ineligible.
     *      Insufficient budget disables the whole commission, never the sale; no partial payout occurs.
     *      Instant settlement preserves v1 accounting rollback on commission delivery failure;
     *      advertiser price payment failure reverts that path. Protected orders reserve, but
     *      do not earn, commission. All effects precede the price pull and revert if it fails.
     * @param id Existing campaign that is active and not yet expired.
     * @param referrer Agent operator's payout address, or zero for no referral.
     * @return orderId Zero-based protected order ID, or NO_ORDER for an instant purchase.
     */
    function buy(uint256 id, address referrer) external nonReentrant returns (uint256 orderId) {
        Campaign storage campaign = _getCampaign(id);
        if (!campaign.active) revert CampaignInactive(id);
        if (block.timestamp >= campaign.endTime) revert CampaignExpired(id);
        if (campaign.protectionWindow != 0 && msg.sender == campaign.arbiter) revert ArbiterIsParty();

        uint256 price = campaign.price;
        uint256 commission;
        if (
            referrer != address(0) &&
            referrer != address(this) &&
            referrer != msg.sender &&
            referrer != campaign.advertiser &&
            referrer != campaign.arbiter
        ) {
            uint256 calculatedCommission = Math.mulDiv(price, campaign.commissionBps, 10000);
            if (campaign.budgetRemaining >= calculatedCommission) commission = calculatedCommission;
        }

        if (campaign.protectionWindow != 0) {
            campaign.budgetRemaining -= commission;
            reservedCommission += commission;
            escrowedPrice += price;
            campaign.pendingOrders += 1;
            orderId = _orders.length;
            uint64 releaseAt = _deadline(campaign.protectionWindow);
            _orders.push(Order({
                campaignId: id,
                buyer: msg.sender,
                referrer: referrer,
                price: price,
                commission: commission,
                releaseAt: releaseAt,
                disputeDeadline: 0,
                status: Status.Pending
            }));
            _buyerOrders[msg.sender].push(orderId);
            _campaignOrders[id].push(orderId);
            usdc.safeTransferFrom(msg.sender, address(this), price);
            emit OrderPlaced(orderId, id, msg.sender, referrer, price, commission, releaseAt);
            return orderId;
        }

        campaign.sales += 1;
        if (commission != 0) {
            campaign.budgetRemaining -= commission;
            campaign.commissionPaid += commission;
            referrerEarnings[referrer] += commission;
        }

        usdc.safeTransferFrom(msg.sender, campaign.advertiser, price);
        if (commission != 0 && !_tryTransfer(referrer, commission)) {
            campaign.budgetRemaining += commission;
            campaign.commissionPaid -= commission;
            referrerEarnings[referrer] -= commission;
            commission = 0;
        }
        emit Purchase(id, msg.sender, referrer, price, commission);
        return NO_ORDER;
    }

    /**
     * @notice Close a campaign and refund its unreserved escrow to its advertiser once.
     * @dev Advertiser may close at any time; anyone may close at or after endTime.
     *      Refund always goes to the advertiser. Reserved commissions and open prices stay
     *      escrowed and all order actions remain available. Repeat calls revert.
     *      Marks inactive and zeroes budget before transferring; delivery failure reverts.
     * @param id Existing, active campaign ID.
     */
    function endCampaign(uint256 id) external nonReentrant {
        Campaign storage campaign = _getCampaign(id);
        if (!campaign.active) revert CampaignInactive(id);
        if (msg.sender != campaign.advertiser && block.timestamp < campaign.endTime) {
            revert Unauthorized(id, msg.sender);
        }

        uint256 unspent = campaign.budgetRemaining;
        campaign.active = false;
        campaign.budgetRemaining = 0;

        if (unspent != 0) usdc.safeTransfer(campaign.advertiser, unspent);
        emit CampaignEnded(id, unspent);
    }

    /**
     * @notice Withdraw a closed campaign's remaining budget to its advertiser.
     * @dev Anyone may retry delivery of returned commissions credited after closure.
     *      Only this campaign's budgetRemaining is withdrawn; reservedCommission and
     *      escrowedPrice are untouched. Zeroes the budget before transferring; failed
     *      delivery reverts to preserve the credit for a later retry.
     * @param id Existing, inactive campaign ID with a nonzero remaining budget.
     */
    function withdrawClosedBudget(uint256 id) external nonReentrant {
        Campaign storage campaign = _getCampaign(id);
        if (campaign.active) revert CampaignStillActive(id);
        uint256 amount = campaign.budgetRemaining;
        if (amount == 0) revert NothingToWithdraw(id);
        campaign.budgetRemaining = 0;
        usdc.safeTransfer(campaign.advertiser, amount);
        emit ClosedBudgetWithdrawn(id, amount);
    }

    /// @notice Confirm receipt and release a Pending or Disputed order immediately as its buyer.
    /// @dev No campaign-active or expiry check. Contested orders require arbiter or timeout action.
    /// @param orderId Existing protected order ID.
    function confirm(uint256 orderId) external nonReentrant {
        Order storage order = _getOrder(orderId);
        if (msg.sender != order.buyer) revert NotBuyer(orderId, msg.sender);
        if (order.status != Status.Pending && order.status != Status.Disputed) {
            revert InvalidOrderStatus(orderId, order.status);
        }
        _release(orderId, order);
    }

    /// @notice Release a Pending order permissionlessly at or after releaseAt.
    /// @dev Failed seller price delivery refunds the buyer instead; failed buyer delivery remains owed.
    /// @param orderId Existing protected order ID.
    function release(uint256 orderId) external nonReentrant {
        Order storage order = _getOrder(orderId);
        if (order.status != Status.Pending) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp < order.releaseAt) revert ReleaseTooEarly(orderId, order.releaseAt);
        _release(orderId, order);
    }

    /// @notice Open a dispute as the buyer strictly before the protection window ends.
    /// @dev Starts the 3-day seller response period; no token movement occurs.
    /// @param orderId Existing Pending order ID.
    /// @param reason Public dispute explanation, at most 256 bytes.
    function dispute(uint256 orderId, string calldata reason) external nonReentrant {
        Order storage order = _getOrder(orderId);
        if (msg.sender != order.buyer) revert NotBuyer(orderId, msg.sender);
        if (order.status != Status.Pending) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp >= order.releaseAt) revert DisputeTooLate(orderId, order.releaseAt);
        if (bytes(reason).length > 256) revert ReasonTooLong(bytes(reason).length);
        order.status = Status.Disputed;
        order.disputeDeadline = _deadline(DISPUTE_PERIOD);
        emit OrderDisputed(orderId, reason);
    }

    /// @notice Refund any unsettled order voluntarily as its seller.
    /// @dev Valid for Pending, Disputed, or Contested, even after any deadline or campaign closure.
    /// @param orderId Existing protected order ID.
    function refund(uint256 orderId) external nonReentrant {
        Order storage order = _getOrder(orderId);
        Campaign storage campaign = _campaigns[order.campaignId];
        if (msg.sender != campaign.advertiser) revert NotSeller(orderId, msg.sender);
        if (
            order.status != Status.Pending &&
            order.status != Status.Disputed &&
            order.status != Status.Contested
        ) revert InvalidOrderStatus(orderId, order.status);
        _refund(orderId, order);
    }

    /// @notice Escalate a Disputed order to its campaign's arbiter as the seller.
    /// @dev Hardening: resets disputeDeadline to now + 14 days, preventing indefinite arbiter lockup.
    /// @param orderId Existing Disputed order still within its 3-day response period.
    function contest(uint256 orderId) external nonReentrant {
        Order storage order = _getOrder(orderId);
        if (msg.sender != _campaigns[order.campaignId].advertiser) revert NotSeller(orderId, msg.sender);
        if (order.status != Status.Disputed) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp >= order.disputeDeadline) revert ContestTooLate(orderId, order.disputeDeadline);
        order.status = Status.Contested;
        order.disputeDeadline = _deadline(ARBITER_TIMEOUT);
        emit OrderContested(orderId);
    }

    /// @notice Refund as the buyer when a seller or arbiter response deadline has elapsed.
    /// @dev Disputed orders wait 3 days from dispute; Contested orders wait 14 days from contest.
    ///      At or after the Contested deadline, only this buyer claim or a seller refund can settle;
    ///      arbiter resolution is barred, including at the exact deadline.
    ///      Failed buyer delivery records an owed refund without blocking commission return.
    /// @param orderId Existing Disputed or Contested order ID.
    function claimRefund(uint256 orderId) external nonReentrant {
        Order storage order = _getOrder(orderId);
        if (msg.sender != order.buyer) revert NotBuyer(orderId, msg.sender);
        if (order.status != Status.Disputed && order.status != Status.Contested) {
            revert InvalidOrderStatus(orderId, order.status);
        }
        if (block.timestamp < order.disputeDeadline) revert RefundTooEarly(orderId, order.disputeDeadline);
        _refund(orderId, order);
    }

    /// @notice Retry an owed refund permissionlessly; funds always go to the order's buyer.
    /// @dev Clears the credit before transfer; failed delivery reverts, preserving it for retry.
    /// @param orderId Existing protected order ID with an undelivered refund.
    function claimOwedRefund(uint256 orderId) external nonReentrant {
        Order storage order = _getOrder(orderId);
        uint256 amount = _refundOwed[orderId];
        if (amount == 0) revert NothingOwed(orderId);
        _refundOwed[orderId] = 0;
        owedRefunds -= amount;
        usdc.safeTransfer(order.buyer, amount);
        emit OwedRefundPaid(orderId, order.buyer, amount);
    }

    /// @notice Resolve a Contested order as its campaign's arbiter strictly before disputeDeadline.
    /// @dev No campaign-active or expiry check. Arbiter can never receive order funds.
    ///      At or after disputeDeadline, only buyer claimRefund or seller refund can settle.
    ///      A requested release still refunds if seller price delivery fails.
    ///      Failed buyer delivery records an owed refund without blocking commission return.
    /// @param orderId Existing Contested order ID.
    /// @param refundBuyer True to refund the buyer; false to attempt seller settlement.
    function resolve(uint256 orderId, bool refundBuyer) external nonReentrant {
        Order storage order = _getOrder(orderId);
        if (msg.sender != _campaigns[order.campaignId].arbiter) revert NotArbiter(orderId, msg.sender);
        if (order.status != Status.Contested) revert InvalidOrderStatus(orderId, order.status);
        if (block.timestamp >= order.disputeDeadline) revert ArbiterWindowClosed(orderId, order.disputeDeadline);
        if (refundBuyer) _refund(orderId, order);
        else _release(orderId, order);
        emit OrderResolved(orderId, refundBuyer);
    }

    /// @notice Return all configuration and accounting for an existing campaign.
    /// @param id Zero-based campaign ID; nonexistent IDs revert with CampaignNotFound.
    /// @return campaign A memory snapshot, including metadata and remaining escrow.
    function getCampaign(uint256 id) external view returns (Campaign memory campaign) {
        return _getCampaign(id);
    }

    /// @notice Return the total number of campaigns ever created, including closed ones.
    /// @return count Number of campaigns; valid IDs are strictly less than count.
    function campaignCount() external view returns (uint256 count) {
        return _campaigns.length;
    }

    /// @notice Return the terms and status of a protected order.
    /// @param orderId Zero-based order ID; nonexistent IDs revert with OrderNotFound.
    /// @return order A memory snapshot of the order.
    function getOrder(uint256 orderId) external view returns (Order memory order) {
        return _getOrder(orderId);
    }

    /// @notice Return the undelivered refund owed to an order's buyer, in raw USDC units.
    /// @param orderId Existing protected order ID; nonexistent IDs revert with OrderNotFound.
    /// @return amount Refund held until claimOwedRefund succeeds, or zero if none is owed.
    function refundOwedOf(uint256 orderId) external view returns (uint256 amount) {
        _getOrder(orderId);
        return _refundOwed[orderId];
    }

    /// @notice Return the number of protected orders ever placed, including settled ones.
    /// @return count Number of orders; valid IDs are strictly less than count.
    function orderCount() external view returns (uint256 count) {
        return _orders.length;
    }

    /// @notice Return all protected order IDs for a buyer in creation order.
    /// @param buyer Buyer address to query.
    /// @return orderIds All that buyer's order IDs, including settled orders.
    function ordersOfBuyer(address buyer) external view returns (uint256[] memory orderIds) {
        return _buyerOrders[buyer];
    }

    /// @notice Return all protected order IDs for an existing campaign in creation order.
    /// @param id Existing campaign ID; nonexistent IDs revert with CampaignNotFound.
    /// @return orderIds All that campaign's order IDs, including settled orders.
    function ordersOfCampaign(uint256 id) external view returns (uint256[] memory orderIds) {
        _getCampaign(id);
        return _campaignOrders[id];
    }

    /// @notice Return unsettled-order and lifetime refunded-order counts for a campaign.
    /// @param id Existing campaign ID; nonexistent IDs revert with CampaignNotFound.
    /// @return pendingOrders Number of Pending, Disputed, or Contested orders.
    /// @return refundedCount Number of orders settled as refunds.
    function campaignStats(uint256 id) external view returns (uint256 pendingOrders, uint256 refundedCount) {
        Campaign storage campaign = _getCampaign(id);
        return (campaign.pendingOrders, campaign.refundedCount);
    }

    /// @dev Settle effects before interactions. If seller price delivery fails, restore the
    ///      provisional release effects and run the same refund path as an explicit refund.
    ///      This fallback finalizes even if buyer delivery fails, recording the price as owed.
    ///      All callers have already validated status and authorization and hold the reentrancy lock.
    function _release(uint256 orderId, Order storage order) private {
        Campaign storage campaign = _campaigns[order.campaignId];
        Status previousStatus = order.status;
        order.status = Status.Released;
        escrowedPrice -= order.price;
        reservedCommission -= order.commission;
        campaign.pendingOrders -= 1;
        campaign.sales += 1;

        if (!_tryTransfer(campaign.advertiser, order.price)) {
            order.status = previousStatus;
            escrowedPrice += order.price;
            reservedCommission += order.commission;
            campaign.pendingOrders += 1;
            campaign.sales -= 1;
            _refund(orderId, order);
            return;
        }

        uint256 commissionDelivered = order.commission;
        if (commissionDelivered != 0) {
            campaign.commissionPaid += commissionDelivered;
            referrerEarnings[order.referrer] += commissionDelivered;
            if (!_tryTransfer(order.referrer, commissionDelivered)) {
                campaign.commissionPaid -= commissionDelivered;
                referrerEarnings[order.referrer] -= commissionDelivered;
                _returnCommission(campaign, commissionDelivered);
                commissionDelivered = 0;
            }
        }
        emit OrderReleased(orderId, order.price, commissionDelivered);
    }

    /// @dev Finalize refund accounting and return commission before attempting buyer delivery.
    ///      Failed buyer delivery records owedRefunds until claimOwedRefund succeeds, without
    ///      reverting settlement. The referrer earns nothing on a refunded sale.
    ///      Failed commission returns to a closed campaign's seller remain in budgetRemaining
    ///      for permissionless retry via withdrawClosedBudget, always paid to the advertiser.
    function _refund(uint256 orderId, Order storage order) private {
        Campaign storage campaign = _campaigns[order.campaignId];
        order.status = Status.Refunded;
        escrowedPrice -= order.price;
        reservedCommission -= order.commission;
        campaign.pendingOrders -= 1;
        campaign.refundedCount += 1;
        // Account for the returned commission before any refund transfer.
        campaign.budgetRemaining += order.commission;
        if (!campaign.active && order.commission != 0) {
            campaign.budgetRemaining -= order.commission;
            if (!_tryTransfer(campaign.advertiser, order.commission)) {
                campaign.budgetRemaining += order.commission;
            }
        }
        if (!_tryTransfer(order.buyer, order.price)) {
            owedRefunds += order.price;
            _refundOwed[orderId] = order.price;
            emit RefundOwed(orderId, order.buyer, order.price);
        }
        emit OrderRefunded(orderId, order.price, order.commission);
    }

    /// @dev Return an undeliverable commission to budget if active, otherwise attempt seller
    ///      delivery without blocking settlement; failed delivery remains credited to budget.
    ///      Anyone may retry a closed campaign's credit via withdrawClosedBudget; only its
    ///      advertiser receives the funds, and failed delivery preserves the credit.
    function _returnCommission(Campaign storage campaign, uint256 commission) private {
        if (campaign.active || !_tryTransfer(campaign.advertiser, commission)) {
            campaign.budgetRemaining += commission;
        }
    }

    /// @dev v1 non-reverting token delivery: accept empty return data or exactly one true word.
    ///      Copy at most one word even if the trusted standard token returns excessive data.
    ///      Relies on USDC not transferring tokens when it reverts or reports failure.
    function _tryTransfer(address recipient, uint256 amount) private returns (bool delivered) {
        if (recipient == address(this)) return false;
        bytes memory transferData = abi.encodeCall(IERC20.transfer, (recipient, amount));
        address token = address(usdc);
        assembly ("memory-safe") {
            let success := call(gas(), token, 0, add(transferData, 0x20), mload(transferData), 0, 0x20)
            delivered := and(success, or(iszero(returndatasize()), and(eq(returndatasize(), 0x20), eq(mload(0), 1))))
        }
    }

    /// @dev Calculate a deadline without silently truncating its uint64 representation.
    function _deadline(uint64 duration) private view returns (uint64 deadline) {
        uint256 timestamp = block.timestamp + duration;
        if (timestamp > type(uint64).max) revert TimestampOverflow();
        return uint64(timestamp);
    }

    /// @dev Resolve a campaign storage reference or revert for an uncreated ID.
    function _getCampaign(uint256 id) private view returns (Campaign storage campaign) {
        if (id >= _campaigns.length) revert CampaignNotFound(id);
        return _campaigns[id];
    }

    /// @dev Resolve an order storage reference or revert for an uncreated ID.
    function _getOrder(uint256 orderId) private view returns (Order storage order) {
        if (orderId >= _orders.length) revert OrderNotFound(orderId);
        return _orders[orderId];
    }
}
