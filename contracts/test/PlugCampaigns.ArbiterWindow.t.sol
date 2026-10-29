// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev The 14-day arbiter window after contest: resolve only strictly before disputeDeadline;
///      from the deadline on only claimRefund (buyer) or refund (seller) settle a Contested order.
contract PlugCampaignsArbiterWindowTest is PlugCampaignsV2Base {
    uint256 internal id;
    uint256 internal oid;
    uint64 internal deadline;

    function setUp() public override {
        super.setUp();
        (id, oid) = _setupOrder();
        _dispute(oid);
        skip(1 days);
        _contest(oid);
        deadline = plug.getOrder(oid).disputeDeadline;
        assertEq(deadline, block.timestamp + ARBITER_TIMEOUT);
    }

    function _expectClosed() internal {
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ArbiterWindowClosed.selector, oid, deadline));
    }

    // ------------------------------------------------------------------ strictly before the deadline
    function test_ResolveRefund_AtDeadlineMinusOne_Works() public {
        vm.warp(deadline - 1);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, true);
        _resolve(oid, true);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
        _assertSolvent();
    }

    function test_ResolveRelease_AtDeadlineMinusOne_Works() public {
        vm.warp(deadline - 1);
        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 refBefore = usdc.balanceOf(referrer);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, false);
        _resolve(oid, false);
        assertTrue(_status(oid) == RELEASED);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(usdc.balanceOf(referrer), refBefore + COMMISSION);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ at / after the deadline
    function test_Resolve_AtExactDeadline_RevertsBothWays() public {
        vm.warp(deadline);
        _expectClosed();
        _resolve(oid, true);
        _expectClosed();
        _resolve(oid, false);
        assertTrue(_status(oid) == CONTESTED, "still contested, nothing moved");
        assertEq(plug.escrowedPrice(), PRICE);
        _assertSolvent();
    }

    function test_Resolve_AfterDeadline_RevertsBothWays() public {
        uint256[4] memory offsets = [uint256(1), 1 hours, 14 days, 400 days];
        for (uint256 i; i < offsets.length; i++) {
            vm.warp(uint256(deadline) + offsets[i]);
            _expectClosed();
            _resolve(oid, true);
            _expectClosed();
            _resolve(oid, false);
        }
        assertTrue(_status(oid) == CONTESTED);
        _assertSolvent();
    }

    function test_NonArbiterAfterDeadline_GetsNotArbiterNotWindowError() public {
        vm.warp(deadline + 1);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotArbiter.selector, oid, other));
        plug.resolve(oid, true);
    }

    // ------------------------------------------------------------------ claimRefund at the deadline
    function test_ClaimRefund_BeforeDeadline_RevertsTooEarly() public {
        vm.warp(deadline - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
        plug.claimRefund(oid);
    }

    function test_ClaimRefund_AtExactDeadline_Works() public {
        vm.warp(deadline);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _claim(oid);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
        _assertSolvent();
    }

    function test_ArbiterCannotFrontRun_ArbiterFirstThenBuyerClaims() public {
        vm.warp(deadline);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _expectClosed();
        _resolve(oid, false); // arbiter tries to release to the seller first
        _claim(oid); // buyer's claim in the same timestamp is unaffected
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
        assertEq(usdc.balanceOf(advertiser), advBefore, "seller got nothing");
        assertEq(usdc.balanceOf(referrer), 0);
        _assertSolvent();
    }

    function test_ArbiterCannotFrontRun_BuyerFirstThenArbiterTries() public {
        vm.warp(deadline);
        _claim(oid);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidOrderStatus.selector, oid, REFUNDED));
        plug.resolve(oid, false);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(advertiser), 1_000_000e6 - BUDGET);
        _assertSolvent();
    }

    function test_ArbiterWindow_NoDeadlineGapBetweenResolveAndClaim() public {
        // at deadline-1 the buyer cannot claim but the arbiter can; at deadline the reverse.
        vm.warp(deadline - 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
        plug.claimRefund(oid);
        uint256 snap = vm.snapshotState();
        _resolve(oid, true);
        assertTrue(_status(oid) == REFUNDED);
        vm.revertToState(snap);
        vm.warp(deadline);
        _expectClosed();
        _resolve(oid, true);
        _claim(oid);
        assertTrue(_status(oid) == REFUNDED);
    }

    // ------------------------------------------------------------------ seller refund after the deadline
    function test_SellerRefund_AtAndAfterDeadline_StillWorks() public {
        uint256[3] memory offsets = [uint256(0), 1, 100 days];
        for (uint256 i; i < offsets.length; i++) {
            uint256 snap = vm.snapshotState();
            vm.warp(uint256(deadline) + offsets[i]);
            uint256 buyerBefore = usdc.balanceOf(buyer);
            _sellerRefund(oid);
            assertTrue(_status(oid) == REFUNDED);
            assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
            assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    function test_SellerRefund_AfterDeadline_OnEndedCampaign_ReturnsCommissionToSeller() public {
        vm.prank(advertiser);
        plug.endCampaign(id);
        vm.warp(deadline + 5 days);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _sellerRefund(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + COMMISSION);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        assertEq(usdc.balanceOf(address(plug)), 0);
        _assertSolvent();
    }

    function test_AfterDeadline_ReleaseConfirmContestStillInvalid() public {
        vm.warp(deadline + 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidOrderStatus.selector, oid, CONTESTED));
        plug.confirm(oid);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidOrderStatus.selector, oid, CONTESTED));
        plug.release(oid);
    }

    // ------------------------------------------------------------------ fuzz: exactly one path is open
    function testFuzz_ExactlyOneOfResolveOrClaimIsOpen(uint256 offsetSeed, bool refundBuyer) public {
        uint256 t = block.timestamp + bound(offsetSeed, 0, 2 * uint256(ARBITER_TIMEOUT));
        vm.warp(t);
        uint256 snap = vm.snapshotState();
        if (t < deadline) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
            plug.claimRefund(oid);
            _resolve(oid, refundBuyer);
            assertTrue(_status(oid) == (refundBuyer ? REFUNDED : RELEASED));
        } else {
            _expectClosed();
            _resolve(oid, refundBuyer);
            _claim(oid);
            assertTrue(_status(oid) == REFUNDED);
        }
        _assertSolvent();
        vm.revertToState(snap);
        // seller can always back down regardless of timing
        _sellerRefund(oid);
        assertTrue(_status(oid) == REFUNDED);
        _assertSolvent();
    }
}
