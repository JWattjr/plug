// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev Protected-order happy paths: place, release, confirm, seller refund, claimRefund, contest/resolve.
contract PlugCampaignsOrdersTest is PlugCampaignsV2Base {
    // ---------- (1) placement ----------
    function test_Place_EscrowsPriceReservesCommissionPaysNobody() public {
        uint256 id = _createP();
        uint64 releaseAt = uint64(block.timestamp + WINDOW);
        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.OrderPlaced(0, id, buyer, referrer, PRICE, COMMISSION, releaseAt);
        vm.recordLogs();
        uint256 oid = _place(id, referrer);
        // exactly one PlugCampaigns log: OrderPlaced (no Purchase event for protected orders)
        uint256 plugLogs;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(plug)) plugLogs++;
        }
        assertEq(plugLogs, 1, "only OrderPlaced");

        assertEq(oid, 0);
        assertEq(usdc.balanceOf(buyer), buyerBefore - PRICE, "buyer pays price");
        assertEq(usdc.balanceOf(advertiser), advBefore, "seller not paid yet");
        assertEq(usdc.balanceOf(referrer), 0, "referrer not paid yet");
        assertEq(usdc.balanceOf(address(plug)), BUDGET + PRICE, "price held by contract");

        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, BUDGET - COMMISSION, "commission moved out of budget");
        assertEq(c.sales, 0);
        assertEq(c.commissionPaid, 0);
        assertEq(c.pendingOrders, 1);
        assertEq(c.refundedCount, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(plug.escrowedPrice(), PRICE);
        assertEq(plug.reservedCommission(), COMMISSION);
        assertEq(plug.orderCount(), 1);

        PlugCampaigns.Order memory o = plug.getOrder(oid);
        assertEq(o.campaignId, id);
        assertEq(o.buyer, buyer);
        assertEq(o.referrer, referrer);
        assertEq(o.price, PRICE);
        assertEq(o.commission, COMMISSION);
        assertEq(o.releaseAt, releaseAt);
        assertEq(o.disputeDeadline, 0);
        assertTrue(o.status == PENDING);
        _assertSolvent();
    }

    function test_Place_NoReferrerOrInsufficientBudgetReservesZeroCommission() public {
        uint256 id = _createP();
        uint256 o0 = _place(id, address(0));
        assertEq(plug.getOrder(o0).commission, 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);

        uint256 poor = _createP(PRICE, BPS, COMMISSION - 1, WINDOW);
        uint256 o1 = _place(poor, referrer);
        assertEq(plug.getOrder(o1).commission, 0, "all-or-nothing commission");
        assertEq(plug.getCampaign(poor).budgetRemaining, COMMISSION - 1);
        assertEq(plug.escrowedPrice(), 2 * PRICE);
        _assertSolvent();
    }

    function test_Place_IneligibleReferrersReserveNothing() public {
        uint256 id = _createP();
        address[3] memory refs = [buyer, advertiser, arbiter];
        for (uint256 i; i < 3; i++) {
            uint256 oid = _place(id, refs[i]);
            assertEq(plug.getOrder(oid).commission, 0);
        }
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
        _assertSolvent();
    }

    function test_Place_SecondOrderUsesNextIdAndAccumulates() public {
        uint256 id = _createP();
        assertEq(_place(id, referrer), 0);
        assertEq(_place(id, referrer), 1);
        assertEq(plug.escrowedPrice(), 2 * PRICE);
        assertEq(plug.reservedCommission(), 2 * COMMISSION);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET - 2 * COMMISSION);
        assertEq(plug.getCampaign(id).pendingOrders, 2);
        _assertSolvent();
    }

    function test_Place_BudgetCoversOnlyReservedCommissions() public {
        uint256 id = _createP(PRICE, BPS, COMMISSION, WINDOW); // exactly one commission
        uint256 o0 = _place(id, referrer);
        uint256 o1 = _place(id, referrer);
        assertEq(plug.getOrder(o0).commission, COMMISSION);
        assertEq(plug.getOrder(o1).commission, 0, "budget already reserved");
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
    }

    // ---------- (2) permissionless release ----------
    function test_Release_BeforeReleaseAtReverts() public {
        (, uint256 oid) = _setupOrder();
        uint64 releaseAt = _releaseAt(oid);
        vm.warp(releaseAt - 1);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ReleaseTooEarly.selector, oid, releaseAt));
        plug.release(oid);
        assertTrue(_status(oid) == PENDING);
    }

    function test_Release_AtReleaseAtByAnyoneSplitsExactly() public {
        (uint256 id, uint256 oid) = _setupOrder();
        vm.warp(_releaseAt(oid));
        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 buyerBefore = usdc.balanceOf(buyer);

        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, COMMISSION);
        vm.prank(makeAddr("randomKeeper"));
        plug.release(oid);

        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE, "seller gets full price");
        assertEq(usdc.balanceOf(referrer), COMMISSION, "referrer gets commission");
        assertEq(usdc.balanceOf(buyer), buyerBefore, "buyer unchanged");
        assertEq(usdc.balanceOf(arbiter), 0, "arbiter never paid");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 0);
        assertEq(c.budgetRemaining, BUDGET - COMMISSION);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertTrue(_status(oid) == RELEASED);
        assertEq(usdc.balanceOf(address(plug)), BUDGET - COMMISSION);
        _assertSolvent();
    }

    function test_Release_EarningsAndCommissionOnlyUpdateAtRelease() public {
        (uint256 id, uint256 oid) = _setupOrder();
        vm.warp(_releaseAt(oid) - 1);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(plug.getCampaign(id).commissionPaid, 0);
        assertEq(plug.getCampaign(id).sales, 0);
        vm.warp(_releaseAt(oid));
        _release(oid);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertEq(plug.getCampaign(id).commissionPaid, COMMISSION);
        assertEq(plug.getCampaign(id).sales, 1);
    }

    function test_Release_NoReferrerPaysOnlySeller() public {
        uint256 id = _createP();
        uint256 oid = _place(id, address(0));
        vm.warp(_releaseAt(oid));
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, 0);
        _release(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(plug.getCampaign(id).sales, 1);
        assertEq(plug.getCampaign(id).commissionPaid, 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
    }

    function test_Release_ZeroCommissionRoundingOrder() public {
        uint256 id = _createP(3, 3333, BUDGET, WINDOW); // 3 * 3333 / 10000 = 0
        uint256 oid = _place(id, referrer);
        assertEq(plug.getOrder(oid).commission, 0);
        vm.warp(_releaseAt(oid));
        _release(oid);
        assertEq(plug.getCampaign(id).sales, 1);
        assertEq(plug.referrerEarnings(referrer), 0);
    }

    function test_Release_PendingOrderStillReleasableLongAfterReleaseAt() public {
        (, uint256 oid) = _setupOrder();
        vm.warp(_releaseAt(oid) + 365 days);
        _release(oid);
        assertTrue(_status(oid) == RELEASED);
    }

    // ---------- (3) buyer confirm ----------
    function test_Confirm_BuyerReleasesImmediatelyFromPending() public {
        (uint256 id, uint256 oid) = _setupOrder();
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, COMMISSION);
        _confirm(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(plug.getCampaign(id).sales, 1);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertTrue(_status(oid) == RELEASED);
        _assertSolvent();
    }

    function test_Confirm_FromDisputedReleases() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        _confirm(oid);
        assertTrue(_status(oid) == RELEASED);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(plug.getCampaign(id).sales, 1);
        assertEq(plug.getCampaign(id).pendingOrders, 0);
        _assertSolvent();
    }

    function test_Confirm_AllowedAfterReleaseAtWhilePending() public {
        (, uint256 oid) = _setupOrder();
        vm.warp(_releaseAt(oid) + 1);
        _confirm(oid);
        assertTrue(_status(oid) == RELEASED);
    }

    // ---------- (4) seller refund ----------
    function _assertRefundedClean(uint256 id, uint256 oid, uint256 buyerBefore, uint256 advBefore) internal view {
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE, "buyer gets price back");
        assertEq(usdc.balanceOf(advertiser), advBefore, "seller gets nothing");
        assertEq(usdc.balanceOf(referrer), 0, "referrer gets nothing");
        assertEq(usdc.balanceOf(arbiter), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, BUDGET, "commission back to budget");
        assertEq(c.sales, 0);
        assertEq(c.commissionPaid, 0);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 1);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        _assertSolvent();
    }

    function test_SellerRefund_FromPending() public {
        (uint256 id, uint256 oid) = _setupOrder();
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        _sellerRefund(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_SellerRefund_FromDisputed() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _sellerRefund(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_SellerRefund_FromContested() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        _contest(oid);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _sellerRefund(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_SellerRefund_AllowedAfterReleaseAtWhilePending() public {
        (uint256 id, uint256 oid) = _setupOrder();
        vm.warp(_releaseAt(oid) + 30 days);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _sellerRefund(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_SellerRefund_CommissionCanBeReservedAgainAfterRefund() public {
        uint256 id = _createP(PRICE, BPS, COMMISSION, WINDOW);
        uint256 o0 = _place(id, referrer);
        _sellerRefund(o0);
        uint256 o1 = _place(id, referrer);
        assertEq(plug.getOrder(o1).commission, COMMISSION, "refunded commission is reusable");
    }

    // ---------- (5) dispute -> seller silent -> claimRefund ----------
    function test_Dispute_SetsStateDeadlineAndEmits() public {
        (uint256 id, uint256 oid) = _setupOrder();
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderDisputed(oid, "not as described");
        _dispute(oid);
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        assertTrue(o.status == DISPUTED);
        assertEq(o.disputeDeadline, block.timestamp + DISPUTE_PERIOD);
        assertEq(plug.getCampaign(id).pendingOrders, 1, "still unsettled");
        assertEq(plug.escrowedPrice(), PRICE, "no funds move on dispute");
        _assertSolvent();
    }

    function test_ClaimRefund_AfterThreeDaysWorksAndFailsOneSecondBefore() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        vm.warp(deadline - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
        plug.claimRefund(oid);

        vm.warp(deadline);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        _claim(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_ClaimRefund_WorksEvenAfterReleaseAtPassedDuringDispute() public {
        (uint256 id, uint256 oid) = _setupOrder();
        vm.warp(_releaseAt(oid) - 1);
        _dispute(oid);
        vm.warp(block.timestamp + DISPUTE_PERIOD + 1 days);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _claim(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    // ---------- (6) contest + arbiter ----------
    function test_Contest_SetsContestedAndResetsDeadlineToFourteenDays() public {
        (, uint256 oid) = _setupOrder();
        _dispute(oid);
        vm.warp(block.timestamp + 1 days);
        vm.expectEmit(true, false, false, false, address(plug));
        emit PlugCampaigns.OrderContested(oid);
        _contest(oid);
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        assertTrue(o.status == CONTESTED);
        assertEq(o.disputeDeadline, block.timestamp + ARBITER_TIMEOUT);
    }

    function test_Contest_OneSecondBeforeDeadlineOkAtDeadlineReverts() public {
        (, uint256 oid) = _setupOrder();
        _dispute(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        vm.warp(deadline);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ContestTooLate.selector, oid, deadline));
        plug.contest(oid);
        vm.warp(deadline - 1);
        _contest(oid);
        assertTrue(_status(oid) == CONTESTED);
    }

    function test_Resolve_ArbiterRefundsBuyer() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        _contest(oid);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, true);
        _resolve(oid, true);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_Resolve_ArbiterReleasesToSeller() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        _contest(oid);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, COMMISSION);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, false);
        _resolve(oid, false);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(usdc.balanceOf(buyer), buyerBefore);
        assertEq(usdc.balanceOf(arbiter), 0, "arbiter never paid");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 0);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertTrue(_status(oid) == RELEASED);
        _assertSolvent();
    }

    function test_Resolve_ArbiterBalanceNeverChangesOnEitherOutcome() public {
        uint256 id = _createP();
        uint256 a = _place(id, referrer);
        uint256 b = _place(id, referrer);
        _dispute(a);
        _dispute(b);
        _contest(a);
        _contest(b);
        uint256 arbBefore = usdc.balanceOf(arbiter);
        _resolve(a, true);
        assertEq(usdc.balanceOf(arbiter), arbBefore);
        _resolve(b, false);
        assertEq(usdc.balanceOf(arbiter), arbBefore);
        assertEq(arbBefore, 0);
    }

    function test_Contest_ThenClaimRefundFailsBeforeFourteenDaysWorksAtFourteen() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _dispute(oid);
        vm.warp(block.timestamp + 2 days);
        _contest(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        assertEq(deadline, block.timestamp + ARBITER_TIMEOUT);

        // the old 3-day deadline has long passed for a plain dispute, but contest hardens it to 14 days
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
        plug.claimRefund(oid);

        vm.warp(deadline - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
        plug.claimRefund(oid);

        vm.warp(deadline);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _claim(oid);
        _assertRefundedClean(id, oid, buyerBefore, advBefore);
    }

    function test_Resolve_ArbiterBarredAfterTimeoutEvenIfUnclaimed() public {
        (, uint256 oid) = _setupOrder();
        _dispute(oid);
        _contest(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        vm.warp(block.timestamp + ARBITER_TIMEOUT + 10 days);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ArbiterWindowClosed.selector, oid, deadline));
        plug.resolve(oid, false);
        assertTrue(_status(oid) == CONTESTED);
        _claim(oid); // buyer can still settle
        assertTrue(_status(oid) == REFUNDED);
    }

    function test_Contest_BuyerCannotConfirmOnceContested() public {
        (, uint256 oid) = _setupOrder();
        _dispute(oid);
        _contest(oid);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidOrderStatus.selector, oid, CONTESTED));
        plug.confirm(oid);
    }
}
