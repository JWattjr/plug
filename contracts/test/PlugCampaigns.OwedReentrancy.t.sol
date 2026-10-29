// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {Reentrant} from "./mocks/Mocks.sol";
import {PlugCampaignsFlexBase} from "./PlugCampaigns.FlexBase.t.sol";

/// @dev Hook + blocklist token (FlexUSDC). A contract buyer / seller with a receive hook tries to
///      re-enter EVERY entry point (buy, endCampaign, topUp, createCampaign, withdrawClosedBudget,
///      claimOwedRefund and all order functions) while claimOwedRefund or a refund pays it out.
///      Every attempt must hit ReentrancyGuardReentrantCall and leave state and credits intact.
contract PlugCampaignsOwedReentrancyTest is PlugCampaignsFlexBase {
    Reentrant internal attacker;
    address internal keeper = makeAddr("keeper");

    uint256 internal constant ACTIONS = 13;
    uint256 internal constant ATTACKER_FUNDS = 1_000e6;

    struct World {
        uint256 orders;
        uint256 campaigns;
        uint256 budget;
        uint256 pending;
        uint256 refunded;
        bool active;
        uint256 escrow;
        uint256 reserved;
        uint256 plugBal;
    }

    function setUp() public override {
        super.setUp();
        attacker = new Reentrant(address(plug), address(flex));
        flex.mint(address(attacker), ATTACKER_FUNDS);
    }

    // ---------- helpers ----------
    function _action(uint256 i) internal pure returns (Reentrant.Action) {
        Reentrant.Action[13] memory all = [
            Reentrant.Action.Buy,
            Reentrant.Action.End,
            Reentrant.Action.TopUp,
            Reentrant.Action.Create,
            Reentrant.Action.Confirm,
            Reentrant.Action.Release,
            Reentrant.Action.Dispute,
            Reentrant.Action.Refund,
            Reentrant.Action.Contest,
            Reentrant.Action.ClaimRefund,
            Reentrant.Action.Resolve,
            Reentrant.Action.Withdraw,
            Reentrant.Action.ClaimOwed
        ];
        return all[i];
    }

    function _world(uint256 id) internal view returns (World memory w) {
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        w.orders = plug.orderCount();
        w.campaigns = plug.campaignCount();
        w.budget = c.budgetRemaining;
        w.pending = c.pendingOrders;
        w.refunded = c.refundedCount;
        w.active = c.active;
        w.escrow = plug.escrowedPrice();
        w.reserved = plug.reservedCommission();
        w.plugBal = token.balanceOf(address(plug));
    }

    /// Nothing the re-entrant call could have changed was changed.
    function _assertWorldUnchangedExceptSettlement(uint256 id, World memory w) internal view {
        World memory n = _world(id);
        assertEq(n.orders, w.orders, "no new order");
        assertEq(n.campaigns, w.campaigns, "no new campaign");
        assertEq(n.active, w.active, "active flag");
        assertEq(n.budget, w.budget, "budget");
    }

    function _assertBlocked() internal view {
        assertEq(attacker.hits(), 1, "hook fired once during payout");
        assertFalse(attacker.lastSuccess(), "re-entrant call failed");
        assertEq(bytes4(attacker.lastRet()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function _attackerBuys(uint256 id) internal returns (uint256 oid) {
        (bool ok, bytes memory ret) = attacker.call_(abi.encodeCall(plug.buy, (id, referrer)));
        assertTrue(ok, "attacker buy");
        oid = abi.decode(ret, (uint256));
    }

    /// Attacker buys, is blocklisted, seller refunds: price owed. Blocklist lifted, hook NOT enabled.
    function _makeOwed(uint256 id) internal returns (uint256 oid) {
        oid = _attackerBuys(id);
        bl.setBlocklisted(address(attacker), true);
        _sellerRefund(oid);
        bl.setBlocklisted(address(attacker), false);
        assertEq(plug.refundOwedOf(oid), PRICE, "owed set up");
    }

    // ---------- re-entry while claimOwedRefund pays the buyer ----------
    function test_ClaimOwed_BuyerHookCannotReenterAnyFunction() public {
        uint256 id = _createP();
        uint256 oid = _makeOwed(id);
        flex.setHooked(address(attacker), true);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            World memory w = _world(id);
            uint256 before = token.balanceOf(address(attacker));
            vm.prank(stranger);
            plug.claimOwedRefund(oid);
            _assertBlocked();
            assertEq(token.balanceOf(address(attacker)), before + PRICE, "paid exactly once");
            assertEq(plug.refundOwedOf(oid), 0, "credit cleared");
            assertEq(plug.owedRefunds(), 0);
            assertTrue(_status(oid) == REFUNDED);
            _assertWorldUnchangedExceptSettlement(id, w);
            assertEq(token.balanceOf(address(plug)), w.plugBal - PRICE);
            _assertSolvent();
            _assertOwedConsistent();
            vm.revertToState(snap);
        }
    }

    function test_ClaimOwed_BuyerClaimsItselfAndCannotReenter() public {
        uint256 id = _createP();
        uint256 oid = _makeOwed(id);
        flex.setHooked(address(attacker), true);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            uint256 before = token.balanceOf(address(attacker));
            (bool ok,) = attacker.call_(abi.encodeCall(plug.claimOwedRefund, (oid)));
            assertTrue(ok, "claim itself succeeded");
            _assertBlocked();
            assertEq(token.balanceOf(address(attacker)), before + PRICE);
            assertEq(plug.owedRefunds(), 0);
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    function test_ClaimOwed_ReenteringClaimOfAnotherOrderIsBlockedAndOtherCreditSurvives() public {
        uint256 id = _createP();
        uint256 o1 = _makeOwed(id);
        uint256 o2 = _makeOwed(id);
        assertEq(plug.owedRefunds(), 2 * PRICE);
        flex.setHooked(address(attacker), true);
        attacker.arm(Reentrant.Action.ClaimOwed, id);
        attacker.setOrder(o2);
        uint256 before = token.balanceOf(address(attacker));
        vm.prank(stranger);
        plug.claimOwedRefund(o1);
        _assertBlocked();
        assertEq(token.balanceOf(address(attacker)), before + PRICE, "only the first credit paid");
        assertEq(plug.refundOwedOf(o1), 0);
        assertEq(plug.refundOwedOf(o2), PRICE, "second credit intact");
        assertEq(plug.owedRefunds(), PRICE);
        _assertSolvent();
        _assertOwedConsistent();
        // second credit is still claimable once the hook stops re-entering
        flex.setHooked(address(attacker), false);
        plug.claimOwedRefund(o2);
        assertEq(token.balanceOf(address(attacker)), before + 2 * PRICE);
        assertEq(plug.owedRefunds(), 0);
        _assertSolvent();
    }

    function test_ClaimOwed_ReenteringWithdrawOfClosedCreditIsBlocked() public {
        // Closed campaign credit (seller blocklisted refund) exists alongside an owed buyer refund.
        (uint256 cid, uint256 coid) = _creditViaSellerRefund(); // ended, advertiser blocklisted, buyer paid
        assertEq(_budget(cid), COMMISSION);
        assertTrue(_status(coid) == REFUNDED);
        _heal();
        uint256 id = _createP();
        uint256 oid = _makeOwed(id);
        flex.setHooked(address(attacker), true);
        attacker.arm(Reentrant.Action.Withdraw, cid);
        attacker.setOrder(oid);
        vm.prank(stranger);
        plug.claimOwedRefund(oid);
        _assertBlocked();
        assertEq(_budget(cid), COMMISSION, "closed credit not drained by re-entry");
        assertEq(plug.refundOwedOf(oid), 0);
        _assertSolvent();
    }

    // ---------- re-entry while a refund pays the buyer (attacker is the buyer) ----------
    function _runRefundReentry(uint8 path) internal {
        uint256 id = _createP();
        uint256 oid = _attackerBuys(id);
        if (path == 1 || path == 2) {
            (bool ok,) = attacker.call_(abi.encodeCall(plug.dispute, (oid, "x")));
            assertTrue(ok, "dispute");
        }
        if (path == 2) _contest(oid);
        if (path == 3) bl.setBlocklisted(advertiser, true);
        if (path == 1) skip(DISPUTE_PERIOD);
        if (path == 3) skip(WINDOW);
        flex.setHooked(address(attacker), true);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            uint256 before = token.balanceOf(address(attacker));
            World memory w = _world(id);
            _doRefund(path, oid);
            _assertBlocked();
            assertTrue(_status(oid) == REFUNDED, "refund completed");
            assertEq(token.balanceOf(address(attacker)), before + PRICE, "refunded exactly once");
            assertEq(plug.owedRefunds(), 0, "delivered, nothing owed");
            assertEq(plug.refundOwedOf(oid), 0);
            assertEq(plug.getCampaign(id).refundedCount, 1);
            assertEq(plug.getCampaign(id).pendingOrders, 0);
            assertEq(plug.orderCount(), w.orders);
            assertEq(plug.campaignCount(), w.campaigns);
            assertEq(_budget(id), BUDGET, "commission returned to active budget exactly once");
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    function _doRefund(uint8 path, uint256 oid) internal {
        if (path == 0) {
            _sellerRefund(oid);
        } else if (path == 1) {
            (bool ok,) = attacker.call_(abi.encodeCall(plug.claimRefund, (oid)));
            assertTrue(ok, "claimRefund");
        } else if (path == 2) {
            _resolve(oid, true);
        } else {
            vm.prank(keeper);
            plug.release(oid); // seller blocklisted => release falls back to a refund
        }
    }

    function test_Refund_SellerRefundToHookedBuyerCannotReenter() public {
        _runRefundReentry(0);
    }

    function test_Refund_ClaimRefundToHookedBuyerCannotReenter() public {
        _runRefundReentry(1);
    }

    function test_Refund_ArbiterRefundToHookedBuyerCannotReenter() public {
        _runRefundReentry(2);
    }

    function test_Refund_ReleaseFallbackToHookedBuyerCannotReenter() public {
        _runRefundReentry(3);
    }

    function test_Refund_HookDuringRefundCannotClaimAnotherOwedCredit() public {
        uint256 id = _createP();
        uint256 o0 = _makeOwed(id);
        uint256 o1 = _attackerBuys(id);
        flex.setHooked(address(attacker), true);
        attacker.arm(Reentrant.Action.ClaimOwed, id);
        attacker.setOrder(o0);
        uint256 before = token.balanceOf(address(attacker));
        _sellerRefund(o1);
        _assertBlocked();
        assertEq(token.balanceOf(address(attacker)), before + PRICE, "only the refund was paid");
        assertEq(plug.refundOwedOf(o0), PRICE, "pre-existing credit intact");
        assertEq(plug.owedRefunds(), PRICE);
        assertEq(plug.refundOwedOf(o1), 0);
        _assertSolvent();
        _assertOwedConsistent();
    }

    // ---------- seller hook fires during a refund whose buyer is blocklisted ----------
    function test_Refund_SellerHookDuringOwedRefundOnEndedCampaignCannotReenter() public {
        uint256 id = plug.campaignCount();
        (bool ok1,) = attacker.call_(
            abi.encodeCall(plug.createCampaign, ("T", "u", PRICE, BPS, BUDGET, _end(), WINDOW, arbiter))
        );
        assertTrue(ok1, "create");
        uint256 oid = _place(id, referrer);
        (bool ok2,) = attacker.call_(abi.encodeCall(plug.endCampaign, (id)));
        assertTrue(ok2, "end");
        _dispute(oid);
        skip(DISPUTE_PERIOD);
        bl.setBlocklisted(buyer, true);
        flex.setHooked(address(attacker), true);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            uint256 before = token.balanceOf(address(attacker));
            uint256 buyerBefore = token.balanceOf(buyer);
            _claim(oid); // buyer-initiated; commission goes to the hooked seller, price becomes owed
            _assertBlocked();
            assertTrue(_status(oid) == REFUNDED, "refund finalized despite hook and blocklist");
            assertEq(token.balanceOf(address(attacker)), before + COMMISSION, "commission delivered once");
            assertEq(token.balanceOf(buyer), buyerBefore, "buyer unpaid while blocklisted");
            assertEq(plug.refundOwedOf(oid), PRICE, "price owed");
            assertEq(plug.owedRefunds(), PRICE);
            assertEq(_budget(id), 0);
            assertFalse(plug.getCampaign(id).active);
            _assertSolvent();
            _assertOwedConsistent();
            vm.revertToState(snap);
        }
    }
}
