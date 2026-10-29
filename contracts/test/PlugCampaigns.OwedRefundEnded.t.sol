// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev Owed refunds on ended campaigns, double-blocklist retry flows, and fuzzing.
contract PlugCampaignsOwedRefundEndedTest is PlugCampaignsV2Base {
    uint256 internal id;
    uint256 internal oid;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        (id, oid) = _setupOrder();
    }

    function _end(uint256 campaignId) internal {
        vm.prank(advertiser);
        plug.endCampaign(campaignId);
    }

    // ---------- ended campaign, blocklisted buyer: commission to the advertiser ----------
    function test_EndedCampaign_BlockedBuyer_CommissionToAdvertiserPriceOwed() public {
        _end(id);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        bl.setBlocklisted(buyer, true);
        uint256 a = usdc.balanceOf(advertiser);
        uint256 b = usdc.balanceOf(buyer);
        _sellerRefund(oid);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(usdc.balanceOf(advertiser), a + COMMISSION, "commission to advertiser");
        assertEq(c.budgetRemaining, 0, "no residual credit");
        assertFalse(c.active);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 1);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(buyer), b);
        assertEq(plug.refundOwedOf(oid), PRICE);
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(usdc.balanceOf(referrer), 0);
        assertEq(usdc.balanceOf(address(plug)), PRICE);
        _assertSolvent();
        // claim after unblock
        bl.setBlocklisted(buyer, false);
        vm.prank(stranger);
        plug.claimOwedRefund(oid);
        assertEq(usdc.balanceOf(buyer), b + PRICE);
        assertEq(usdc.balanceOf(address(plug)), 0);
        _assertSolvent();
    }

    function test_EndedCampaign_BlockedBuyer_ClaimRefundAndResolvePaths() public {
        uint256 o2 = _place(id, referrer);
        _dispute(oid);
        _dispute(o2);
        _contest(o2);
        _end(id);
        bl.setBlocklisted(buyer, true);
        uint256 a = usdc.balanceOf(advertiser);
        vm.warp(block.timestamp + DISPUTE_PERIOD);
        // o2 is Contested: arbiter window still open (14 days from contest) -> resolve refund
        _resolve(o2, true);
        _claim(oid); // Disputed past 3 days
        assertEq(usdc.balanceOf(advertiser), a + 2 * COMMISSION);
        assertEq(plug.owedRefunds(), 2 * PRICE);
        assertEq(plug.getCampaign(id).refundedCount, 2);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        _assertSolvent();
        _assertOwedConsistent();
    }

    // ---------- blocklisted buyer AND advertiser on an ended campaign ----------
    function test_EndedCampaign_BlockedBuyerAndAdvertiser_IndependentRetries() public {
        _end(id);
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(advertiser, true);
        uint256 b = usdc.balanceOf(buyer);
        uint256 a = usdc.balanceOf(advertiser);

        _sellerRefund(oid); // msg.sender needs no token movement
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(c.budgetRemaining, COMMISSION, "commission stays credited to closed campaign");
        assertFalse(c.active);
        assertEq(plug.refundOwedOf(oid), PRICE);
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(usdc.balanceOf(address(plug)), COMMISSION + PRICE);
        assertEq(usdc.balanceOf(advertiser), a);
        assertEq(usdc.balanceOf(buyer), b);
        _assertSolvent();

        // both retries fail, both credits preserved
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, advertiser));
        plug.withdrawClosedBudget(id);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, buyer));
        plug.claimOwedRefund(oid);
        assertEq(plug.getCampaign(id).budgetRemaining, COMMISSION);
        assertEq(plug.refundOwedOf(oid), PRICE);
        _assertSolvent();

        // unblock only the advertiser: budget credit retries, buyer credit still blocked
        bl.setBlocklisted(advertiser, false);
        vm.prank(stranger);
        plug.withdrawClosedBudget(id);
        assertEq(usdc.balanceOf(advertiser), a + COMMISSION);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, buyer));
        plug.claimOwedRefund(oid);
        assertEq(plug.owedRefunds(), PRICE);
        _assertSolvent();

        // unblock the buyer: owed credit pays out; nothing is left in the contract
        bl.setBlocklisted(buyer, false);
        vm.prank(stranger);
        plug.claimOwedRefund(oid);
        assertEq(usdc.balanceOf(buyer), b + PRICE);
        assertEq(usdc.balanceOf(address(plug)), 0);
        assertEq(plug.owedRefunds(), 0);
        _assertSolvent();
        _assertOwedConsistent();
    }

    function test_EndedCampaign_BlockedBuyerAndAdvertiser_UnblockBuyerFirst() public {
        _end(id);
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(advertiser, true);
        _sellerRefund(oid);
        bl.setBlocklisted(buyer, false);
        plug.claimOwedRefund(oid);
        // the advertiser credit is untouched by the buyer claim
        assertEq(plug.getCampaign(id).budgetRemaining, COMMISSION);
        assertEq(usdc.balanceOf(address(plug)), COMMISSION);
        _assertSolvent();
        bl.setBlocklisted(advertiser, false);
        plug.withdrawClosedBudget(id);
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    function test_EndedCampaign_ReleaseFallback_BlockedBuyerAndAdvertiser() public {
        _end(id);
        bl.setBlocklisted(buyer, true);
        bl.setBlocklisted(advertiser, true);
        vm.warp(_releaseAt(oid));
        _release(oid);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(plug.getCampaign(id).sales, 0);
        assertEq(plug.getCampaign(id).budgetRemaining, COMMISSION);
        assertEq(plug.owedRefunds(), PRICE);
        _assertSolvent();
        _assertOwedConsistent();
    }

    // ---------- fuzz ----------
    /// Any price / commission rate / window, blocklisted buyer, any refund path, active or ended:
    /// the refund always finalizes with the price owed, accounting holds, and the claim pays the buyer once.
    function testFuzz_BlockedBuyerRefund(uint256 price, uint16 bps, uint64 window, uint8 path, bool ended) public {
        price = bound(price, 1, 1e11);
        bps = uint16(bound(bps, 0, 5000));
        window = uint64(bound(window, 1, 30 days));
        path = path % 5;
        uint256 expectedCommission = price * bps / 10000;
        uint256 budget = price * 3;
        uint256 cid = _createP(price, bps, budget, window);
        uint256 o = _place(cid, referrer);
        assertEq(plug.getOrder(o).commission, expectedCommission);

        if (ended) _end(cid);
        bl.setBlocklisted(buyer, true);
        if (path == 4) bl.setBlocklisted(advertiser, true); // release fallback

        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _settleRefund(o, path, window);

        assertTrue(_status(o) == REFUNDED);
        assertEq(usdc.balanceOf(buyer), buyerBefore, "buyer unpaid");
        assertEq(plug.refundOwedOf(o), price);
        assertEq(plug.owedRefunds(), price);
        assertEq(usdc.balanceOf(referrer), 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(cid);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 1);
        assertEq(c.sales, 0);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.escrowedPrice(), PRICE, "only the setUp order is still escrowed");
        assertEq(plug.reservedCommission(), COMMISSION, "only the setUp order's commission is reserved");
        if (ended && path != 4) {
            assertEq(c.budgetRemaining, 0);
            assertEq(usdc.balanceOf(advertiser), advBefore + expectedCommission, "commission to advertiser");
        } else if (ended) {
            assertEq(c.budgetRemaining, expectedCommission, "commission credit retained (advertiser blocklisted)");
        } else {
            assertEq(c.budgetRemaining, budget, "commission back to active budget");
        }
        _assertSolvent();
        _assertOwedConsistent();

        // blocklisted still: claim reverts, credit preserved
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, buyer));
        plug.claimOwedRefund(o);
        assertEq(plug.refundOwedOf(o), price);

        bl.setBlocklisted(buyer, false);
        vm.prank(stranger);
        plug.claimOwedRefund(o);
        assertEq(usdc.balanceOf(buyer), buyerBefore + price);
        assertEq(plug.owedRefunds(), 0);
        _assertSolvent();
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingOwed.selector, o));
        plug.claimOwedRefund(o);
    }

    function _settleRefund(uint256 o, uint8 path, uint64 window) internal {
        if (path == 0) {
            _sellerRefund(o);
        } else if (path == 1) {
            _dispute(o);
            vm.warp(block.timestamp + DISPUTE_PERIOD);
            _claim(o);
        } else if (path == 2) {
            _dispute(o);
            _contest(o);
            _resolve(o, true);
        } else if (path == 3) {
            _dispute(o);
            _contest(o);
            vm.warp(block.timestamp + ARBITER_TIMEOUT);
            _claim(o);
        } else {
            vm.warp(block.timestamp + window);
            _release(o);
        }
    }
}
