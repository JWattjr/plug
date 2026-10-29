// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsBase} from "./PlugCampaigns.Base.t.sol";

contract PlugCampaignsTest is PlugCampaignsBase {

    // ---------- constructor ----------
    function test_Constructor_SetsToken() public view {
        assertEq(address(plug.usdc()), address(usdc));
        assertEq(plug.MAX_COMMISSION_BPS(), 5000);
        assertEq(plug.MAX_TITLE_LENGTH(), 128);
        assertEq(plug.MAX_OFFER_URL_LENGTH(), 512);
        assertEq(plug.campaignCount(), 0);
    }

    function test_Constructor_ZeroTokenReverts() public {
        vm.expectRevert(PlugCampaigns.ZeroAddress.selector);
        new PlugCampaigns(address(0));
    }

    // ---------- createCampaign ----------
    function test_Create_StoresCampaignAndEscrows() public {
        uint64 end = _end();
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.CampaignCreated(0, advertiser, PRICE, BPS, BUDGET, end, 0, address(0));
        vm.prank(advertiser);
        uint256 id = plug.createCampaign("Title", "https://x.y", PRICE, BPS, BUDGET, end, 0, address(0));

        assertEq(id, 0);
        assertEq(plug.campaignCount(), 1);
        PlugCampaigns.Campaign memory c = plug.getCampaign(0);
        assertEq(c.advertiser, advertiser);
        assertEq(c.title, "Title");
        assertEq(c.offerUrl, "https://x.y");
        assertEq(c.price, PRICE);
        assertEq(c.commissionBps, BPS);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(c.endTime, end);
        assertTrue(c.active);
        assertEq(c.sales, 0);
        assertEq(c.commissionPaid, 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        assertEq(usdc.balanceOf(advertiser), advBefore - BUDGET);
    }

    function test_Create_IdsIncrement() public {
        assertEq(_create(), 0);
        assertEq(_create(), 1);
        assertEq(plug.campaignCount(), 2);
    }

    function test_Create_ZeroBudgetZeroBpsEmptyMetadataAllowed() public {
        vm.prank(advertiser);
        uint256 id = plug.createCampaign("", "", 1, 0, 0, _end(), 0, address(0));
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    function test_Create_BpsBoundary() public {
        _create(PRICE, 5000, BUDGET); // ok
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidCommissionBps.selector, uint16(5001)));
        plug.createCampaign("t", "u", PRICE, 5001, BUDGET, _end(), 0, address(0));
    }

    function test_Create_ZeroPriceReverts() public {
        vm.prank(advertiser);
        vm.expectRevert(PlugCampaigns.InvalidPrice.selector);
        plug.createCampaign("t", "u", 0, BPS, BUDGET, _end(), 0, address(0));
    }

    function test_Create_EndTimeNotInFutureReverts() public {
        uint64 nowTs = uint64(block.timestamp);
        vm.startPrank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidEndTime.selector, nowTs));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, nowTs, 0, address(0));
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidEndTime.selector, nowTs - 1));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, nowTs - 1, 0, address(0));
        // now + 1 is valid
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, nowTs + 1, 0, address(0));
        vm.stopPrank();
    }

    function test_Create_TitleLengthBoundary() public {
        string memory ok = string(new bytes(128));
        string memory bad = string(new bytes(129));
        vm.startPrank(advertiser);
        plug.createCampaign(ok, "u", PRICE, BPS, BUDGET, _end(), 0, address(0));
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.TitleTooLong.selector, 129));
        plug.createCampaign(bad, "u", PRICE, BPS, BUDGET, _end(), 0, address(0));
        vm.stopPrank();
    }

    function test_Create_UrlLengthBoundary() public {
        string memory ok = string(new bytes(512));
        string memory bad = string(new bytes(513));
        vm.startPrank(advertiser);
        plug.createCampaign("t", ok, PRICE, BPS, BUDGET, _end(), 0, address(0));
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.OfferUrlTooLong.selector, 513));
        plug.createCampaign("t", bad, PRICE, BPS, BUDGET, _end(), 0, address(0));
        vm.stopPrank();
    }

    function test_Create_WithoutAllowanceRevertsAndLeavesNoCampaign() public {
        vm.prank(advertiser);
        usdc.approve(address(plug), 0);
        vm.prank(advertiser);
        vm.expectRevert();
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 0, address(0));
        assertEq(plug.campaignCount(), 0);
    }

    // ---------- buy: happy path ----------
    function test_Buy_WithReferrerPaysAdvertiserFullPriceAndCommission() public {
        uint256 id = _create();
        uint256 mBefore = usdc.balanceOf(advertiser);
        uint256 bBefore = usdc.balanceOf(buyer);

        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, referrer, PRICE, COMMISSION);
        _buy(id, referrer);

        assertEq(usdc.balanceOf(advertiser), mBefore + PRICE, "advertiser full price");
        assertEq(usdc.balanceOf(referrer), COMMISSION, "referrer commission");
        assertEq(usdc.balanceOf(buyer), bBefore - PRICE, "buyer pays price only");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, BUDGET - COMMISSION);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), BUDGET - COMMISSION);
    }

    function test_Buy_MultipleSalesAccumulate() public {
        uint256 id = _create();
        _buy(id, referrer);
        _buy(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 2);
        assertEq(c.commissionPaid, 2 * COMMISSION);
        assertEq(c.budgetRemaining, BUDGET - 2 * COMMISSION);
        assertEq(plug.referrerEarnings(referrer), 2 * COMMISSION);
    }

    function test_Buy_ReferrerEarningsAcrossCampaigns() public {
        uint256 a = _create();
        uint256 b = _create();
        _buy(a, referrer);
        _buy(b, referrer);
        assertEq(plug.referrerEarnings(referrer), 2 * COMMISSION);
    }

    function test_Buy_CommissionRoundsDown() public {
        uint256 id = _create(10_001, 1, BUDGET); // 10001*1/10000 = 1.0001 -> 1
        _buy(id, referrer);
        assertEq(usdc.balanceOf(referrer), 1);
        uint256 id2 = _create(3, 3333, BUDGET); // 0.9999 -> 0
        _buy(id2, referrer);
        assertEq(usdc.balanceOf(referrer), 1);
        assertEq(plug.getCampaign(id2).sales, 1);
        assertEq(plug.getCampaign(id2).commissionPaid, 0);
    }

    // ---------- buy: ineligible referrers ----------
    function _assertNoCommissionSale(uint256 id, address ref, address who) internal {
        uint256 mBefore = usdc.balanceOf(advertiser);
        uint256 budgetBefore = plug.getCampaign(id).budgetRemaining;
        uint256 refBefore = usdc.balanceOf(ref);
        uint256 contractBefore = usdc.balanceOf(address(plug));
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, who, ref, PRICE, 0);
        vm.prank(who);
        plug.buy(id, ref);
        // advertiser receives the full price unless it is itself the buyer (then it pays itself: net zero)
        assertEq(usdc.balanceOf(advertiser), who == advertiser ? mBefore : mBefore + PRICE, "advertiser full price");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, budgetBefore);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(ref), 0);
        assertEq(usdc.balanceOf(address(plug)), contractBefore);
        if (ref != who && ref != advertiser) assertEq(usdc.balanceOf(ref), refBefore);
    }

    function test_Buy_ZeroReferrerNoCommission() public {
        uint256 id = _create();
        _assertNoCommissionSale(id, address(0), buyer);
        assertEq(plug.getCampaign(id).sales, 1);
    }

    function test_Buy_BuyerAsReferrerNoCommission() public {
        uint256 id = _create();
        uint256 before_ = usdc.balanceOf(buyer);
        _assertNoCommissionSale(id, buyer, buyer);
        assertEq(usdc.balanceOf(buyer), before_ - PRICE, "buyer==referrer nets -price");
    }

    function test_Buy_AdvertiserAsReferrerNoCommission() public {
        uint256 id = _create();
        _assertNoCommissionSale(id, advertiser, buyer);
    }

    function test_Buy_AdvertiserAsBuyerWithOwnReferrerNoCommission() public {
        uint256 id = _create();
        _assertNoCommissionSale(id, advertiser, advertiser);
    }

    function test_Buy_AdvertiserAsBuyerWithEligibleReferrerPaysCommissionFromEscrow() public {
        uint256 id = _create();
        uint256 before_ = usdc.balanceOf(advertiser);
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, advertiser, referrer, PRICE, COMMISSION);
        vm.prank(advertiser);
        plug.buy(id, referrer);
        assertEq(usdc.balanceOf(advertiser), before_, "advertiser pays itself the price");
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET - COMMISSION);
    }

    // ---------- buy: budget edge ----------
    function test_Buy_BudgetBelowCommissionSaleSucceedsNoCommission() public {
        uint256 id = _create(PRICE, BPS, COMMISSION - 1);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, referrer, PRICE, 0);
        _buy(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, COMMISSION - 1);
        assertEq(usdc.balanceOf(referrer), 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
    }

    function test_Buy_ExactBudgetPaysCommissionLeavesZero() public {
        uint256 id = _create(PRICE, BPS, COMMISSION);
        _buy(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, 0);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), 0);
        // next sale: still succeeds, no commission
        _buy(id, referrer);
        assertEq(plug.getCampaign(id).sales, 2);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
    }

    function test_Buy_ZeroBudgetSaleSucceeds() public {
        uint256 id = _create(PRICE, BPS, 0);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _buy(id, referrer);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(plug.getCampaign(id).commissionPaid, 0);
    }

    // ---------- buy: reverts ----------
    function test_Buy_AtEndTimeReverts() public {
        uint256 id = _create();
        vm.warp(_end());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignExpired.selector, id));
        plug.buy(id, referrer);
    }

    function test_Buy_OneSecondBeforeEndTimeSucceeds() public {
        uint256 id = _create();
        vm.warp(_end() - 1);
        _buy(id, referrer);
        assertEq(plug.getCampaign(id).sales, 1);
    }

    function test_Buy_AfterEndTimeReverts() public {
        uint256 id = _create();
        vm.warp(_end() + 1 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignExpired.selector, id));
        plug.buy(id, referrer);
    }

    function test_Buy_AfterEndCampaignReverts() public {
        uint256 id = _create();
        vm.prank(advertiser);
        plug.endCampaign(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.buy(id, referrer);
    }

    function test_Buy_WithoutAllowanceReverts() public {
        uint256 id = _create();
        address poor = makeAddr("poor");
        vm.prank(poor);
        vm.expectRevert();
        plug.buy(id, referrer);
    }

    function test_NonexistentCampaignReverts() public {
        bytes memory err = abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, 0);
        vm.expectRevert(err);
        plug.getCampaign(0);
        vm.expectRevert(err);
        plug.buy(0, referrer);
        vm.expectRevert(err);
        plug.topUp(0, 1);
        vm.expectRevert(err);
        plug.endCampaign(0);
        _create();
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, 1));
        plug.getCampaign(1);
    }
}
