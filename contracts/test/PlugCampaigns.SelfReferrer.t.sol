// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";

/// @dev referrer == address(plug) is ineligible on the instant and protected buy paths.
contract PlugCampaignsSelfReferrerTest is PlugCampaignsV2Base {
    function _instant(uint256 price, uint16 bps, uint256 budget) internal returns (uint256 id) {
        vm.prank(advertiser);
        id = plug.createCampaign("T", "u", price, bps, budget, _end(), 0, address(0));
    }

    // ------------------------------------------------------------------ instant
    function test_Instant_ContractReferrer_NoCommissionSaleSucceeds() public {
        uint256 id = _instant(PRICE, BPS, BUDGET);
        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, address(plug), PRICE, 0);
        vm.prank(buyer);
        uint256 oid = plug.buy(id, address(plug));
        assertEq(oid, NO_ORDER);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1, "sale counted");
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, BUDGET, "budget untouched");
        assertEq(plug.referrerEarnings(address(plug)), 0, "referrerEarnings unchanged");
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(usdc.balanceOf(buyer), buyerBefore - PRICE);
        assertEq(usdc.balanceOf(address(plug)), BUDGET, "contract holds exactly the budget");
        _assertSolvent();
    }

    function test_Instant_ContractReferrer_RepeatedSalesNeverEarn() public {
        uint256 id = _instant(PRICE, 5000, BUDGET);
        for (uint256 i; i < 5; i++) _buy(id, address(plug));
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 5);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(plug.referrerEarnings(address(plug)), 0);
        _assertSolvent();
    }

    function test_Instant_ContractReferrer_DoesNotConsumeBudgetThenRealReferrerStillPaid() public {
        uint256 id = _instant(PRICE, BPS, COMMISSION); // budget for exactly one commission
        _buy(id, address(plug));
        _buy(id, referrer);
        assertEq(usdc.balanceOf(referrer), COMMISSION, "budget was still intact for a real referrer");
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        _assertSolvent();
    }

    function test_Instant_ContractReferrer_EndCampaignRefundsFullBudget() public {
        uint256 id = _instant(PRICE, BPS, BUDGET);
        _buy(id, address(plug));
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser), advBefore + BUDGET);
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    // ------------------------------------------------------------------ protected
    function test_Protected_ContractReferrer_ZeroCommissionOrderPlaced() public {
        uint256 id = _createP();
        uint256 buyerBefore = usdc.balanceOf(buyer);
        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.OrderPlaced(0, id, buyer, address(plug), PRICE, 0, uint64(block.timestamp + WINDOW));
        uint256 oid = _place(id, address(plug));
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        assertEq(o.referrer, address(plug), "supplied referrer recorded");
        assertEq(o.commission, 0);
        assertEq(o.price, PRICE);
        assertEq(plug.reservedCommission(), 0);
        assertEq(plug.escrowedPrice(), PRICE);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET, "budget untouched");
        assertEq(usdc.balanceOf(buyer), buyerBefore - PRICE);
        assertEq(usdc.balanceOf(address(plug)), BUDGET + PRICE);
        _assertSolvent();
    }

    function test_Protected_ContractReferrer_ReleaseSettlesWithoutCommission() public {
        uint256 id = _createP();
        uint256 oid = _place(id, address(plug));
        uint256 advBefore = usdc.balanceOf(advertiser);
        skip(WINDOW);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.OrderReleased(oid, PRICE, 0);
        _release(oid);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(usdc.balanceOf(advertiser), advBefore + PRICE);
        assertEq(c.sales, 1);
        assertEq(c.commissionPaid, 0);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(plug.referrerEarnings(address(plug)), 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        _assertSolvent();
    }

    function test_Protected_ContractReferrer_ConfirmAndArbiterReleaseAlsoZeroCommission() public {
        uint256 id = _createP();
        uint256 a = _place(id, address(plug));
        uint256 b = _place(id, address(plug));
        _confirm(a);
        _dispute(b);
        _contest(b);
        _resolve(b, false);
        assertEq(plug.getCampaign(id).commissionPaid, 0);
        assertEq(plug.referrerEarnings(address(plug)), 0);
        assertEq(usdc.balanceOf(address(plug)), BUDGET);
        assertEq(plug.getCampaign(id).sales, 2);
        _assertSolvent();
    }

    function test_Protected_ContractReferrer_RefundReturnsPriceKeepsAccounting() public {
        uint256 id = _createP();
        uint256 oid = _place(id, address(plug));
        uint256 buyerBefore = usdc.balanceOf(buyer);
        _sellerRefund(oid);
        assertEq(usdc.balanceOf(buyer), buyerBefore + PRICE);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.refundedCount, 1);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(plug.referrerEarnings(address(plug)), 0);
        _assertSolvent();
    }

    function test_Protected_ContractReferrer_ThenRealReferrerOrderStillReservesCommission() public {
        uint256 id = _createP(PRICE, BPS, COMMISSION, WINDOW);
        _place(id, address(plug));
        uint256 oid = _place(id, referrer);
        assertEq(plug.getOrder(oid).commission, COMMISSION);
        assertEq(plug.reservedCommission(), COMMISSION);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_ContractReferrer_NeverEarnsAndConservesFunds(
        uint256 priceIn,
        uint16 bpsIn,
        uint64 windowIn,
        uint8 path,
        uint256 budgetIn
    ) public {
        uint256 price = bound(priceIn, 1, 1e24);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        uint64 window = uint64(bound(windowIn, 0, 30 days));
        uint256 budget = bound(budgetIn, 0, 2 * price);
        usdc.mint(advertiser, 2 * price);
        usdc.mint(buyer, 2 * price);
        uint256 id = _createP(price, bps, budget, window);
        uint256 advStart = usdc.balanceOf(advertiser);
        uint256 buyerStart = usdc.balanceOf(buyer);

        vm.prank(buyer);
        uint256 oid = plug.buy(id, address(plug));
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, budget, "budget untouched by contract-referrer buy");
        assertEq(c.commissionPaid, 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(plug.referrerEarnings(address(plug)), 0);

        if (window == 0) {
            assertEq(oid, NO_ORDER);
            assertEq(c.sales, 1);
            assertEq(usdc.balanceOf(advertiser), advStart + price);
            assertEq(usdc.balanceOf(address(plug)), budget);
            _assertSolvent();
            return;
        }
        assertEq(plug.getOrder(oid).commission, 0);
        assertEq(plug.escrowedPrice(), price);
        _assertSolvent();

        bool released;
        if (path % 3 == 0) {
            skip(window);
            _release(oid);
            released = true;
        } else if (path % 3 == 1) {
            _confirm(oid);
            released = true;
        } else {
            _sellerRefund(oid);
        }
        c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, budget);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(address(plug)), 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(plug.reservedCommission(), 0);
        assertEq(usdc.balanceOf(advertiser), released ? advStart + price : advStart);
        assertEq(usdc.balanceOf(buyer), released ? buyerStart - price : buyerStart);
        assertEq(usdc.balanceOf(address(plug)), budget);
        _assertSolvent();
    }
}
