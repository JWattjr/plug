// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev Every wrong-caller / wrong-status / wrong-time / wrong-input path reverts with the right custom error.
contract PlugCampaignsOrdersRevertTest is PlugCampaignsV2Base {
    uint256 internal id;
    uint256 internal oid;

    function setUp() public override {
        super.setUp();
        (id, oid) = _setupOrder();
    }

    function _invalidStatus(PlugCampaigns.Status s) internal view returns (bytes memory) {
        return abi.encodeWithSelector(PlugCampaigns.InvalidOrderStatus.selector, oid, s);
    }

    // ---------- (a) wrong caller on EVERY lifecycle function ----------
    function test_WrongCaller_Confirm() public {
        address[4] memory bad = [advertiser, arbiter, other, referrer];
        for (uint256 i; i < 4; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotBuyer.selector, oid, bad[i]));
            plug.confirm(oid);
        }
        assertTrue(_status(oid) == PENDING);
    }

    function test_WrongCaller_Dispute() public {
        address[4] memory bad = [advertiser, arbiter, other, referrer];
        for (uint256 i; i < 4; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotBuyer.selector, oid, bad[i]));
            plug.dispute(oid, "x");
        }
        assertTrue(_status(oid) == PENDING);
    }

    function test_WrongCaller_Refund() public {
        address[4] memory bad = [buyer, arbiter, other, referrer];
        for (uint256 i; i < 4; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotSeller.selector, oid, bad[i]));
            plug.refund(oid);
        }
        assertTrue(_status(oid) == PENDING);
    }

    function test_WrongCaller_Contest() public {
        _dispute(oid);
        address[4] memory bad = [buyer, arbiter, other, referrer];
        for (uint256 i; i < 4; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotSeller.selector, oid, bad[i]));
            plug.contest(oid);
        }
        assertTrue(_status(oid) == DISPUTED);
    }

    function test_WrongCaller_ClaimRefund() public {
        _dispute(oid);
        vm.warp(block.timestamp + DISPUTE_PERIOD);
        address[4] memory bad = [advertiser, arbiter, other, referrer];
        for (uint256 i; i < 4; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotBuyer.selector, oid, bad[i]));
            plug.claimRefund(oid);
        }
        assertTrue(_status(oid) == DISPUTED);
    }

    function test_WrongCaller_Resolve() public {
        _dispute(oid);
        _contest(oid);
        address[5] memory bad = [advertiser, buyer, other, referrer, address(0xdead)];
        for (uint256 i; i < 5; i++) {
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotArbiter.selector, oid, bad[i]));
            plug.resolve(oid, true);
            vm.prank(bad[i]);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotArbiter.selector, oid, bad[i]));
            plug.resolve(oid, false);
        }
        assertTrue(_status(oid) == CONTESTED);
    }

    function test_WrongCaller_ResolveEvenOnNonContestedOrderChecksArbiterFirst() public {
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NotArbiter.selector, oid, buyer));
        plug.resolve(oid, true);
    }

    // ---------- (b) double settlement ----------
    function test_DoubleConfirmReverts() public {
        _confirm(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.confirm(oid);
    }

    function test_DoubleReleaseReverts() public {
        vm.warp(_releaseAt(oid));
        _release(oid);
        vm.prank(other);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.release(oid);
        assertEq(usdc.balanceOf(referrer), COMMISSION, "paid once");
    }

    function test_DoubleRefundReverts() public {
        _sellerRefund(oid);
        vm.prank(advertiser);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.refund(oid);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET, "commission restored once");
    }

    function test_DoubleClaimRefundReverts() public {
        _dispute(oid);
        vm.warp(block.timestamp + DISPUTE_PERIOD);
        _claim(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.claimRefund(oid);
    }

    function test_DoubleResolveReverts() public {
        _dispute(oid);
        _contest(oid);
        _resolve(oid, true);
        vm.prank(arbiter);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.resolve(oid, true);
        vm.prank(arbiter);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.resolve(oid, false);
    }

    function test_ReleasedOrderRejectsEverySettlementAction() public {
        _confirm(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.dispute(oid, "x");
        vm.prank(advertiser);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.refund(oid);
        vm.prank(advertiser);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.contest(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.claimRefund(oid);
        vm.prank(arbiter);
        vm.expectRevert(_invalidStatus(RELEASED));
        plug.resolve(oid, true);
    }

    function test_RefundedOrderRejectsEverySettlementAction() public {
        _sellerRefund(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.confirm(oid);
        vm.prank(other);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.release(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.dispute(oid, "x");
        vm.prank(advertiser);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.contest(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.claimRefund(oid);
        vm.prank(arbiter);
        vm.expectRevert(_invalidStatus(REFUNDED));
        plug.resolve(oid, false);
    }

    // ---------- (c) wrong status ----------
    function test_ReleaseRequiresPending() public {
        _dispute(oid);
        vm.warp(_releaseAt(oid) + 1);
        vm.prank(other);
        vm.expectRevert(_invalidStatus(DISPUTED));
        plug.release(oid);
        assertEq(usdc.balanceOf(referrer), 0);
    }

    function test_ReleaseOnDisputedAndContestedReverts() public {
        _dispute(oid);
        vm.prank(other);
        vm.expectRevert(_invalidStatus(DISPUTED));
        plug.release(oid);
        _contest(oid);
        vm.warp(_releaseAt(oid));
        vm.prank(other);
        vm.expectRevert(_invalidStatus(CONTESTED));
        plug.release(oid);
    }

    function test_DisputeOnDisputedOrContestedReverts() public {
        _dispute(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(DISPUTED));
        plug.dispute(oid, "again");
        _contest(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(CONTESTED));
        plug.dispute(oid, "again");
    }

    function test_ContestRequiresDisputed() public {
        vm.prank(advertiser);
        vm.expectRevert(_invalidStatus(PENDING));
        plug.contest(oid);
        _dispute(oid);
        _contest(oid);
        vm.prank(advertiser);
        vm.expectRevert(_invalidStatus(CONTESTED));
        plug.contest(oid);
    }

    function test_ClaimRefundRequiresDisputedOrContested() public {
        vm.warp(_releaseAt(oid) + 100 days);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(PENDING));
        plug.claimRefund(oid);
    }

    function test_ResolveRequiresContested() public {
        vm.prank(arbiter);
        vm.expectRevert(_invalidStatus(PENDING));
        plug.resolve(oid, true);
        _dispute(oid);
        vm.prank(arbiter);
        vm.expectRevert(_invalidStatus(DISPUTED));
        plug.resolve(oid, false);
    }

    function test_ConfirmOnContestedReverts() public {
        _dispute(oid);
        _contest(oid);
        vm.prank(buyer);
        vm.expectRevert(_invalidStatus(CONTESTED));
        plug.confirm(oid);
    }

    // ---------- (d) wrong time ----------
    function test_DisputeAtReleaseAtReverts() public {
        uint64 releaseAt = _releaseAt(oid);
        vm.warp(releaseAt);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.DisputeTooLate.selector, oid, releaseAt));
        plug.dispute(oid, "late");
        assertTrue(_status(oid) == PENDING);
    }

    function test_DisputeAfterReleaseAtReverts() public {
        uint64 releaseAt = _releaseAt(oid);
        vm.warp(releaseAt + 1 days);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.DisputeTooLate.selector, oid, releaseAt));
        plug.dispute(oid, "late");
    }

    function test_DisputeOneSecondBeforeReleaseAtSucceeds() public {
        vm.warp(_releaseAt(oid) - 1);
        _dispute(oid);
        assertTrue(_status(oid) == DISPUTED);
    }

    function test_ReleaseOneSecondBeforeReleaseAtRevertsAtSucceeds() public {
        uint64 releaseAt = _releaseAt(oid);
        vm.warp(releaseAt - 1);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ReleaseTooEarly.selector, oid, releaseAt));
        plug.release(oid);
        vm.warp(releaseAt);
        _release(oid);
        assertTrue(_status(oid) == RELEASED);
    }

    function test_ContestAfterDeadlineReverts() public {
        _dispute(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        vm.warp(deadline + 1 days);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ContestTooLate.selector, oid, deadline));
        plug.contest(oid);
    }

    function test_ClaimRefundOnFreshDisputeReverts() public {
        _dispute(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
        plug.claimRefund(oid);
    }

    // ---------- (e) reason length ----------
    function test_ReasonLengthBoundary() public {
        vm.prank(buyer);
        plug.dispute(oid, string(new bytes(256)));
        assertTrue(_status(oid) == DISPUTED);

        (, uint256 oid2) = _setupOrder();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ReasonTooLong.selector, 257));
        plug.dispute(oid2, string(new bytes(257)));
        assertTrue(_status(oid2) == PENDING);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ReasonTooLong.selector, 10_000));
        plug.dispute(oid2, string(new bytes(10_000)));
    }

    function test_EmptyReasonAllowed() public {
        vm.prank(buyer);
        plug.dispute(oid, "");
        assertTrue(_status(oid) == DISPUTED);
    }

    // ---------- (f) nonexistent orders ----------
    function test_NonexistentOrderRevertsEverywhere() public {
        uint256 bad = plug.orderCount();
        bytes memory err = abi.encodeWithSelector(PlugCampaigns.OrderNotFound.selector, bad);
        vm.expectRevert(err);
        plug.getOrder(bad);
        vm.startPrank(buyer);
        vm.expectRevert(err);
        plug.confirm(bad);
        vm.expectRevert(err);
        plug.release(bad);
        vm.expectRevert(err);
        plug.dispute(bad, "x");
        vm.expectRevert(err);
        plug.refund(bad);
        vm.expectRevert(err);
        plug.contest(bad);
        vm.expectRevert(err);
        plug.claimRefund(bad);
        vm.expectRevert(err);
        plug.resolve(bad, true);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.OrderNotFound.selector, type(uint256).max));
        plug.getOrder(type(uint256).max); // NO_ORDER sentinel is never a valid order
    }

    function test_NonexistentCampaignViewsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, 99));
        plug.ordersOfCampaign(99);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, 99));
        plug.campaignStats(99);
    }

    function test_BuyWithoutAllowanceOrBalanceRevertsAndLeavesNoOrder() public {
        address poor = makeAddr("poor");
        uint256 before_ = plug.orderCount();
        vm.prank(poor);
        vm.expectRevert();
        plug.buy(id, referrer);
        assertEq(plug.orderCount(), before_);
        assertEq(plug.escrowedPrice(), PRICE);
        assertEq(plug.reservedCommission(), COMMISSION);
        assertEq(plug.getCampaign(id).pendingOrders, 1);
        _assertSolvent();
    }
}
