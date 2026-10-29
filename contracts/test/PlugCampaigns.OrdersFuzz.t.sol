// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev Fuzz the protection window (0..30 days), price and bps across the whole order lifecycle.
contract PlugCampaignsOrdersFuzzTest is PlugCampaignsV2Base {
    function _refFor(uint8 kind) internal view returns (address) {
        uint8 k = kind % 6;
        if (k == 0) return address(0);
        if (k == 1) return buyer;
        if (k == 2) return advertiser;
        if (k == 3) return arbiter;
        if (k == 5) return address(plug); // the contract itself is an ineligible referrer
        return referrer;
    }

    function _fund(uint256 price) internal {
        usdc.mint(advertiser, 2 * price);
        usdc.mint(buyer, 2 * price);
    }

    struct Snap {
        uint256 price;
        uint256 commission;
        uint256 advB;
        uint256 buyB;
        uint256 refB;
        uint256 start;
        address ref;
        uint256 id;
        uint256 oid;
    }

    /// Whole lifecycle with exact payouts and conservation, for every window incl. 0 (instant).
    function testFuzz_LifecycleExactPayoutsAndConservation(
        uint256 priceIn,
        uint16 bpsIn,
        uint64 windowIn,
        uint8 path,
        uint8 refKind,
        uint256 offsetSeed
    ) public {
        Snap memory s;
        s.price = bound(priceIn, 1, 1e24);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        uint64 window = uint64(bound(windowIn, 0, 30 days));
        s.ref = _refFor(refKind);
        _fund(s.price);
        {
            bool eligible = s.ref != address(0) && s.ref != buyer && s.ref != advertiser
                && s.ref != address(plug) && !(window != 0 && s.ref == arbiter);
            s.commission = eligible ? (s.price * bps) / 10000 : 0;
        }
        s.id = _createP(s.price, bps, s.price, window); // budget always covers the commission
        s.advB = usdc.balanceOf(advertiser);
        s.buyB = usdc.balanceOf(buyer);
        s.refB = usdc.balanceOf(s.ref);
        s.start = block.timestamp;
        vm.prank(buyer);
        s.oid = plug.buy(s.id, s.ref);

        if (window == 0) {
            _assertInstant(s);
            return;
        }
        _assertPlaced(s, window);
        bool released = _runPath(path % 10, s.oid, window, s.start, offsetSeed);
        _assertFinal(s, released);
    }

    function _assertInstant(Snap memory s) internal view {
        assertEq(s.oid, NO_ORDER);
        assertEq(plug.orderCount(), 0);
        assertEq(usdc.balanceOf(buyer), s.buyB - s.price);
        assertEq(usdc.balanceOf(advertiser), s.advB + s.price);
        if (s.commission != 0) assertEq(usdc.balanceOf(s.ref) - s.refB, s.commission);
        assertEq(plug.getCampaign(s.id).sales, 1);
        assertEq(plug.getCampaign(s.id).commissionPaid, s.commission);
        _assertSolvent();
    }

    function _assertPlaced(Snap memory s, uint64 window) internal view {
        assertEq(usdc.balanceOf(buyer), s.buyB - s.price);
        assertEq(usdc.balanceOf(advertiser), s.advB);
        if (s.ref != buyer && s.ref != address(plug)) assertEq(usdc.balanceOf(s.ref), s.refB);
        assertEq(plug.escrowedPrice(), s.price);
        assertEq(plug.reservedCommission(), s.commission);
        assertEq(plug.getCampaign(s.id).budgetRemaining, s.price - s.commission);
        assertEq(plug.getOrder(s.oid).releaseAt, s.start + window);
        _assertSolvent();
    }

    function _assertFinal(Snap memory s, bool released) internal view {
        PlugCampaigns.Campaign memory c = plug.getCampaign(s.id);
        assertEq(usdc.balanceOf(arbiter), 0, "arbiter never paid");
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(c.pendingOrders, 0);
        assertTrue(_status(s.oid) == (released ? RELEASED : REFUNDED));
        bool refIsPlain = s.ref != buyer && s.ref != advertiser && s.ref != address(plug);
        if (released) {
            assertEq(usdc.balanceOf(advertiser), s.advB + s.price, "seller gets exactly price");
            assertEq(usdc.balanceOf(buyer), s.buyB - s.price);
            assertEq(c.budgetRemaining, s.price - s.commission);
            assertEq(c.sales, 1);
            assertEq(c.commissionPaid, s.commission);
            assertEq(c.refundedCount, 0);
            assertEq(plug.referrerEarnings(s.ref), s.commission);
            if (refIsPlain) assertEq(usdc.balanceOf(s.ref), s.refB + s.commission);
        } else {
            assertEq(usdc.balanceOf(advertiser), s.advB, "seller gets nothing");
            assertEq(usdc.balanceOf(buyer), s.buyB, "buyer made whole");
            assertEq(c.budgetRemaining, s.price, "commission back in budget");
            assertEq(c.sales, 0);
            assertEq(c.commissionPaid, 0);
            assertEq(c.refundedCount, 1);
            assertEq(plug.referrerEarnings(s.ref), 0);
            if (refIsPlain) assertEq(usdc.balanceOf(s.ref), s.refB);
        }
        assertEq(usdc.balanceOf(address(plug)), c.budgetRemaining);
        _assertSolvent();
    }

    function _runPath(uint8 path, uint256 oid, uint64 window, uint256 start, uint256 offsetSeed)
        internal
        returns (bool released)
    {
        if (path == 0) {
            vm.warp(start + bound(offsetSeed, 0, uint256(window) * 2));
            _confirm(oid);
            return true;
        }
        if (path == 1) {
            vm.warp(start + window + bound(offsetSeed, 0, 400 days));
            _release(oid);
            return true;
        }
        if (path == 2) {
            vm.warp(start + bound(offsetSeed, 0, uint256(window) * 2));
            _sellerRefund(oid);
            return false;
        }
        // dispute strictly before releaseAt
        vm.warp(start + bound(offsetSeed, 0, uint256(window) - 1));
        _dispute(oid);
        uint256 d = block.timestamp;
        if (path == 3) {
            vm.warp(d + DISPUTE_PERIOD + bound(offsetSeed, 0, 100 days));
            _claim(oid);
            return false;
        }
        if (path == 7) {
            _confirm(oid);
            return true;
        }
        if (path == 8) {
            _sellerRefund(oid);
            return false;
        }
        vm.warp(d + bound(offsetSeed, 0, DISPUTE_PERIOD - 1));
        _contest(oid);
        uint256 cts = block.timestamp;
        if (path == 4) {
            _resolve(oid, true);
            return false;
        }
        if (path == 5) {
            vm.warp(cts + bound(offsetSeed, 0, uint256(ARBITER_TIMEOUT) - 1)); // arbiter window is strict
            _resolve(oid, false);
            return true;
        }
        if (path == 6) {
            vm.warp(cts + ARBITER_TIMEOUT + bound(offsetSeed, 0, 100 days));
            _claim(oid);
            return false;
        }
        _sellerRefund(oid); // path 9: contested, seller backs down
        return false;
    }

    /// release is possible iff t >= releaseAt; dispute iff t < releaseAt.
    function testFuzz_WindowBoundary(uint64 windowIn, uint256 offsetSeed) public {
        uint64 window = uint64(bound(windowIn, 1, 30 days));
        (, uint256 oid) = _setupOrderWindow(window);
        uint256 start = block.timestamp;
        uint256 t = start + bound(offsetSeed, 0, uint256(window) * 2);
        vm.warp(t);
        uint256 snap = vm.snapshotState();
        if (t >= start + window) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.DisputeTooLate.selector, oid, uint64(start + window)));
            plug.dispute(oid, "x");
            vm.revertToState(snap);
            _release(oid);
            assertTrue(_status(oid) == RELEASED);
        } else {
            vm.prank(other);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ReleaseTooEarly.selector, oid, uint64(start + window)));
            plug.release(oid);
            vm.revertToState(snap);
            _dispute(oid);
            assertTrue(_status(oid) == DISPUTED);
        }
    }

    function _setupOrderWindow(uint64 window) internal returns (uint256 id, uint256 oid) {
        id = _createP(PRICE, BPS, BUDGET, window);
        oid = _place(id, referrer);
    }

    /// claimRefund succeeds iff now >= disputeDeadline (3 days from dispute, or 14 days from contest).
    function testFuzz_ClaimTiming(uint64 windowIn, bool contested, uint256 offsetSeed) public {
        uint64 window = uint64(bound(windowIn, 1, 30 days));
        (, uint256 oid) = _setupOrderWindow(window);
        _dispute(oid);
        if (contested) _contest(oid);
        uint64 deadline = plug.getOrder(oid).disputeDeadline;
        assertEq(deadline, block.timestamp + (contested ? ARBITER_TIMEOUT : DISPUTE_PERIOD));
        uint256 t = block.timestamp + bound(offsetSeed, 0, 2 * uint256(ARBITER_TIMEOUT));
        vm.warp(t);
        if (t < deadline) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.RefundTooEarly.selector, oid, deadline));
            plug.claimRefund(oid);
        } else {
            _claim(oid);
            assertTrue(_status(oid) == REFUNDED);
        }
    }

    /// Several orders sharing one budget with mixed outcomes: budget + paid commissions is conserved.
    function testFuzz_ManyOrdersSharedBudgetConserved(
        uint256 priceIn,
        uint16 bpsIn,
        uint64 windowIn,
        uint256 budgetSeed,
        uint8 outcomes
    ) public {
        uint256 price = bound(priceIn, 1, 1e18);
        uint16 bps = uint16(bound(bpsIn, 1, 5000));
        uint64 window = uint64(bound(windowIn, 1, 30 days));
        uint256 budget = bound(budgetSeed, 0, 3 * price);
        _fund(3 * price);
        uint256 id = _createP(price, bps, budget, window);
        uint256[4] memory oids;
        for (uint256 i; i < 4; i++) oids[i] = _place(id, referrer);
        _assertSolvent();
        uint256 start = block.timestamp;
        uint256 expectedPaid;
        uint256 refunds;
        for (uint256 i; i < 4; i++) {
            if (((outcomes >> (2 * i)) & 3) == 3) _dispute(oids[i]); // before any warp: window may be short
        }
        for (uint256 i; i < 4; i++) {
            uint256 o = oids[i];
            uint256 commission = plug.getOrder(o).commission;
            uint8 kind = (outcomes >> (2 * i)) & 3;
            if (kind == 0) {
                _confirm(o);
                expectedPaid += commission;
            } else if (kind == 1) {
                vm.warp(start + window);
                _release(o);
                expectedPaid += commission;
            } else if (kind == 2) {
                _sellerRefund(o);
                refunds++;
            } else {
                vm.warp(plug.getOrder(o).disputeDeadline);
                _claim(o);
                refunds++;
            }
            _assertSolvent();
        }
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.commissionPaid, expectedPaid);
        assertEq(c.budgetRemaining + c.commissionPaid, budget, "budget + paid == deposited");
        assertEq(c.refundedCount, refunds);
        assertEq(c.sales, 4 - refunds);
        assertEq(c.pendingOrders, 0);
        assertEq(usdc.balanceOf(address(plug)), c.budgetRemaining);
        assertEq(plug.referrerEarnings(referrer), expectedPaid);
    }

    /// A reason is accepted iff it is <= 256 bytes.
    function testFuzz_ReasonLength(uint256 lenSeed) public {
        uint256 len = bound(lenSeed, 0, 1000);
        (, uint256 oid) = _setupOrder();
        vm.prank(buyer);
        if (len > 256) vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.ReasonTooLong.selector, len));
        plug.dispute(oid, string(new bytes(len)));
    }
}
