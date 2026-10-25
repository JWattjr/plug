// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev Drives bounded random actions against PlugCampaigns.
contract PlugHandler is Test {
    PlugCampaigns public plug;
    BlocklistUSDC public usdc;

    address[4] public actors;

    uint256 public ghostSales;
    /// Count of sales where the advertiser's balance change was not exactly (buyer == advertiser ? 0 : +price).
    uint256 public ghostBadAdvertiserDelta;
    /// Count of sales where the buyer's balance change broke the expected value.
    uint256 public ghostBadBuyerDelta;
    /// Count of successful sales where a blocklisted referrer nonetheless got commission accounted.
    uint256 public ghostBlockedRefPaid;
    /// Count of successful sales where referrerEarnings delta != commissionPaid delta.
    uint256 public ghostEarningsMismatch;
    /// Count of times the blocklist action flipped a status.
    uint256 public ghostBlockToggles;
    /// Count of successful sales whose referrer was blocklisted at the time (commission must have failed).
    uint256 public ghostSalesWithBlockedRef;
    uint256 public constant INITIAL_BALANCE = 1e30;

    constructor(PlugCampaigns plug_, BlocklistUSDC usdc_) {
        plug = plug_;
        usdc = usdc_;
        for (uint256 i; i < 4; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            usdc.mint(actors[i], INITIAL_BALANCE);
            vm.prank(actors[i]);
            usdc.approve(address(plug), type(uint256).max);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _id(uint256 seed) internal view returns (bool ok, uint256 id) {
        uint256 n = plug.campaignCount();
        if (n == 0) return (false, 0);
        uint256 window = n < 4 ? n : 4; // bias towards recent campaigns so buys/topUps/ends hit live ones
        return (true, n - 1 - (seed % window));
    }

    function create(uint256 aSeed, uint256 price, uint16 bps, uint256 budget, uint256 dur) external {
        price = bound(price, 1, 1e12);
        bps = uint16(bound(bps, 0, 5000));
        budget = bound(budget, 0, 1e12);
        dur = bound(dur, 1, 3 days);
        vm.prank(_actor(aSeed));
        plug.createCampaign("t", "u", price, bps, budget, uint64(block.timestamp + dur));
    }

    function buy(uint256 aSeed, uint256 idSeed, uint256 refSeed) external {
        (bool ok, uint256 id) = _id(idSeed);
        if (!ok) return;
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        uint256 r = refSeed % 6;
        address ref = r == 0 ? address(0) : r == 5 ? c.advertiser : actors[r - 1];
        address who = _actor(aSeed);
        uint256 advBefore = usdc.balanceOf(c.advertiser);
        uint256 buyerBefore = usdc.balanceOf(who);
        uint256 paidBefore = c.commissionPaid;
        uint256 earnedBefore = plug.referrerEarnings(ref);
        bool refBlocked = ref != address(0) && usdc.isBlocklisted(ref);
        vm.prank(who);
        try plug.buy(id, ref) {
            PlugCampaigns.Campaign memory c2 = plug.getCampaign(id);
            if (refBlocked) {
                ghostSalesWithBlockedRef++;
                if (c2.commissionPaid != paidBefore) ghostBlockedRefPaid++;
            }
            if (plug.referrerEarnings(ref) - earnedBefore != c2.commissionPaid - paidBefore) ghostEarningsMismatch++;
            // Advertiser receives exactly price per sale (a self-buy nets zero; commission never goes to it).
            uint256 expAdv = who == c.advertiser ? advBefore : advBefore + c.price;
            if (usdc.balanceOf(c.advertiser) != expAdv) ghostBadAdvertiserDelta++;
            // Buyer pays exactly price; if buyer is also an eligible commission recipient it cannot be (excluded).
            uint256 expBuyer = who == c.advertiser ? buyerBefore : buyerBefore - c.price;
            if (usdc.balanceOf(who) != expBuyer) ghostBadBuyerDelta++;
            ghostSales++;
        } catch {}
    }

    function topUp(uint256 idSeed, uint256 amount) external {
        (bool ok, uint256 id) = _id(idSeed);
        if (!ok) return;
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        vm.prank(c.advertiser);
        try plug.topUp(id, bound(amount, 0, 1e12)) {} catch {}
    }

    function end(uint256 aSeed, uint256 idSeed) external {
        (bool ok, uint256 id) = _id(idSeed);
        if (!ok) return;
        vm.prank(_actor(aSeed));
        try plug.endCampaign(id) {} catch {}
    }

    /// Toggle the issuer blocklist for one of the actors or for the PlugCampaigns contract itself.
    function blocklist(uint256 seed, bool on) external {
        uint256 i = seed % 5;
        address who = i == 4 ? address(plug) : actors[i];
        usdc.setBlocklisted(who, on);
        ghostBlockToggles++;
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 0, 1 days));
    }
}

contract PlugCampaignsInvariantTest is Test {
    PlugCampaigns internal plug;
    BlocklistUSDC internal usdc;
    PlugHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new BlocklistUSDC();
        plug = new PlugCampaigns(address(usdc));
        handler = new PlugHandler(plug, usdc);
        targetContract(address(handler));
    }

    /// Conservation: contract USDC == sum of budgetRemaining across all campaigns.
    function invariant_BalanceEqualsSumOfBudgets() public view {
        uint256 sum;
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) sum += plug.getCampaign(i).budgetRemaining;
        assertEq(usdc.balanceOf(address(plug)), sum);
    }

    function invariant_InactiveCampaignsHoldNoBudget() public view {
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) {
            PlugCampaigns.Campaign memory c = plug.getCampaign(i);
            if (!c.active) assertEq(c.budgetRemaining, 0);
        }
    }

    /// Advertiser receives exactly price per successful sale; the buyer pays exactly price.
    function invariant_AdvertiserReceivesExactlyPricePerSale() public view {
        assertEq(handler.ghostBadAdvertiserDelta(), 0);
        assertEq(handler.ghostBadBuyerDelta(), 0);
    }

    /// Token conservation across the closed system of actors + contract.
    function invariant_TotalSupplyConserved() public view {
        uint256 total = usdc.balanceOf(address(plug));
        for (uint256 i; i < 4; i++) total += usdc.balanceOf(handler.actors(i));
        assertEq(total, 4 * handler.INITIAL_BALANCE() + 0);
    }

    /// Sum of per-referrer lifetime earnings (over handler actors) == sum of commissionPaid.
    function invariant_EarningsEqualCommissionPaid() public view {
        uint256 paid;
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) {
            PlugCampaigns.Campaign memory c = plug.getCampaign(i);
            paid += c.commissionPaid;
            assertLe(c.commissionPaid * 2, c.sales * c.price); // commission <= 50% of revenue
        }
        uint256 earned;
        for (uint256 i; i < 4; i++) earned += plug.referrerEarnings(handler.actors(i));
        assertEq(earned, paid);
    }

    /// A blocklisted referrer is never credited commission; earnings always move in lock-step with commissionPaid.
    function invariant_BlocklistedReferrerNeverCredited() public view {
        assertEq(handler.ghostBlockedRefPaid(), 0);
        assertEq(handler.ghostEarningsMismatch(), 0);
    }

    function invariant_CampaignSalesMatchGhost() public view {
        uint256 s;
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) s += plug.getCampaign(i).sales;
        assertEq(s, handler.ghostSales());
    }
}
