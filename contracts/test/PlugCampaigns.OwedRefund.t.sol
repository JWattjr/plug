// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev v2 "owed refund" semantics with a blocklisted buyer: every refund path finalizes,
///      the price becomes owed, and claimOwedRefund pays it to the buyer once deliverable.
contract PlugCampaignsOwedRefundTest is PlugCampaignsV2Base {
    uint256 internal id;
    uint256 internal oid;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        (id, oid) = _setupOrder();
    }

    // ---------- shared assertions ----------
    /// Order is Refunded, price owed, buyer unpaid, commission back in the (active) budget.
    function _assertActiveOwed(uint256 orderId, uint256 buyerBefore) internal view {
        assertTrue(_status(orderId) == REFUNDED, "status Refunded");
        assertEq(usdc.balanceOf(buyer), buyerBefore, "buyer unpaid while blocklisted");
        assertEq(plug.refundOwedOf(orderId), PRICE, "refundOwedOf == price");
        assertEq(plug.owedRefunds(), PRICE, "owedRefunds == price");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.pendingOrders, 0, "pendingOrders");
        assertEq(c.refundedCount, 1, "refundedCount");
        assertEq(c.budgetRemaining, BUDGET, "commission back to budget");
        assertEq(c.sales, 0);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(usdc.balanceOf(referrer), 0, "referrer gets nothing");
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET + PRICE);
        _assertSolvent();
        _assertOwedConsistent();
    }

    // ---------- each settlement path with a blocklisted buyer ----------
    function test_Owed_SellerRefund() public {
        bl.setBlocklisted(buyer, true);
        uint256 b = usdc.balanceOf(buyer);
        vm.expectEmit(true, true, false, true, address(plug));
        emit PlugCampaigns.RefundOwed(oid, buyer, PRICE);
        _sellerRefund(oid);
        _assertActiveOwed(oid, b);
    }

    function test_Owed_ClaimRefund() public {
        _dispute(oid);
        bl.setBlocklisted(buyer, true);
        vm.warp(block.timestamp + DISPUTE_PERIOD);
        uint256 b = usdc.balanceOf(buyer);
        _claim(oid);
        _assertActiveOwed(oid, b);
    }

    function test_Owed_ClaimRefundAfterContestTimeout() public {
        _dispute(oid);
        _contest(oid);
        bl.setBlocklisted(buyer, true);
        vm.warp(block.timestamp + ARBITER_TIMEOUT);
        uint256 b = usdc.balanceOf(buyer);
        _claim(oid);
        _assertActiveOwed(oid, b);
    }

    function test_Owed_ResolveRefundTrue() public {
        _dispute(oid);
        _contest(oid);
        bl.setBlocklisted(buyer, true);
        uint256 b = usdc.balanceOf(buyer);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, true);
        _resolve(oid, true);
        _assertActiveOwed(oid, b);
    }

    function test_Owed_ReleaseFallbackWhenSellerUnreachable_Release() public {
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(advertiser, true);
        vm.warp(_releaseAt(oid));
        uint256 b = usdc.balanceOf(buyer);
        uint256 a = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        _release(oid);
        _assertActiveOwed(oid, b);
        assertEq(usdc.balanceOf(advertiser), a, "seller unpaid");
    }

    function test_Owed_ReleaseFallbackWhenSellerUnreachable_Confirm() public {
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(advertiser, true);
        uint256 b = usdc.balanceOf(buyer);
        // confirm is called by the buyer itself; the buyer's own blocklist does not stop the call
        _confirm(oid);
        _assertActiveOwed(oid, b);
    }

    function test_Owed_ReleaseFallbackWhenSellerUnreachable_ArbiterRelease() public {
        _dispute(oid);
        _contest(oid);
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(advertiser, true);
        uint256 b = usdc.balanceOf(buyer);
        _resolve(oid, false);
        _assertActiveOwed(oid, b);
    }

    function test_Owed_BuyerWithDeliverableBalanceIsPaidDirectlyNoOwed() public {
        vm.recordLogs();
        uint256 b = usdc.balanceOf(buyer);
        _sellerRefund(oid);
        assertEq(usdc.balanceOf(buyer), b + PRICE);
        assertEq(plug.owedRefunds(), 0);
        assertEq(plug.refundOwedOf(oid), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != PlugCampaigns.RefundOwed.selector, "no RefundOwed when delivered");
        }
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingOwed.selector, oid));
        plug.claimOwedRefund(oid);
    }

    // ---------- claimOwedRefund ----------
    function test_Claim_WhileBuyerStillBlocklistedRevertsAndPreservesCredit() public {
        bl.setBlocklisted(buyer, true);
        _sellerRefund(oid);
        uint256 b = usdc.balanceOf(buyer);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, buyer));
        plug.claimOwedRefund(oid);
        assertEq(plug.refundOwedOf(oid), PRICE, "credit preserved");
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(usdc.balanceOf(buyer), b);
        assertEq(usdc.balanceOf(address(plug)), BUDGET + PRICE);
        _assertSolvent();
    }

    function test_Claim_AfterUnblockAnyonePaysExactlyTheBuyer() public {
        bl.setBlocklisted(buyer, true);
        _sellerRefund(oid);
        bl.setBlocklisted(buyer, false);
        uint256 b = usdc.balanceOf(buyer);
        uint256 s = usdc.balanceOf(stranger);
        vm.expectEmit(true, true, false, true, address(plug));
        emit PlugCampaigns.OwedRefundPaid(oid, buyer, PRICE);
        vm.prank(stranger);
        plug.claimOwedRefund(oid);
        assertEq(usdc.balanceOf(buyer), b + PRICE, "buyer paid exactly the price");
        assertEq(usdc.balanceOf(stranger), s, "caller gets nothing");
        assertEq(plug.refundOwedOf(oid), 0);
        assertEq(plug.owedRefunds(), 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        _assertSolvent();
        _assertOwedConsistent();
    }

    function test_Claim_SecondCallRevertsNothingOwed() public {
        bl.setBlocklisted(buyer, true);
        _sellerRefund(oid);
        bl.setBlocklisted(buyer, false);
        plug.claimOwedRefund(oid);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingOwed.selector, oid));
        plug.claimOwedRefund(oid);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingOwed.selector, oid));
        plug.claimOwedRefund(oid);
    }

    function test_Claim_CallerRoleIsIrrelevantAndFundsAlwaysGoToBuyer() public {
        address[5] memory callers = [stranger, advertiser, arbiter, referrer, buyer];
        for (uint256 i; i < callers.length; i++) {
            uint256 snap = vm.snapshotState();
            bl.setBlocklisted(buyer, true);
            _sellerRefund(oid);
            bl.setBlocklisted(buyer, false);
            uint256 b = usdc.balanceOf(buyer);
            uint256 c = usdc.balanceOf(callers[i]);
            vm.prank(callers[i]);
            plug.claimOwedRefund(oid);
            assertEq(usdc.balanceOf(buyer), b + PRICE);
            if (callers[i] != buyer) assertEq(usdc.balanceOf(callers[i]), c, "caller unchanged");
            vm.revertToState(snap);
        }
    }

    function test_Claim_StrangerCannotRedirectFundsEvenIfStrangerIsBlocklistedOrFunded() public {
        bl.setBlocklisted(buyer, true);
        _sellerRefund(oid);
        bl.setBlocklisted(buyer, false);
        // a blocklisted caller can still trigger the claim; funds go to the buyer, not msg.sender
        bl.setBlocklisted(stranger, true);
        vm.prank(stranger);
        plug.claimOwedRefund(oid);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6, "buyer made whole");
    }

    function test_Claim_BadIdsAndNothingOwed() public {
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.OrderNotFound.selector, 99));
        plug.claimOwedRefund(99);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.OrderNotFound.selector, 99));
        plug.refundOwedOf(99);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingOwed.selector, oid));
        plug.claimOwedRefund(oid); // Pending, nothing owed
        _confirm(oid); // Released
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingOwed.selector, oid));
        plug.claimOwedRefund(oid);
    }

    function test_Claim_OrdersAreIndependentAndRouteToTheirOwnBuyer() public {
        vm.prank(other);
        uint256 o2 = plug.buy(id, referrer); // buyer2 == other
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(other, true);
        _sellerRefund(oid);
        _sellerRefund(o2);
        assertEq(plug.owedRefunds(), 2 * PRICE);
        bl.setBlocklisted(other, false); // only o2's buyer is reachable
        uint256 ob = usdc.balanceOf(other);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, buyer));
        plug.claimOwedRefund(oid);
        plug.claimOwedRefund(o2);
        assertEq(usdc.balanceOf(other), ob + PRICE);
        assertEq(plug.refundOwedOf(oid), PRICE);
        assertEq(plug.refundOwedOf(o2), 0);
        assertEq(plug.owedRefunds(), PRICE);
        _assertSolvent();
        _assertOwedConsistent();
        bl.setBlocklisted(buyer, false);
        plug.claimOwedRefund(oid);
        assertEq(plug.owedRefunds(), 0);
        _assertSolvent();
    }

    function test_Claim_UnblockedBeforeAnyRefundNeverOwes() public {
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(buyer, false);
        _sellerRefund(oid);
        assertEq(plug.owedRefunds(), 0);
    }
}
