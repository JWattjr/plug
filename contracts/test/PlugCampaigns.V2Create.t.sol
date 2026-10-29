// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev v2 createCampaign / buy-time arbiter hardening and the window == 0 (v1-equivalent) path.
contract PlugCampaignsV2CreateTest is PlugCampaignsV2Base {
    function test_V2_Constants() public view {
        assertEq(plug.MAX_PROTECTION_WINDOW(), 30 days);
        assertEq(plug.DISPUTE_PERIOD(), 3 days);
        assertEq(plug.ARBITER_TIMEOUT(), 14 days);
        assertEq(plug.NO_ORDER(), type(uint256).max);
        assertEq(plug.orderCount(), 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
    }

    function test_Create_WindowedStoresWindowAndArbiterAndEmits() public {
        uint64 end = _end();
        vm.expectEmit(true, true, false, true, address(plug));
        emit PlugCampaigns.CampaignCreated(0, advertiser, PRICE, BPS, BUDGET, end, WINDOW, arbiter);
        vm.prank(advertiser);
        uint256 id = plug.createCampaign("Title", "https://x.y", PRICE, BPS, BUDGET, end, WINDOW, arbiter);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.protectionWindow, WINDOW);
        assertEq(c.arbiter, arbiter);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 0);
        assertEq(c.budgetRemaining, BUDGET);
    }

    function test_Create_WindowZeroStoresArbiterAsZeroAndEmitsZero() public {
        uint64 end = _end();
        vm.expectEmit(true, true, false, true, address(plug));
        emit PlugCampaigns.CampaignCreated(0, advertiser, PRICE, BPS, BUDGET, end, 0, address(0));
        vm.prank(advertiser);
        uint256 id = plug.createCampaign("Title", "https://x.y", PRICE, BPS, BUDGET, end, 0, arbiter);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.protectionWindow, 0);
        assertEq(c.arbiter, address(0), "arbiter cleared");
    }

    function test_Create_WindowZeroAllowsZeroOrAdvertiserArbiterArg() public {
        vm.startPrank(advertiser);
        uint256 a = plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 0, address(0));
        uint256 b = plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 0, advertiser);
        vm.stopPrank();
        assertEq(plug.getCampaign(a).arbiter, address(0));
        assertEq(plug.getCampaign(b).arbiter, address(0));
    }

    function test_Create_WindowedZeroArbiterReverts() public {
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidArbiter.selector, address(0)));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), WINDOW, address(0));
        assertEq(plug.campaignCount(), 0);
    }

    function test_Create_WindowedArbiterEqualsAdvertiserReverts() public {
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidArbiter.selector, advertiser));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 1, advertiser);
        assertEq(plug.campaignCount(), 0);
    }

    function test_Create_WindowAboveMaxReverts() public {
        uint64 bad = 30 days + 1;
        vm.startPrank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidProtectionWindow.selector, bad));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), bad, arbiter);
        // window check precedes arbiter check
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidProtectionWindow.selector, bad));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), bad, address(0));
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidProtectionWindow.selector, type(uint64).max));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), type(uint64).max, arbiter);
        // boundary values are accepted
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 30 days, arbiter);
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 1, arbiter);
        vm.stopPrank();
        assertEq(plug.campaignCount(), 2);
    }

    function test_Create_V1ValidationStillAppliesWithWindow() public {
        vm.startPrank(advertiser);
        vm.expectRevert(PlugCampaigns.InvalidPrice.selector);
        plug.createCampaign("t", "u", 0, BPS, BUDGET, _end(), WINDOW, arbiter);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidCommissionBps.selector, uint16(5001)));
        plug.createCampaign("t", "u", PRICE, 5001, BUDGET, _end(), WINDOW, arbiter);
        uint64 nowTs = uint64(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidEndTime.selector, nowTs));
        plug.createCampaign("t", "u", PRICE, BPS, BUDGET, nowTs, WINDOW, arbiter);
        vm.stopPrank();
    }

    // ---------- window == 0 == v1 ----------
    function test_WindowZero_BuyReturnsNoOrderAndCreatesNoOrder() public {
        uint256 id = _create();
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, referrer, PRICE, COMMISSION);
        vm.prank(buyer);
        uint256 oid = plug.buy(id, referrer);
        assertEq(oid, NO_ORDER);
        assertEq(plug.orderCount(), 0);
        assertEq(plug.ordersOfBuyer(buyer).length, 0);
        assertEq(plug.ordersOfCampaign(id).length, 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        (uint256 pending, uint256 refunded) = plug.campaignStats(id);
        assertEq(pending, 0);
        assertEq(refunded, 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        _assertSolvent();
    }

    function test_WindowZero_ArbiterArgIsIgnoredSoItIsAnOrdinaryReferrerAndBuyer() public {
        vm.prank(advertiser);
        uint256 id = plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), 0, arbiter);
        // "arbiter" is eligible as referrer on an instant campaign
        _buy(id, arbiter);
        assertEq(usdc.balanceOf(arbiter), COMMISSION);
        // and as a buyer
        usdc.mint(arbiter, PRICE);
        vm.startPrank(arbiter);
        usdc.approve(address(plug), PRICE);
        assertEq(plug.buy(id, address(0)), NO_ORDER);
        vm.stopPrank();
    }

    // ---------- arbiter hardening at buy ----------
    function test_Buy_ArbiterAsBuyerReverts() public {
        uint256 id = _createP();
        usdc.mint(arbiter, PRICE);
        vm.startPrank(arbiter);
        usdc.approve(address(plug), PRICE);
        vm.expectRevert(PlugCampaigns.ArbiterIsParty.selector);
        plug.buy(id, referrer);
        vm.stopPrank();
        assertEq(plug.orderCount(), 0);
        assertEq(usdc.balanceOf(arbiter), PRICE);
    }

    function test_Buy_ArbiterAsReferrerGetsNoCommission() public {
        uint256 id = _createP();
        uint256 oid = _place(id, arbiter);
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        assertEq(o.commission, 0);
        assertEq(o.referrer, arbiter);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET, "budget untouched");
        assertEq(plug.reservedCommission(), 0);
        vm.warp(o.releaseAt);
        _release(oid);
        assertEq(usdc.balanceOf(arbiter), 0);
        assertEq(plug.referrerEarnings(arbiter), 0);
        assertEq(plug.getCampaign(id).commissionPaid, 0);
    }

    function test_Buy_ArbiterOfOtherCampaignCanBuyAndReceiveCommission() public {
        uint256 id = _createP();
        // second campaign with a different arbiter
        vm.prank(advertiser);
        uint256 id2 = plug.createCampaign("t", "u", PRICE, BPS, BUDGET, _end(), WINDOW, other);
        uint256 oid = _place(id2, arbiter); // arbiter of campaign 0 is an ordinary referrer on campaign 1
        assertEq(plug.getOrder(oid).commission, COMMISSION);
        assertEq(plug.getCampaign(id).pendingOrders, 0);
    }

    function test_Buy_AdvertiserAsBuyerOfOwnWindowedCampaignEscrowsPrice() public {
        uint256 id = _createP();
        uint256 before_ = usdc.balanceOf(advertiser);
        vm.prank(advertiser);
        uint256 oid = plug.buy(id, aliasRef);
        assertEq(usdc.balanceOf(advertiser), before_ - PRICE, "price escrowed even for self-buy");
        assertEq(plug.getOrder(oid).commission, COMMISSION);
        vm.warp(plug.getOrder(oid).releaseAt);
        _release(oid);
        assertEq(usdc.balanceOf(advertiser), before_, "seller gets own price back");
        assertEq(usdc.balanceOf(aliasRef), COMMISSION);
        _assertSolvent();
    }
}
