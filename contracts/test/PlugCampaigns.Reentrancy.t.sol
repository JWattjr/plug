// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {HookUSDC, Reentrant} from "./mocks/Mocks.sol";

/// @dev Uses an ERC777-style token that calls back into hooked receivers, so every payee
///      (advertiser receiving sale proceeds or refund, referrer receiving commission) gets a chance to reenter.
contract PlugCampaignsReentrancyTest is Test {
    PlugCampaigns internal plug;
    HookUSDC internal usdc;
    Reentrant internal attacker;

    address internal advertiser = makeAddr("advertiser");
    address internal buyer = makeAddr("buyer");

    uint256 internal constant PRICE = 100e6;
    uint256 internal constant BUDGET = 50e6;
    uint256 internal constant COMMISSION = 10e6;

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

    function _create(address adv) internal returns (uint256 id) {
        bytes memory data = abi.encodeCall(
            PlugCampaigns.createCampaign, ("t", "u", PRICE, uint16(1000), BUDGET, uint64(block.timestamp + 1 days), uint64(0), address(0))
        );
        if (adv == address(attacker)) {
            (bool ok, bytes memory ret) = attacker.call_(data);
            assertTrue(ok);
            id = abi.decode(ret, (uint256));
        } else {
            vm.prank(adv);
            id = abi.decode(_raw(data), (uint256));
        }
    }

    function _raw(bytes memory data) internal returns (bytes memory) {
        (bool ok, bytes memory ret) = address(plug).call(data);
        require(ok, "create failed");
        return ret;
    }

    function _assertBlocked() internal view {
        assertEq(attacker.hits(), 1, "hook fired");
        assertFalse(attacker.lastSuccess(), "reentry must fail");
        bytes memory ret = attacker.lastRet();
        assertEq(bytes4(ret), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function _assertConserved(uint256 id) internal view {
        assertEq(usdc.balanceOf(address(plug)), plug.getCampaign(id).budgetRemaining);
    }

    function test_Reentrancy_ReferrerCannotReenterBuy() public {
        uint256 id = _create(advertiser);
        attacker.arm(Reentrant.Action.Buy, id);
        vm.prank(buyer);
        plug.buy(id, address(attacker)); // commission paid -> hook fires
        _assertBlocked();
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(plug.referrerEarnings(address(attacker)), COMMISSION);
        assertEq(usdc.balanceOf(advertiser), 1_000e6 - BUDGET + PRICE, "advertiser got full price");
        _assertConserved(id);
    }

    function test_Reentrancy_ReferrerCannotReenterEndOrTopUp() public {
        uint256 id = _create(advertiser);
        attacker.arm(Reentrant.Action.End, id);
        vm.prank(buyer);
        plug.buy(id, address(attacker));
        _assertBlocked();
        assertTrue(plug.getCampaign(id).active);
        _assertConserved(id);
    }

    function test_Reentrancy_AdvertiserSaleProceedsCannotReenterBuy() public {
        uint256 id = _create(address(attacker));
        attacker.arm(Reentrant.Action.Buy, id);
        vm.prank(buyer);
        plug.buy(id, address(0)); // advertiser receives price -> hook fires
        _assertBlocked();
        assertEq(plug.getCampaign(id).sales, 1);
        assertEq(usdc.balanceOf(address(attacker)), 1_000e6 - BUDGET + PRICE);
        _assertConserved(id);
    }

    function test_Reentrancy_AdvertiserSaleProceedsCannotReenterCreate() public {
        uint256 id = _create(address(attacker));
        attacker.arm(Reentrant.Action.Create, id);
        vm.prank(buyer);
        plug.buy(id, address(0));
        _assertBlocked();
        assertEq(plug.campaignCount(), 1);
    }

    function test_Reentrancy_AdvertiserRefundCannotReenterEnd() public {
        uint256 id = _create(address(attacker));
        uint256 before_ = usdc.balanceOf(address(attacker));
        attacker.arm(Reentrant.Action.End, id);
        (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.endCampaign, (id)));
        assertTrue(ok);
        _assertBlocked();
        assertEq(usdc.balanceOf(address(attacker)), before_ + BUDGET, "refunded exactly once");
        assertFalse(plug.getCampaign(id).active);
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    function test_Reentrancy_AdvertiserRefundCannotReenterTopUp() public {
        uint256 id = _create(address(attacker));
        attacker.arm(Reentrant.Action.TopUp, id);
        (bool ok,) = attacker.call_(abi.encodeCall(PlugCampaigns.endCampaign, (id)));
        assertTrue(ok);
        _assertBlocked();
        assertEq(usdc.balanceOf(address(plug)), 0);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
    }

    function test_Reentrancy_AdvertiserSaleProceedsCannotReenterEnd() public {
        uint256 id = _create(address(attacker));
        attacker.arm(Reentrant.Action.End, id);
        vm.prank(buyer);
        plug.buy(id, address(0));
        _assertBlocked();
        assertTrue(plug.getCampaign(id).active);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
        _assertConserved(id);
    }

    function test_Reentrancy_AdvertiserSaleProceedsCannotReenterTopUp() public {
        uint256 id = _create(address(attacker));
        attacker.arm(Reentrant.Action.TopUp, id);
        vm.prank(buyer);
        plug.buy(id, address(0));
        _assertBlocked();
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
        _assertConserved(id);
    }
}
