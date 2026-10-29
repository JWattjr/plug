// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {HookUSDC, Reentrant} from "./mocks/Mocks.sol";

/// @dev Every payee (seller on release, referrer on release, buyer on refund, seller on a
///      closed-campaign refund, seller on endCampaign) tries to re-enter EVERY entry point, including
///      all order functions, from inside the token callback. Each must hit the reentrancy guard.
contract PlugCampaignsReentrancyV2Test is Test {
    PlugCampaigns internal plug;
    HookUSDC internal usdc;
    Reentrant internal attacker;

    address internal advertiser = makeAddr("advertiser");
    address internal buyer = makeAddr("buyer");
    address internal arbiter = makeAddr("arbiter");
    address internal keeper = makeAddr("keeper");

    uint256 internal constant PRICE = 100e6;
    uint256 internal constant BUDGET = 50e6;
    uint256 internal constant COMMISSION = 10e6;
    uint64 internal constant WINDOW = 7 days;

    uint256 internal constant ACTIONS = 11;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new HookUSDC();
        plug = new PlugCampaigns(address(usdc));
        attacker = new Reentrant(address(plug), address(usdc));
        usdc.setHooked(address(attacker), true);
        usdc.mint(advertiser, 1_000e6);
        usdc.mint(buyer, 1_000e6);
        usdc.mint(address(attacker), 1_000e6);
        vm.prank(advertiser);
        usdc.approve(address(plug), type(uint256).max);
        vm.prank(buyer);
        usdc.approve(address(plug), type(uint256).max);
    }

    function _action(uint256 i) internal pure returns (Reentrant.Action) {
        Reentrant.Action[11] memory all = [
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
            Reentrant.Action.Resolve
        ];
        return all[i];
    }

    function _createBy(address adv) internal returns (uint256 id) {
        bytes memory data = abi.encodeCall(
            PlugCampaigns.createCampaign,
            ("t", "u", PRICE, uint16(1000), BUDGET, uint64(block.timestamp + 1 days), WINDOW, arbiter)
        );
        if (adv == address(attacker)) {
            (bool ok, bytes memory ret) = attacker.call_(data);
            assertTrue(ok);
            id = abi.decode(ret, (uint256));
        } else {
            vm.prank(adv);
            (bool ok2, bytes memory ret2) = address(plug).call(data);
            assertTrue(ok2);
            id = abi.decode(ret2, (uint256));
        }
    }

    function _buyBy(address who, uint256 id, address ref) internal returns (uint256 oid) {
        if (who == address(attacker)) {
            (bool ok, bytes memory ret) = attacker.call_(abi.encodeCall(PlugCampaigns.buy, (id, ref)));
            assertTrue(ok);
            oid = abi.decode(ret, (uint256));
        } else {
            vm.prank(who);
            oid = plug.buy(id, ref);
        }
    }

    function _assertBlockedAndSolvent() internal view {
        assertEq(attacker.hits(), 1, "hook fired once");
        assertFalse(attacker.lastSuccess(), "reentry must fail");
        assertEq(bytes4(attacker.lastRet()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        uint256 sum;
        for (uint256 i; i < plug.campaignCount(); i++) sum += plug.getCampaign(i).budgetRemaining;
        assertEq(usdc.balanceOf(address(plug)), sum + plug.reservedCommission() + plug.escrowedPrice() + plug.owedRefunds(), "solvent");
    }

    // ---------- seller receives the price on a permissionless release ----------
    function test_Reentrancy_SellerReceivingPriceOnReleaseCannotReenterAnyFunction() public {
        uint256 id = _createBy(address(attacker));
        uint256 oid = _buyBy(buyer, id, address(0));
        vm.warp(block.timestamp + WINDOW);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            vm.prank(keeper);
            plug.release(oid);
            _assertBlockedAndSolvent();
            assertEq(plug.getCampaign(id).sales, 1, "release itself completed");
            assertEq(usdc.balanceOf(address(attacker)), 1_000e6 - BUDGET + PRICE);
            vm.revertToState(snap);
        }
    }

    function test_Reentrancy_SellerReceivingPriceOnBuyerConfirmCannotReenter() public {
        uint256 id = _createBy(address(attacker));
        uint256 oid = _buyBy(buyer, id, address(0));
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            vm.prank(buyer);
            plug.confirm(oid);
            _assertBlockedAndSolvent();
            vm.revertToState(snap);
        }
    }

    function test_Reentrancy_SellerReceivingPriceOnArbiterReleaseCannotReenter() public {
        uint256 id = _createBy(address(attacker));
        uint256 oid = _buyBy(buyer, id, address(0));
        vm.prank(buyer);
        plug.dispute(oid, "x");
        attacker.setOrder(oid);
        (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.contest, (oid)));
        assertTrue(ok);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            vm.prank(arbiter);
            plug.resolve(oid, false);
            _assertBlockedAndSolvent();
            vm.revertToState(snap);
        }
    }

    // ---------- referrer receives the commission ----------
    function test_Reentrancy_ReferrerReceivingCommissionOnReleaseCannotReenter() public {
        uint256 id = _createBy(advertiser);
        uint256 oid = _buyBy(buyer, id, address(attacker));
        assertEq(plug.getOrder(oid).commission, COMMISSION);
        vm.warp(block.timestamp + WINDOW);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            vm.prank(keeper);
            plug.release(oid);
            _assertBlockedAndSolvent();
            assertEq(plug.referrerEarnings(address(attacker)), COMMISSION);
            assertEq(usdc.balanceOf(address(attacker)), 1_000e6 + COMMISSION, "paid exactly once");
            vm.revertToState(snap);
        }
    }

    // ---------- buyer receives a refund ----------
    function test_Reentrancy_BuyerReceivingRefundFromSellerCannotReenter() public {
        uint256 id = _createBy(advertiser);
        uint256 oid = _buyBy(address(attacker), id, address(0));
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            vm.prank(advertiser);
            plug.refund(oid);
            _assertBlockedAndSolvent();
            assertEq(usdc.balanceOf(address(attacker)), 1_000e6, "refunded exactly once");
            assertEq(plug.getCampaign(id).refundedCount, 1);
            vm.revertToState(snap);
        }
    }

    function test_Reentrancy_BuyerReceivingRefundFromClaimCannotReenter() public {
        uint256 id = _createBy(advertiser);
        uint256 oid = _buyBy(address(attacker), id, address(0));
        (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.dispute, (oid, "x")));
        assertTrue(ok);
        vm.warp(block.timestamp + 3 days);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            (bool ok2,) = attacker.call_(abi.encodeCall(PlugCampaigns.claimRefund, (oid)));
            assertTrue(ok2);
            _assertBlockedAndSolvent();
            assertEq(usdc.balanceOf(address(attacker)), 1_000e6);
            vm.revertToState(snap);
        }
    }

    function test_Reentrancy_BuyerReceivingRefundFromArbiterCannotReenter() public {
        uint256 id = _createBy(advertiser);
        uint256 oid = _buyBy(address(attacker), id, address(0));
        (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.dispute, (oid, "x")));
        assertTrue(ok);
        vm.prank(advertiser);
        plug.contest(oid);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            vm.prank(arbiter);
            plug.resolve(oid, true);
            _assertBlockedAndSolvent();
            vm.revertToState(snap);
        }
    }

    // ---------- seller receives the commission back on a closed campaign ----------
    function test_Reentrancy_SellerReceivingCommissionAfterEndCannotReenter() public {
        uint256 id = _createBy(address(attacker));
        uint256 oid = _buyBy(buyer, id, makeAddr("someReferrer"));
        (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.endCampaign, (id)));
        assertTrue(ok);
        vm.prank(buyer);
        plug.dispute(oid, "x");
        vm.warp(block.timestamp + 3 days);
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            uint256 before_ = usdc.balanceOf(address(attacker));
            vm.prank(buyer);
            plug.claimRefund(oid);
            _assertBlockedAndSolvent();
            assertEq(usdc.balanceOf(address(attacker)), before_ + COMMISSION, "commission to closed-campaign seller");
            vm.revertToState(snap);
        }
    }

    // ---------- seller receives the unreserved budget on endCampaign with open orders ----------
    function test_Reentrancy_SellerReceivingEndRefundWithOpenOrderCannotReenter() public {
        uint256 id = _createBy(address(attacker));
        uint256 oid = _buyBy(buyer, id, makeAddr("someReferrer"));
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < ACTIONS; i++) {
            attacker.arm(_action(i), id);
            attacker.setOrder(oid);
            (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.endCampaign, (id)));
            assertTrue(ok);
            _assertBlockedAndSolvent();
            assertFalse(plug.getCampaign(id).active);
            assertEq(plug.getCampaign(id).pendingOrders, 1, "open order untouched");
            vm.revertToState(snap);
        }
    }
}
