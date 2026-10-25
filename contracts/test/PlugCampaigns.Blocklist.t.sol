// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsBase} from "./PlugCampaigns.Base.t.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev Shared assertions for "commission could not be delivered but the sale succeeded".
abstract contract FailedCommissionBase is PlugCampaignsBase {
    function _buyExpectNoCommission(IERC20 token, uint256 id, address ref) internal {
        PlugCampaigns.Campaign memory c0 = plug.getCampaign(id);
        uint256 advBefore = token.balanceOf(advertiser);
        uint256 buyerBefore = token.balanceOf(buyer);
        uint256 refBefore = token.balanceOf(ref);
        uint256 plugBefore = token.balanceOf(address(plug));
        uint256 earnedBefore = plug.referrerEarnings(ref);

        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, ref, c0.price, 0);
        vm.prank(buyer);
        plug.buy(id, ref);

        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(token.balanceOf(advertiser) - advBefore, c0.price, "advertiser gets full price");
        assertEq(buyerBefore - token.balanceOf(buyer), c0.price, "buyer pays price");
        assertEq(token.balanceOf(ref), refBefore, "referrer gets nothing");
        assertEq(token.balanceOf(address(plug)), plugBefore, "escrow untouched");
        assertEq(c.budgetRemaining, c0.budgetRemaining, "budget unchanged");
        assertEq(c.commissionPaid, c0.commissionPaid, "commissionPaid unchanged");
        assertEq(plug.referrerEarnings(ref), earnedBefore, "earnings unchanged");
        assertEq(c.sales, c0.sales + 1, "sales +1");
    }
}

contract PlugCampaignsBlocklistTest is FailedCommissionBase {
    BlocklistUSDC internal bl;

    function setUp() public override {
        vm.warp(1_000_000);
        bl = new BlocklistUSDC();
        usdc = bl; // Base helpers only use plug/advertiser/buyer; keep handle consistent
        plug = new PlugCampaigns(address(bl));
        address[3] memory who = [advertiser, buyer, other];
        for (uint256 i; i < 3; i++) {
            bl.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            bl.approve(address(plug), type(uint256).max);
        }
    }

    // (a) blocklisted eligible referrer
    function test_BlocklistedReferrerSaleSucceedsWithZeroCommission() public {
        uint256 id = _create();
        bl.setBlocklisted(referrer, true);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
    }

    function test_BlocklistedReferrerRepeatedBuysAllSucceed() public {
        uint256 id = _create();
        bl.setBlocklisted(referrer, true);
        for (uint256 i; i < 5; i++) _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 5);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
    }

    function test_UnblockedReferrerIsPaidAgain() public {
        uint256 id = _create();
        bl.setBlocklisted(referrer, true);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        bl.setBlocklisted(referrer, false);
        _buy(id, referrer);
        assertEq(bl.balanceOf(referrer), COMMISSION);
        assertEq(plug.referrerEarnings(referrer), COMMISSION);
        assertEq(plug.getCampaign(id).commissionPaid, COMMISSION);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET - COMMISSION);
    }

    // (c) blocklisted advertiser cannot receive proceeds => buy reverts, nothing changes
    function test_BlocklistedAdvertiserBuyReverts() public {
        uint256 id = _create();
        bl.setBlocklisted(advertiser, true);
        uint256 buyerBefore = bl.balanceOf(buyer);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, advertiser));
        vm.prank(buyer);
        plug.buy(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 0);
        assertEq(c.budgetRemaining, BUDGET);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(bl.balanceOf(buyer), buyerBefore);
        assertEq(bl.balanceOf(referrer), 0);
    }

    function test_BlocklistedAdvertiserBuyRevertsWithoutReferrer() public {
        uint256 id = _create();
        bl.setBlocklisted(advertiser, true);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, advertiser));
        vm.prank(buyer);
        plug.buy(id, address(0));
    }

    function test_BlocklistedBuyerBuyReverts() public {
        uint256 id = _create();
        bl.setBlocklisted(buyer, true);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, buyer));
        vm.prank(buyer);
        plug.buy(id, referrer);
        assertEq(plug.getCampaign(id).sales, 0);
    }

    // (d) budget still fully refundable after failed commissions; good referrer later still paid
    function test_BudgetFullyRefundableAfterFailedCommission() public {
        uint256 id = _create();
        bl.setBlocklisted(referrer, true);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        uint256 advBefore = bl.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.CampaignEnded(id, BUDGET);
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(bl.balanceOf(advertiser) - advBefore, BUDGET);
        assertEq(bl.balanceOf(address(plug)), 0);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
        assertFalse(plug.getCampaign(id).active);
    }

    function test_LaterBuyWithGoodReferrerStillPaysAfterFailure() public {
        uint256 id = _create();
        bl.setBlocklisted(referrer, true);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);

        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, buyer, aliasRef, PRICE, COMMISSION);
        _buy(id, aliasRef);
        assertEq(bl.balanceOf(aliasRef), COMMISSION);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.commissionPaid, COMMISSION);
        assertEq(c.budgetRemaining, BUDGET - COMMISSION);
        assertEq(c.sales, 2);
        assertEq(plug.referrerEarnings(aliasRef), COMMISSION);
        assertEq(plug.referrerEarnings(referrer), 0);

        uint256 advBefore = bl.balanceOf(advertiser);
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(bl.balanceOf(advertiser) - advBefore, BUDGET - COMMISSION);
        assertEq(bl.balanceOf(address(plug)), 0);
    }

    function test_FailedCommissionKeepsExactBudgetForNextGoodBuy() public {
        uint256 id = _create(PRICE, BPS, COMMISSION); // budget covers exactly one commission
        bl.setBlocklisted(referrer, true);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        _buy(id, aliasRef);
        assertEq(bl.balanceOf(aliasRef), COMMISSION);
        assertEq(plug.getCampaign(id).budgetRemaining, 0);
    }

    // Issuer blocklists the contract itself: commissions fail softly, refunds revert (documented trust model).
    function test_BlocklistedContractSalesSucceedButRefundReverts() public {
        uint256 id = _create();
        bl.setBlocklisted(address(plug), true);
        _buyExpectNoCommission(IERC20(address(bl)), id, referrer);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, address(plug)));
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertTrue(plug.getCampaign(id).active, "failed refund reverts whole end");
    }

    // (e) fuzz: blocklisted referrer, any price/bps -> sale succeeds, escrow == sum of budgets
    function testFuzz_BlocklistedReferrerSaleAlwaysSucceeds(uint256 price, uint16 bps, uint256 budgetSeed) public {
        price = bound(price, 1, 1e11);
        bps = uint16(bound(bps, 0, 5000));
        uint256 budget = bound(budgetSeed, 0, 2 * price);
        uint256 id = _create(price, bps, budget);
        bl.setBlocklisted(referrer, true);

        uint256 advBefore = bl.balanceOf(advertiser);
        _buy(id, referrer);

        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(c.budgetRemaining, budget);
        assertEq(c.commissionPaid, 0);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(bl.balanceOf(referrer), 0);
        assertEq(bl.balanceOf(advertiser) - advBefore, price);
        assertEq(bl.balanceOf(address(plug)), c.budgetRemaining, "escrow == sum of budgets");
    }

    /// Mixed blocklisted / good referrers across several buys keeps escrow == budgets and earnings == paid.
    function testFuzz_MixedReferrersConserveEscrow(uint256 price, uint16 bps, uint8 pattern) public {
        price = bound(price, 1, 1e11);
        bps = uint16(bound(bps, 0, 5000));
        uint256 id = _create(price, bps, price * 3);
        bl.setBlocklisted(referrer, true);
        for (uint256 i; i < 6; i++) _buy(id, (pattern >> i) & 1 == 1 ? referrer : aliasRef);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(bl.balanceOf(address(plug)), c.budgetRemaining);
        assertEq(plug.referrerEarnings(aliasRef), c.commissionPaid);
        assertEq(bl.balanceOf(aliasRef), c.commissionPaid);
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(c.budgetRemaining + c.commissionPaid, price * 3);
    }
}
