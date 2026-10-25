// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsBase} from "./PlugCampaigns.Base.t.sol";

contract PlugCampaignsLifecycleTest is PlugCampaignsBase {
    // ---------- endCampaign ----------
    function test_End_AdvertiserRefundsRemainingBudgetOnce() public {
        uint256 id = _create();
        _buy(id, referrer);
        uint256 remaining = BUDGET - COMMISSION;
        uint256 advBefore = usdc.balanceOf(advertiser);

        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.CampaignEnded(id, remaining);
        vm.prank(advertiser);
        plug.endCampaign(id);

        assertEq(usdc.balanceOf(advertiser), advBefore + remaining);
        assertEq(usdc.balanceOf(address(plug)), 0);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertFalse(c.active);
        assertEq(c.budgetRemaining, 0);
        assertEq(c.sales, 1); // history preserved
        assertEq(c.commissionPaid, COMMISSION);
    }

    function test_End_SecondCallReverts() public {
        uint256 id = _create();
        vm.prank(advertiser);
        plug.endCampaign(id);
        uint256 bal = usdc.balanceOf(advertiser);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser), bal, "no double refund");
    }

    function test_End_SecondCallByAnyoneAfterExpiryReverts() public {
        uint256 id = _create();
        vm.warp(_end());
        vm.prank(other);
        plug.endCampaign(id);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.endCampaign(id);
    }

    function test_End_NonAdvertiserBeforeEndTimeReverts() public {
        uint256 id = _create();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.Unauthorized.selector, id, other));
        plug.endCampaign(id);
        vm.warp(_end() - 1);
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.Unauthorized.selector, id, other));
        plug.endCampaign(id);
        assertTrue(plug.getCampaign(id).active);
    }

    function test_End_AnyoneAtEndTimeRefundsAdvertiserNotCaller() public {
        uint256 id = _create();
        uint256 advBefore = usdc.balanceOf(advertiser);
        uint256 otherBefore = usdc.balanceOf(other);
        vm.warp(_end()); // exactly at endTime
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.CampaignEnded(id, BUDGET);
        vm.prank(other);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser), advBefore + BUDGET);
        assertEq(usdc.balanceOf(other), otherBefore);
        assertFalse(plug.getCampaign(id).active);
    }

    function test_End_ZeroBudgetEmitsZeroRefund() public {
        uint256 id = _create(PRICE, BPS, 0);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.CampaignEnded(id, 0);
        vm.prank(advertiser);
        plug.endCampaign(id);
    }

    function test_End_AfterBudgetExhaustedRefundsZero() public {
        uint256 id = _create(PRICE, BPS, COMMISSION);
        _buy(id, referrer);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser), advBefore);
    }

    // ---------- topUp ----------
    function test_TopUp_AdvertiserIncreasesBudgetAndEmits() public {
        uint256 id = _create();
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.ToppedUp(id, 25e6);
        vm.prank(advertiser);
        plug.topUp(id, 25e6);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET + 25e6);
        assertEq(usdc.balanceOf(address(plug)), BUDGET + 25e6);
        assertEq(usdc.balanceOf(advertiser), advBefore - 25e6);
    }

    function test_TopUp_ZeroAmountAllowed() public {
        uint256 id = _create();
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.ToppedUp(id, 0);
        vm.prank(advertiser);
        plug.topUp(id, 0);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
    }

    function test_TopUp_EnablesCommissionAfterBudgetShortfall() public {
        uint256 id = _create(PRICE, BPS, 0);
        _buy(id, referrer);
        assertEq(usdc.balanceOf(referrer), 0);
        vm.prank(advertiser);
        plug.topUp(id, COMMISSION);
        _buy(id, referrer);
        assertEq(usdc.balanceOf(referrer), COMMISSION);
    }

    function test_TopUp_NonAdvertiserReverts() public {
        uint256 id = _create();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.Unauthorized.selector, id, other));
        plug.topUp(id, 1e6);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
    }

    function test_TopUp_AfterEndReverts() public {
        uint256 id = _create();
        vm.prank(advertiser);
        plug.endCampaign(id);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.topUp(id, 1e6);
    }

    function test_TopUp_AfterExpiryButStillActiveSucceedsAndIsRefundable() public {
        uint256 id = _create();
        vm.warp(_end() + 1);
        vm.prank(advertiser);
        plug.topUp(id, 5e6);
        uint256 advBefore = usdc.balanceOf(advertiser);
        vm.prank(other);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser), advBefore + BUDGET + 5e6);
    }

    // ---------- collusion / economics ----------
    /// Seller (advertiser) buying from itself through an alias referrer nets exactly zero for the entity.
    function test_Collusion_SellerSelfBuyViaAliasNetsZero() public {
        uint256 entityBefore = usdc.balanceOf(advertiser) + usdc.balanceOf(aliasRef);
        uint256 id = _create(PRICE, 5000, BUDGET);
        uint256 entityMid = usdc.balanceOf(advertiser) + usdc.balanceOf(aliasRef);
        assertEq(entityMid, entityBefore - BUDGET);

        vm.expectEmit(true, true, true, true, address(plug));
        emit PlugCampaigns.Purchase(id, advertiser, aliasRef, PRICE, PRICE / 2);
        vm.prank(advertiser);
        plug.buy(id, aliasRef); // aliasRef is a distinct address => eligible, paid from own escrow

        assertEq(usdc.balanceOf(aliasRef), PRICE / 2);
        uint256 escrow = plug.getCampaign(id).budgetRemaining;
        assertEq(usdc.balanceOf(advertiser) + usdc.balanceOf(aliasRef) + escrow, entityBefore, "no value created");

        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser) + usdc.balanceOf(aliasRef), entityBefore, "net zero after refund");
    }

    /// Third-party buyer who is also the referrer loses the full price.
    function test_Collusion_ThirdPartyBuyerAsOwnReferrerLosesPrice() public {
        uint256 id = _create(PRICE, 5000, BUDGET);
        uint256 before_ = usdc.balanceOf(buyer);
        _buy(id, buyer);
        assertEq(before_ - usdc.balanceOf(buyer), PRICE);
    }

    /// Third-party buyer colluding via an alias referrer still loses price - commission >= 50% of price.
    function test_Collusion_ThirdPartyBuyerViaAliasLoses() public {
        uint256 id = _create(PRICE, 5000, BUDGET);
        uint256 entityBefore = usdc.balanceOf(buyer) + usdc.balanceOf(aliasRef);
        _buy(id, aliasRef);
        uint256 entityAfter = usdc.balanceOf(buyer) + usdc.balanceOf(aliasRef);
        assertEq(entityBefore - entityAfter, PRICE - PRICE / 2);
        assertGe((entityBefore - entityAfter) * 2, PRICE);
    }

    function test_SelfReferral_BuyerEqualsReferrerYieldsNoCommission() public {
        uint256 id = _create();
        uint256 before_ = usdc.balanceOf(buyer);
        _buy(id, buyer);
        assertEq(usdc.balanceOf(buyer), before_ - PRICE);
        assertEq(plug.referrerEarnings(buyer), 0);
        assertEq(plug.getCampaign(id).budgetRemaining, BUDGET);
    }
}
