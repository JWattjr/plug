// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {FailedCommissionBase} from "./PlugCampaigns.Blocklist.t.sol";
import {MisbehavingUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev Commission transfer with non-standard return behaviour (false / no data / oversized data / gas burn).
contract PlugCampaignsBadTokenTest is FailedCommissionBase {
    MisbehavingUSDC internal tok;
    IERC20 internal t;

    function setUp() public override {
        vm.warp(1_000_000);
        tok = new MisbehavingUSDC();
        t = IERC20(address(tok));
        plug = new PlugCampaigns(address(tok));
        address[3] memory who = [advertiser, buyer, other];
        for (uint256 i; i < 3; i++) {
            tok.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            tok.approve(address(plug), type(uint256).max);
        }
    }

    // (b) transfer returning false behaves like a blocklisted referrer
    function test_TransferReturningFalseGivesZeroCommission() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnFalse);
        _buyExpectNoCommission(t, id, referrer);
    }

    function test_FalseThenGoodReferrerStillPaid() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnFalse);
        _buyExpectNoCommission(t, id, referrer);
        _buy(id, aliasRef);
        assertEq(tok.balanceOf(aliasRef), COMMISSION);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET - COMMISSION);
        assertEq(plug.getCampaign(id).commissionPaid, COMMISSION);
        assertEq(plug.referrerEarnings(referrer), 0);
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(tok.balanceOf(address(plug)), 0);
    }

    // Token with no return data (USDT-style) that actually moves funds counts as delivered.
    function test_NoReturnDataTokenCountsAsDelivered() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnNoData);
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, referrer, PRICE, COMMISSION);
        _buy(id, referrer);
        assertEq(tok.balanceOf(referrer), COMMISSION);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(c.budgetRemaining, BUDGET - COMMISSION);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertEq(tok.balanceOf(address(plug)), c.budgetRemaining);
    }

    // (f) non-exact returns are treated as NOT delivered
    function test_ReturnedWordNotExactlyOneIsNotDelivered() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnWordTwo);
        _buyExpectNoCommission(t, id, referrer);
    }

    function test_TwoWordReturnIsNotDelivered() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnTwoWords);
        _buyExpectNoCommission(t, id, referrer);
    }

    function test_HugeReturndataIsHandledAndNotDelivered() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnBlob);
        uint256 g = gasleft();
        _buyExpectNoCommission(t, id, referrer);
        // 64KB returndata must not be copied into the caller's memory: gas stays bounded.
        assertLt(g - gasleft(), 600_000, "bounded gas despite 64KB returndata");
    }

    function test_HugeReturndataBuySucceedsWithTightGasLimit() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.ReturnBlob);
        vm.prank(buyer);
        plug.buy{gas: 400_000}(id, referrer);
        assertEq(plug.getCampaign(id).sales, 1);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
    }

    /// Referrer token hook burns every forwarded gas unit: 1/64 reserve must be enough to finish the sale.
    function test_GasBurningCommissionTransferDoesNotBreakSale() public {
        uint256 id = _create();
        tok.setMode(referrer, MisbehavingUSDC.Mode.BurnAllGas);
        vm.prank(buyer);
        plug.buy{gas: 3_000_000}(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(tok.balanceOf(address(plug)), BUDGET);
        assertEq(tok.balanceOf(advertiser), 1_000_000e6 - BUDGET + PRICE);
    }

    /// (e)-style fuzz over every non-delivering return shape.
    function testFuzz_AnyUndeliveredShapeSaleSucceeds(uint256 price, uint16 bps, uint256 budgetSeed, uint8 shape) public {
        price = bound(price, 1, 1e11);
        bps = uint16(bound(bps, 0, 5000));
        uint256 budget = bound(budgetSeed, 0, 2 * price);
        MisbehavingUSDC.Mode[4] memory modes = [
            MisbehavingUSDC.Mode.ReturnFalse,
            MisbehavingUSDC.Mode.ReturnTwoWords,
            MisbehavingUSDC.Mode.ReturnBlob,
            MisbehavingUSDC.Mode.ReturnWordTwo
        ];
        tok.setMode(referrer, modes[shape % 4]);
        uint256 id = _create(price, bps, budget);
        uint256 advBefore = tok.balanceOf(advertiser);
        _buy(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.budgetRemaining, budget);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(tok.balanceOf(advertiser) - advBefore, price);
        assertEq(tok.balanceOf(address(plug)), c.budgetRemaining);
    }
}
