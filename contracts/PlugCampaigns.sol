// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title PlugCampaigns
 * @notice Permissionless, USDC-funded pay-per-sale affiliate campaigns for AI agents on Arc.
 * @dev Every offer is sponsored: agents MUST disclose its sponsored nature to buyers.
 *      All monetary values are raw USDC units (6 decimals); 1 USDC is 1_000_000 units.
 *      The constructor token is trusted to be standard, non-fee-on-transfer USDC.
 *      Token decimals are an integration assumption, not checked on-chain.
 *      Campaign IDs start at zero and are never reused. There is no owner, admin,
 *      pause mechanism, or upgrade path. The advertiser is the merchant: purchases
 *      pay the advertiser in full; any eligible commission is paid separately from
 *      the advertiser's escrow.
 *      A purchase records token payment, not off-chain fulfillment or attribution
 *      authenticity. Buyers supply the agent operator's address as the referrer.
 *
 *      Trust model (read before funding a campaign):
 *      - The seller is the advertiser and funds its own commission budget. A seller buying
 *        from itself through any referrer only moves its own money: the purchase price returns
 *        to the seller and any commission re-routes its own escrowed USDC, creating no net gain.
 *        A third party farming commission pays the full price to the seller to get back at
 *        most 50% (commissionBps <= 5000), so it always loses money on the token flows.
 *      - All campaign budgets sit at this contract's address. If the USDC issuer blocklists
 *        that address, commission payouts fail and refunds revert, leaving escrow stuck. There is no
 *        pause or rescue path by design (permissionless, no admin).
 *      - An undeliverable referrer receives zero commission and leaves the budget untouched;
 *        commission delivery failure does not revert the sale.
 *      - A blocklisted advertiser cannot receive sale proceeds or refunds, which makes
 *        purchases on that campaign revert.
 */
contract PlugCampaigns is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Campaign configuration and cumulative settlement accounting.
    /// @dev Expiry does not automatically change active; endCampaign closes and refunds it.
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
    }

    /// @notice USDC used for both purchase payments and campaign escrow.
    IERC20 public immutable usdc;

    /// @notice Maximum title length in bytes, not Unicode characters.
    uint256 public constant MAX_TITLE_LENGTH = 128;
    /// @notice Maximum offer URL length in bytes; URL contents are not validated.
    uint256 public constant MAX_OFFER_URL_LENGTH = 512;
    /// @notice Maximum commission rate: 50% of the purchase price.
    uint16 public constant MAX_COMMISSION_BPS = 5000;

    Campaign[] private _campaigns;

    /// @notice Lifetime commission paid to each referrer, in raw USDC units.
    /// @dev This is historical accounting, not a withdrawable balance.
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
    /// @notice Purchases are prohibited at or after endTime.
    error CampaignExpired(uint256 id);
    /// @notice Only the advertiser may perform this action before expiry.
    error Unauthorized(uint256 id, address caller);

    /// @notice Emitted after a campaign's budget has been escrowed.
    event CampaignCreated(
        uint256 indexed id,
        address indexed advertiser,
        uint256 price,
        uint16 commissionBps,
        uint256 budget,
        uint64 endTime
    );

    /// @notice Emitted after additional USDC has been escrowed.
    event ToppedUp(uint256 indexed id, uint256 amount);

    /// @notice Emitted after purchase settlement succeeds.
    /// @dev Referrer is the supplied address, even when ineligible; commission is actual payment.
    event Purchase(
        uint256 indexed id,
        address indexed buyer,
        address indexed referrer,
        uint256 price,
        uint256 commission
    );

    /// @notice Emitted after closing a campaign and refunding its remaining escrow.
    event CampaignEnded(uint256 indexed id, uint256 refund);

    /// @param usdc_ Standard USDC token address; must not be zero.
    constructor(address usdc_) {
        if (usdc_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
    }

    /**
     * @notice Create a sponsored offer and escrow its commission budget.
     * @dev Caller becomes advertiser and seller, receives the full purchase price,
     *      and must approve this contract for budget.
     *      Zero budget and zero commission are permitted. Empty metadata is permitted.
     *      Effects precede token interactions; failed transfers revert all creation state.
     * @param title Display title, at most 128 bytes.
     * @param offerUrl Offer location, at most 512 bytes.
     * @param price Positive purchase price in raw USDC units.
     * @param commissionBps Commission rate in basis points, at most 5000.
     * @param budget Initial escrow in raw USDC units.
     * @param endTime Exclusive purchase deadline, in Unix seconds; must be in the future.
     * @return id Zero-based, monotonically assigned campaign ID.
     */
    function createCampaign(
        string calldata title,
        string calldata offerUrl,
        uint256 price,
        uint16 commissionBps,
        uint256 budget,
        uint64 endTime
    ) external nonReentrant returns (uint256 id) {
        if (price == 0) revert InvalidPrice();
        if (commissionBps > MAX_COMMISSION_BPS) revert InvalidCommissionBps(commissionBps);
        if (endTime <= block.timestamp) revert InvalidEndTime(endTime);
        if (bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong(bytes(title).length);
        if (bytes(offerUrl).length > MAX_OFFER_URL_LENGTH) revert OfferUrlTooLong(bytes(offerUrl).length);

        id = _campaigns.length;
        _campaigns.push(Campaign({
            advertiser: msg.sender,
            title: title,
            offerUrl: offerUrl,
            price: price,
            commissionBps: commissionBps,
            budgetRemaining: budget,
            endTime: endTime,
            active: true,
            sales: 0,
            commissionPaid: 0
        }));

        if (budget != 0) usdc.safeTransferFrom(msg.sender, address(this), budget);
        emit CampaignCreated(id, msg.sender, price, commissionBps, budget, endTime);
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
     * @notice Pay the advertiser in full and attempt an eligible agent operator's commission.
     * @dev Buyer must approve this contract for the price. Commission rounds down:
     *      floor(price * commissionBps / 10000), computed without intermediate overflow.
     *      Zero, buyer, and advertiser referrers are ineligible. Insufficient
     *      escrow disables the whole commission, never the sale; there is no partial payout.
     *      All accounting precedes both transfers. Advertiser payment failure reverts everything.
     *      Failed commission delivery restores its accounting and emits zero commission,
     *      without reverting the sale. Advertiser proceeds must still be deliverable.
     *      Advertisers may buy, but the stated referrer exclusions still apply.
     * @param id Existing campaign that is active and not yet expired.
     * @param referrer Agent operator's payout address, or zero for no referral.
     */
    function buy(uint256 id, address referrer) external nonReentrant {
        Campaign storage campaign = _getCampaign(id);
        if (!campaign.active) revert CampaignInactive(id);
        if (block.timestamp >= campaign.endTime) revert CampaignExpired(id);

        uint256 price = campaign.price;
        uint256 commission;
        if (
            referrer != address(0) &&
            referrer != msg.sender &&
            referrer != campaign.advertiser
        ) {
            uint256 calculatedCommission = Math.mulDiv(price, campaign.commissionBps, 10000);
            if (campaign.budgetRemaining >= calculatedCommission) commission = calculatedCommission;
        }

        campaign.sales += 1;
        if (commission != 0) {
            campaign.budgetRemaining -= commission;
            campaign.commissionPaid += commission;
            referrerEarnings[referrer] += commission;
        }

        usdc.safeTransferFrom(msg.sender, campaign.advertiser, price);
        if (commission != 0) {
            bytes memory transferData = abi.encodeCall(IERC20.transfer, (referrer, commission));
            address token = address(usdc);
            bool delivered;
            // Copy at most one word, even if the token returns excessive data.
            assembly ("memory-safe") {
                let success := call(gas(), token, 0, add(transferData, 0x20), mload(transferData), 0, 0x20)
                delivered := and(success, or(iszero(returndatasize()), and(eq(returndatasize(), 0x20), eq(mload(0), 1))))
            }
            if (!delivered) {
                campaign.budgetRemaining += commission;
                campaign.commissionPaid -= commission;
                referrerEarnings[referrer] -= commission;
                commission = 0;
            }
        }
        emit Purchase(id, msg.sender, referrer, price, commission);
    }

    /**
     * @notice Close a campaign and refund all unused escrow to its advertiser once.
     * @dev Advertiser may close at any time; anyone may close at or after endTime.
     *      Refund always goes to the advertiser, never to a third-party closer.
     *      Marks inactive and zeroes escrow before transferring; repeat calls revert.
     * @param id Existing, active campaign ID.
     */
    function endCampaign(uint256 id) external nonReentrant {
        Campaign storage campaign = _getCampaign(id);
        if (!campaign.active) revert CampaignInactive(id);
        if (msg.sender != campaign.advertiser && block.timestamp < campaign.endTime) {
            revert Unauthorized(id, msg.sender);
        }

        uint256 refund = campaign.budgetRemaining;
        campaign.active = false;
        campaign.budgetRemaining = 0;

        if (refund != 0) usdc.safeTransfer(campaign.advertiser, refund);
        emit CampaignEnded(id, refund);
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

    /// @dev Resolve a campaign storage reference or revert for an uncreated ID.
    function _getCampaign(uint256 id) private view returns (Campaign storage campaign) {
        if (id >= _campaigns.length) revert CampaignNotFound(id);
        return _campaigns[id];
    }
}
