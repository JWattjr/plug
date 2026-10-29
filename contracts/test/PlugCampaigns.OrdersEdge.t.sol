// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";
import {MisbehavingUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev Undeliverable payees at settlement time (blocklisted accounts).
contract PlugCampaignsOrdersBlocklistTest is PlugCampaignsV2Base {
    uint256 internal id;
    uint256 internal oid;

    function setUp() public override {
        super.setUp();
        (id, oid) = _setupOrder();
    }

    function _assertBuyerRefundedInstead(uint256 buyerBefore, uint256 advBefore) internal view {
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE, "buyer refunded");
        assertEq(usdc.balanceOf(advertiser), advBefore, "seller not paid");
        assertEq(usdc.balanceOf(referrer), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 0, "no sale recorded");
        assertEq(c.commissionPaid, 0);
        assertEq(c.refundedCount, 1);
        assertEq(c.pendingOrders, 0);
        assertEq(c.budgetRemaining, BUDGET, "commission back to the active budget");
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        _assertSolvent();
    }

    // ---------- blocklisted advertiser at release -> buyer refunded ----------
    function test_BlockedAdvertiser_PermissionlessReleaseRefundsBuyer() public {
        bl.setBlocklisted(advertiser, true);
        vm.warp(_releaseAt(oid));
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        _release(oid);
        _assertBuyerRefundedInstead(buyerBefore, advBefore);
    }

    function test_BlockedAdvertiser_ConfirmRefundsBuyer() public {
        bl.setBlocklisted(advertiser, true);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _confirm(oid);
        _assertBuyerRefundedInstead(buyerBefore, advBefore);
    }

    function test_BlockedAdvertiser_ArbiterReleaseRefundsBuyerAndEmitsResolved() public {
        _dispute(oid);
        _contest(oid);
        bl.setBlocklisted(advertiser, true);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, false);
        _resolve(oid, false);
        _assertBuyerRefundedInstead(buyerBefore, advBefore);
        assertEq(usdc.balanceOf(arbiter), 0);
    }

    function test_BlockedAdvertiser_StillReceivesNewProtectedOrders() public {
        bl.setBlocklisted(advertiser, true);
        // buying a protected order has no seller payee, so it works (unlike instant buys)
        uint256 o2 = _place(id, referrer);
        assertEq(o2, 1);
        _assertSolvent();
    }

    // ---------- blocklisted referrer at release -> commission back to budget ----------
    function test_BlockedReferrer_ReleaseReturnsCommissionToActiveBudget() public {
        bl.setBlocklisted(referrer, true);
        vm.warp(_releaseAt(oid));
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, 0);
        _release(oid);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE, "seller still paid");
        assertEq(usdc.balanceOf(referrer), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, BUDGET, "commission returned to budget");
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        _assertSolvent();
    }

    function test_BlockedReferrer_ConfirmAndArbiterReleaseAlsoReturnCommission() public {
        uint256 o2 = _place(id, referrer);
        bl.setBlocklisted(referrer, true);
        _confirm(oid);
        _dispute(o2);
        _contest(o2);
        _resolve(o2, false);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 2);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(plug.referrerEarnings(referrer), 0);
        _assertSolvent();
    }

    function test_BlockedReferrer_UnblockedBeforeReleaseIsPaid() public {
        bl.setBlocklisted(referrer, true);
        bl.setBlocklisted(referrer, false);
        _confirm(oid);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
    }

    // ---------- blocklisted buyer on refund: finalizes, price owed (v2) ----------
    function _assertOwedState(uint256 buyerBefore) internal view {
        assertEq(usdc.balanceOf(buyer), buyerBefore, "buyer not paid while blocklisted");
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(plug.refundOwedOf(oid), PRICE);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.pendingOrders, 0);
        assertEq(c.refundedCount, 1);
        assertEq(c.budgetRemaining, BUDGET, "commission back to budget");
        assertEq(c.sales, 0);
        assertEq(c.commissionPaid, 0);
        assertEq(usdc.balanceOf(referrer), 0, "referrer gets nothing");
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET + PRICE);
        _assertSolvent();
        _assertOwedConsistent();
    }

    function test_BlockedBuyer_SellerRefundSucceedsAndOwes() public {
        bl.setBlocklisted(buyer, true);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.expectEmit(true, true, false, true, address(plug));
        emit PlugCampaigns.RefundOwed(oid, buyer, PRICE);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderRefunded(oid, PRICE, COMMISSION);
        _sellerRefund(oid);
        _assertOwedState(buyerBefore);
    }

    function test_BlockedBuyer_ClaimRefundSucceedsAndOwes() public {
        _dispute(oid);
        bl.setBlocklisted(buyer, true);
        vm.warp(block.timestamp + DISPUTE_PERIOD);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _claim(oid);
        _assertOwedState(buyerBefore);
    }

    function test_BlockedBuyer_ArbiterRefundSucceedsAndOwes() public {
        _dispute(oid);
        _contest(oid);
        bl.setBlocklisted(buyer, true);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderResolved(oid, true);
        _resolve(oid, true);
        _assertOwedState(buyerBefore);
        assertEq(usdc.balanceOf(arbiter), 0);
    }

    function test_BlockedBuyer_ReleaseStillPaysSeller() public {
        bl.setBlocklisted(buyer, true);
        vm.warp(_releaseAt(oid));
        _release(oid);
        assertTrue(_status(oid) == RELEASED);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
        assertEq(plug.owedRefunds(), 0);
        _assertSolvent();
    }

    function test_BlockedAdvertiserAndBuyer_ReleaseFallbackRefundsAndOwes() public {
        bl.setBlocklisted(advertiser, true);
        bl.setBlocklisted(buyer, true);
        vm.warp(_releaseAt(oid));
        uint256 buyerBefore = usdc.balanceOf(buyer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _release(oid);
        _assertOwedState(buyerBefore);
        assertEq(usdc.balanceOf(advertiser), advBefore, "seller not paid");
    }

    function test_BlockedAdvertiserAndBuyer_ConfirmAndArbiterReleaseFallbackOwe() public {
        uint256 o2 = _place(id, referrer);
        bl.setBlocklisted(advertiser, true);
        bl.setBlocklisted(buyer, true);
        _confirm(oid);
        _dispute(o2);
        _contest(o2);
        _resolve(o2, false);
        assertTrue(_status(oid) == REFUNDED);
        assertTrue(_status(o2) == REFUNDED);
        assertEq(plug.owedRefunds(), 2 * PRICE);
        assertEq(plug.getCampaign(id).sales, 0);
        assertEq(plug.getCampaign(id).refundedCount, 2);
        _assertSolvent();
        _assertOwedConsistent();
    }

    function test_BlockedPlugContract_ReleaseFinalizesAsRefundAndOwes() public {
        bl.setBlocklisted(address(plug), true);
        vm.warp(_releaseAt(oid));
        _release(oid);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(plug.refundOwedOf(oid), PRICE);
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
        // owed refund cannot be paid while the contract itself is blocklisted; credit kept
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, address(plug)));
        plug.claimOwedRefund(oid);
        assertEq(plug.refundOwedOf(oid), PRICE);
        _assertSolvent();
        bl.setBlocklisted(address(plug), false);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        plug.claimOwedRefund(oid);
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
        _assertSolvent();
    }

    function test_BlockedPlugContract_SellerRefundFinalizesAndOwes() public {
        bl.setBlocklisted(address(plug), true);
        _sellerRefund(oid);
        assertTrue(_status(oid) == REFUNDED);
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(plug.getCampaign(id).refundedCount, 1);
        _assertSolvent();
        _assertOwedConsistent();
    }

    function test_BlockedArbiter_IsIrrelevant() public {
        bl.setBlocklisted(arbiter, true);
        _dispute(oid);
        _contest(oid);
        _resolve(oid, true);
        assertTrue(_status(oid) == REFUNDED);
    }
}

/// @dev Same settlement fallbacks with a non-reverting, non-standard token (transfer returns false).
contract PlugCampaignsOrdersBadTokenTest is PlugCampaignsV2Base {
    MisbehavingUSDC internal tok;
    uint256 internal id;
    uint256 internal oid;

    function setUp() public override {
        vm.warp(1_000_000);
        tok = new MisbehavingUSDC();
        token = IERC20(address(tok));
        plug = new PlugCampaigns(address(tok));
        address[3] memory who = [advertiser, buyer, other];
        for (uint256 i; i < 3; i++) {
            tok.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            tok.approve(address(plug), type(uint256).max);
        }
        (id, oid) = _setupOrder();
    }

    function test_ReturnFalseAdvertiser_ReleaseRefundsBuyer() public {
        tok.setMode(advertiser, MisbehavingUSDC.Mode.ReturnFalse);
        vm.warp(_releaseAt(oid));
        uint256 buyerBefore = tok.balanceOf(buyer);
        _release(oid);
        assertEq(tok.balanceOf(buyer), buyerBefore + PRICE);
        assertTrue(_status(oid) == REFUNDED);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 0);
        assertEq(c.refundedCount, 1);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(tok.balanceOf(address(plug)), BUDGET);
        _assertSolvent();
    }

    function test_WordTwoAdvertiser_ConfirmRefundsBuyer() public {
        tok.setMode(advertiser, MisbehavingUSDC.Mode.ReturnWordTwo);
        _confirm(oid);
        assertTrue(_status(oid) == REFUNDED);
        _assertSolvent();
    }

    function test_BurnAllGasAdvertiser_ReleaseStillRefundsBuyer() public {
        tok.setMode(advertiser, MisbehavingUSDC.Mode.BurnAllGas);
        vm.warp(_releaseAt(oid));
        vm.prank(other);
        plug.release{gas: 20_000_000}(oid);
        assertTrue(_status(oid) == REFUNDED);
        _assertSolvent();
    }

    function test_ReturnFalseReferrer_ReleaseReturnsCommissionToBudget() public {
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnFalse);
        vm.warp(_releaseAt(oid));
        uint256 advBefore = tok.balanceOf(advertiser);
        _release(oid);
        assertEq(tok.balanceOf(advertiser), advBefore + PRICE);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(plug.referrerEarnings(referrer), 0);
        _assertSolvent();
    }

    function test_NoReturnDataReferrer_CountsAsDelivered() public {
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnNoData);
        _confirm(oid);
        assertEq(tok.balanceOf(referrer), COMMISSION);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        _assertSolvent();
    }

    function test_ReturnFalseReferrerAfterEnd_CommissionToAdvertiser() public {
        vm.prank(advertiser);
        plug.endCampaign(id);
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnFalse);
        uint256 advBefore = tok.balanceOf(advertiser);
        _confirm(oid);
        assertEq(tok.balanceOf(advertiser), advBefore + PRICE + COMMISSION);
        assertEq(tok.balanceOf(address(plug)), 0);
    }
}
