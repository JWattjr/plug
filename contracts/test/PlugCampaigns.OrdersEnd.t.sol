// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev endCampaign / expiry with open orders, and the order/campaign views.
contract PlugCampaignsOrdersEndTest is PlugCampaignsV2Base {
    uint256 internal id;
    uint256 internal oid;

    function setUp() public override {
        super.setUp();
        (id, oid) = _setupOrder(); // budget 50, order reserves 10 => budgetRemaining 40
    }

    function _end_() internal {
        vm.prank(advertiser);
        plug.endCampaign(id);
    }

    // ---------- (8) endCampaign with open orders ----------
    function test_End_RefundExcludesReservedCommission() public {
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.CampaignEnded(id, BUDGET - COMMISSION);
        _end_();
        assertEq(usdc.balanceOf(advertiser), advBefore + BUDGET - COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), PRICE + COMMISSION, "price and reserved commission stay escrowed");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertFalse(c.active);
        assertEq(c.budgetRemaining, 0);
        assertEq(c.pendingOrders, 1);
        assertEq(plug.reservedCommission(), COMMISSION);
        assertEq(plug.escrowedPrice(), PRICE);
        _assertSolvent();
    }

    function test_End_ThenBuyReverts() public {
        _end_();
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.buy(id, referrer);
    }

    function test_End_ThenSellerRefundSendsCommissionStraightToAdvertiser() public {
        _end_();
        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        _sellerRefund(oid);
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
        assertEq(usdc.balanceOf(advertiser), advBefore + COMMISSION, "commission to advertiser");
        assertEq(usdc.balanceOf(referrer), 0);
        assertEq(usdc.balanceOf(address(plug)), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, 0, "nothing re-credited to a closed campaign");
        assertEq(c.refundedCount, 1);
        assertEq(c.pendingOrders, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        _assertSolvent();
    }

    function test_End_ThenClaimRefundSendsCommissionToAdvertiser() public {
        _end_();
        _dispute(oid);
        vm.warp(block.timestamp + DISPUTE_PERIOD);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _claim(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), 0);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
    }

    function test_End_ThenArbiterRefundSendsCommissionToAdvertiser() public {
        _end_();
        _dispute(oid);
        _contest(oid);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _resolve(oid, true);
        assertEq(usdc.balanceOf(advertiser), advBefore + COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), 0);
        assertEq(usdc.balanceOf(arbiter), 0);
    }

    function test_End_ThenReleasePaysReferrerNormally() public {
        _end_();
        vm.warp(_releaseAt(oid));
        uint256 advBefore = usdc.balanceOf(advertiser);
        _release(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(c.budgetRemaining, 0);
        _assertSolvent();
    }

    function test_End_ThenReleaseWithBlocklistedReferrerSendsCommissionToAdvertiser() public {
        _end_();
        bl.setBlocklisted(referrer, true);
        vm.warp(_releaseAt(oid));
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, 0);
        _release(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE + COMMISSION, "price + undeliverable commission");
        assertEq(usdc.balanceOf(referrer), 0);
        assertEq(usdc.balanceOf(address(plug)), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        _assertSolvent();
    }

    function test_End_OpenOrdersStillConfirmDisputeContestResolveAfterEnd() public {
        uint256 o1 = _place(id, referrer);
        uint256 o2 = _place(id, referrer);
        _end_();
        _confirm(oid); // Pending -> Released
        _dispute(o1);
        _contest(o1);
        _resolve(o1, false); // arbiter releases
        _dispute(o2);
        _contest(o2);
        _resolve(o2, true); // arbiter refunds
        assertTrue(_status(oid) == RELEASED);
        assertTrue(_status(o1) == RELEASED);
        assertTrue(_status(o2) == REFUNDED);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 2);
        assertEq(c.commissionPaid, 2 * COMMISSION);
        assertEq(c.refundedCount, 1);
        assertEq(c.pendingOrders, 0);
        assertEq(usdc.balanceOf(address(plug)), 0);
        assertEq(usdc.balanceOf(arbiter), 0);
        _assertSolvent();
    }

    function test_Expired_BuyRevertsButOpenOrdersStillWork() public {
        uint256 o1 = _place(id, referrer);
        uint256 o2 = _place(id, referrer);
        vm.warp(_end());
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignExpired.selector, id));
        plug.buy(id, referrer);

        _confirm(oid);
        _dispute(o1);
        _contest(o1);
        _resolve(o1, false);
        _dispute(o2);
        _sellerRefund(o2); // campaign still active: commission goes back to budget
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET - 3 * COMMISSION + COMMISSION);
        assertEq(plug.getCampaign(id).sales, 2);
        assertEq(plug.getCampaign(id).refundedCount, 1);
        _assertSolvent();

        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.prank(other);
        plug.endCampaign(id); // anyone, after expiry
        assertEq(usdc.balanceOf(advertiser), advBefore + BUDGET - 2 * COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    function test_Expired_ReleaseAfterEndTimeWorksAndTopUpStillBlockedAfterEnd() public {
        vm.warp(_releaseAt(oid));
        _release(oid);
        _end_();
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.topUp(id, 1);
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    function test_End_ThenRefundWithBlockedAdvertiserLeavesCommissionCreditedToBudget() public {
        _end_();
        bl.setBlocklisted(advertiser, true);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _sellerRefund(oid); // msg.sender is the blocklisted advertiser but only receives, never sends
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE, "buyer still refunded");
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, COMMISSION, "undeliverable commission stays credited");
        assertEq(usdc.balanceOf(address(plug)), COMMISSION);
        _assertSolvent();
        // once the advertiser is unblocked the funds are not lost: the campaign is closed, so
        // there is no path to withdraw them (documented limitation) - conservation still holds.
        assertFalse(c.active);
    }

    // ---------- (10) views ----------
    function test_Views_MixedSequence() public {
        // campaign `id` = A has order 0 (buyer). Add B and more orders.
        uint256 b = _createP();
        vm.prank(other);
        uint256 o1 = plug.buy(id, referrer); // A, other
        uint256 o2 = _place(b, referrer); // B, buyer
        vm.prank(other);
        uint256 o3 = plug.buy(b, referrer); // B, other
        // instant campaign adds no orders
        uint256 inst = _create();
        _buy(inst, referrer);

        assertEq(plug.orderCount(), 4);
        assertEq(o1, 1);
        assertEq(o2, 2);
        assertEq(o3, 3);

        uint256[] memory bb = plug.ordersOfBuyer(buyer);
        assertEq(bb.length, 2);
        assertEq(bb[0], 0);
        assertEq(bb[1], 2);
        uint256[] memory oo = plug.ordersOfBuyer(other);
        assertEq(oo.length, 2);
        assertEq(oo[0], 1);
        assertEq(oo[1], 3);
        assertEq(plug.ordersOfBuyer(referrer).length, 0);

        uint256[] memory a = plug.ordersOfCampaign(id);
        assertEq(a.length, 2);
        assertEq(a[0], 0);
        assertEq(a[1], 1);
        uint256[] memory bs = plug.ordersOfCampaign(b);
        assertEq(bs.length, 2);
        assertEq(bs[0], 2);
        assertEq(bs[1], 3);
        assertEq(plug.ordersOfCampaign(inst).length, 0);

        (uint256 p, uint256 r) = plug.campaignStats(id);
        assertEq(p, 2);
        assertEq(r, 0);

        _sellerRefund(0); // A: refunded
        _dispute(2); // B: disputed
        (p, r) = plug.campaignStats(id);
        assertEq(p, 1);
        assertEq(r, 1);
        (p, r) = plug.campaignStats(b);
        assertEq(p, 2, "disputed and pending are both unsettled");
        assertEq(r, 0);
        (p, r) = plug.campaignStats(inst);
        assertEq(p, 0);
        assertEq(r, 0);

        vm.warp(_releaseAt(1));
        _release(1); // A: released
        (p, r) = plug.campaignStats(id);
        assertEq(p, 0);
        assertEq(r, 1);
        _claim(2); // dispute deadline (3 days) long passed
        (p, r) = plug.campaignStats(b);
        assertEq(p, 1);
        assertEq(r, 1);

        // settled orders remain listed and readable
        assertEq(plug.ordersOfBuyer(buyer).length, 2);
        assertEq(plug.ordersOfCampaign(id).length, 2);
        assertTrue(_status(0) == REFUNDED);
        assertTrue(_status(1) == RELEASED);
        assertTrue(_status(2) == REFUNDED);
        assertTrue(_status(3) == PENDING);
        assertEq(plug.getOrder(3).buyer, other);
        assertEq(plug.getOrder(3).campaignId, b);
        _assertSolvent();
    }

    function test_Views_GetOrderMatchesTermsAfterContest() public {
        _dispute(oid);
        PlugCampaigns.Order memory d = plug.getOrder(oid);
        assertTrue(d.status == DISPUTED);
        assertEq(d.disputeDeadline, uint64(block.timestamp) + DISPUTE_PERIOD);
        _contest(oid);
        PlugCampaigns.Order memory c = plug.getOrder(oid);
        assertTrue(c.status == CONTESTED);
        assertEq(c.disputeDeadline, uint64(block.timestamp) + ARBITER_TIMEOUT);
        assertEq(c.commission, COMMISSION, "reserved commission is stored in the order");
        assertEq(c.price, PRICE);
    }
}
