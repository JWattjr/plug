// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {Reentrant} from "./mocks/Mocks.sol";
import {PlugCampaignsFlexBase} from "./PlugCampaigns.FlexBase.t.sol";

/// @dev The advertiser is a contract whose token hook re-enters PlugCampaigns while
///      withdrawClosedBudget is paying it out.
contract PlugCampaignsWithdrawReentrancyTest is PlugCampaignsFlexBase {
    Reentrant internal attacker;

    function setUp() public override {
        super.setUp();
        attacker = new Reentrant(address(plug), address(flex));
        flex.mint(address(attacker), 1_000_000e6);
    }

    function _attackerCreates() internal returns (uint256 id) {
        id = plug.campaignCount();
        (bool ok,) = attacker.call_(
            abi.encodeCall(plug.createCampaign, ("T", "u", PRICE, BPS, BUDGET, _end(), WINDOW, arbiter))
        );
        assertTrue(ok, "create");
    }

    /// Campaign owned by the attacker contract, ended, buyer refunded while attacker is blocklisted
    /// => COMMISSION credit; blocklist then lifted. Hook NOT yet enabled.
    function _attackerCredit() internal returns (uint256 id) {
        id = _attackerCreates();
        vm.prank(buyer);
        uint256 oid = plug.buy(id, referrer);
        (bool ok,) = attacker.call_(abi.encodeCall(plug.endCampaign, (id)));
        assertTrue(ok, "end");
        bl.setBlocklisted(address(attacker), true);
        _dispute(oid);
        skip(DISPUTE_PERIOD);
        _claim(oid);
        assertEq(_budget(id), COMMISSION);
        bl.setBlocklisted(address(attacker), false);
    }

    function _assertBlocked() internal view {
        assertEq(attacker.hits(), 1, "hook fired once during payout");
        assertFalse(attacker.lastSuccess(), "re-entrant call failed");
        assertEq(bytes4(attacker.lastRet()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_Reenter_WithdrawSameCampaign_Blocked() public {
        uint256 id = _attackerCredit();
        flex.setHooked(address(attacker), true);
        attacker.arm(Reentrant.Action.Withdraw, id);
        uint256 before = token.balanceOf(address(attacker));
        _withdraw(stranger, id);
        _assertBlocked();
        assertEq(token.balanceOf(address(attacker)), before + COMMISSION, "paid exactly once");
        assertEq(_budget(id), 0);
        assertEq(token.balanceOf(address(plug)), 0);
        _assertSolvent();
    }

    function test_Reenter_WithdrawOtherCampaign_BlockedAndOtherCreditSurvives() public {
        uint256 idA = _attackerCredit();
        uint256 idB = _attackerCredit();
        flex.setHooked(address(attacker), true);
        attacker.arm(Reentrant.Action.Withdraw, idB);
        _withdraw(stranger, idA);
        _assertBlocked();
        assertEq(_budget(idA), 0);
        assertEq(_budget(idB), COMMISSION, "second credit not drained by re-entry");
        assertEq(token.balanceOf(address(plug)), COMMISSION);
        _assertSolvent();
        flex.setHooked(address(attacker), false);
        _withdraw(stranger, idB);
        assertEq(token.balanceOf(address(plug)), 0);
    }

    function test_Reenter_BuyEndTopUp_AllBlockedDuringWithdraw() public {
        Reentrant.Action[3] memory acts = [Reentrant.Action.Buy, Reentrant.Action.End, Reentrant.Action.TopUp];
        for (uint256 i; i < acts.length; i++) {
            uint256 snap = vm.snapshotState();
            uint256 id = _attackerCredit();
            flex.setHooked(address(attacker), true);
            attacker.arm(acts[i], id);
            _withdraw(stranger, id);
            _assertBlocked();
            assertEq(_budget(id), 0);
            _assertSolvent();
            vm.revertToState(snap);
        }
    }

    function test_Reenter_SettleOpenOrderDuringWithdraw_Blocked() public {
        // Attacker's closed campaign has a credit AND a separate still-open order.
        uint256 id = _attackerCreates();
        vm.startPrank(buyer);
        uint256 o1 = plug.buy(id, referrer);
        uint256 o2 = plug.buy(id, referrer);
        vm.stopPrank();
        attacker.call_(abi.encodeCall(plug.endCampaign, (id)));
        bl.setBlocklisted(address(attacker), true);
        _dispute(o1);
        skip(DISPUTE_PERIOD);
        _claim(o1);
        bl.setBlocklisted(address(attacker), false);
        assertEq(_budget(id), COMMISSION);

        flex.setHooked(address(attacker), true);
        attacker.setOrder(o2);
        attacker.arm(Reentrant.Action.Refund, id); // seller-refund o2 from inside the payout hook
        _withdraw(stranger, id);
        _assertBlocked();
        assertTrue(_status(o2) == PENDING, "open order untouched by re-entry");
        assertEq(plug.escrowedPrice(), PRICE);
        assertEq(plug.reservedCommission(), COMMISSION);
        _assertSolvent();
    }
}
