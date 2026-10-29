// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";
import {FlexUSDC} from "./mocks/FlexMocks.sol";
import {PlugCampaignsFlexBase} from "./PlugCampaigns.FlexBase.t.sol";

/// @dev withdrawClosedBudget: how closed-campaign credits arise, who can retry, and what it never touches.
contract PlugCampaignsWithdrawClosedTest is PlugCampaignsFlexBase {
    // ------------------------------------------------------------------ credit creation
    function _assertCredit(uint256 id, uint256 oid, bool refunded) internal view {
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertFalse(c.active, "campaign closed");
        assertEq(c.budgetRemaining, COMMISSION, "commission credited to inactive campaign");
        assertTrue(_status(oid) == (refunded ? REFUNDED : RELEASED));
        assertEq(plug.reservedCommission(), 0);
        assertEq(plug.escrowedPrice(), 0);
        assertEq(token.balanceOf(address(plug)), COMMISSION, "credit is all the contract holds");
        _assertSolvent();
    }

    function test_Credit_AfterBuyerClaimWithBlocklistedAdvertiser() public {
        (uint256 id, uint256 oid) = _creditViaClaim();
        _assertCredit(id, oid, true);
    }

    function test_Credit_AfterArbiterRefundWithBlocklistedAdvertiser() public {
        (uint256 id, uint256 oid) = _creditViaResolve();
        _assertCredit(id, oid, true);
    }

    function test_Credit_AfterSellerRefundWithBlocklistedAdvertiser() public {
        (uint256 id, uint256 oid) = _creditViaSellerRefund();
        _assertCredit(id, oid, true);
    }

    function test_Credit_AfterReleaseWithUndeliverableCommission() public {
        uint256 advBefore = token.balanceOf(advertiser);
        (uint256 id, uint256 oid) = _creditViaRelease();
        _assertCredit(id, oid, false);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        // net of the budget deposited (BUDGET) and the unreserved refund at close (BUDGET - COMMISSION)
        assertEq(token.balanceOf(advertiser), advBefore - COMMISSION + PRICE, "seller got the price");
        assertEq(c.commissionPaid, 0, "undelivered commission not counted");
        assertEq(plug.referrerEarnings(referrer), 0);
        assertEq(c.sales, 1);
    }

    // ------------------------------------------------------------------ stranger while blocklisted
    function test_Stranger_RevertsWhileAdvertiserBlocklisted_CreditPreserved() public {
        (uint256 id,) = _creditViaClaim();
        uint256 plugBal = token.balanceOf(address(plug));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, advertiser));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), COMMISSION, "credit preserved");
        assertEq(token.balanceOf(address(plug)), plugBal, "nothing left the contract");
        assertEq(token.balanceOf(stranger), 0, "stranger gets nothing");
        _assertSolvent();
    }

    function test_AdvertiserItself_AlsoRevertsWhileBlocklisted() public {
        (uint256 id,) = _creditViaClaim();
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, advertiser));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), COMMISSION);
    }

    function test_Stranger_RevertsWhileContractBlocklisted_CreditPreserved() public {
        (uint256 id,) = _creditViaClaim();
        bl.setBlocklisted(advertiser, false);
        bl.setBlocklisted(address(plug), true);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, address(plug)));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), COMMISSION);
        bl.setBlocklisted(address(plug), false);
        _withdraw(stranger, id);
        assertEq(_budget(id), 0);
    }

    function test_QuotaExhaustedTransferFailure_RevertsAndPreservesCredit() public {
        (uint256 id,) = _creditViaRelease(); // advertiser quota is now exhausted
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(FlexUSDC.QuotaExhausted.selector, advertiser));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), COMMISSION);
        _assertSolvent();
    }

    // ------------------------------------------------------------------ after unblocking
    function _withdrawAndCheck(uint256 id, address caller) internal {
        _heal();
        uint256 advBefore = token.balanceOf(advertiser);
        uint256 callerBefore = token.balanceOf(caller);
        uint256 refBefore = token.balanceOf(referrer);
        uint256 plugBefore = token.balanceOf(address(plug));
        vm.expectEmit(true, false, false, true, address(plug));
        emit PlugCampaigns.ClosedBudgetWithdrawn(id, COMMISSION);
        _withdraw(caller, id);
        assertEq(token.balanceOf(advertiser), advBefore + COMMISSION, "advertiser paid exactly the credit");
        if (caller != advertiser) assertEq(token.balanceOf(caller), callerBefore, "caller never paid");
        assertEq(token.balanceOf(referrer), refBefore, "referrer never paid");
        assertEq(token.balanceOf(address(plug)), plugBefore - COMMISSION);
        assertEq(_budget(id), 0);
        assertEq(token.balanceOf(address(plug)), 0);
        _assertSolvent();
    }

    function test_AfterUnblock_StrangerCallPaysAdvertiser_Claim() public {
        (uint256 id,) = _creditViaClaim();
        _withdrawAndCheck(id, stranger);
    }

    function test_AfterUnblock_BuyerCallPaysAdvertiser_Resolve() public {
        (uint256 id,) = _creditViaResolve();
        _withdrawAndCheck(id, buyer);
    }

    function test_AfterUnblock_OtherCallPaysAdvertiser_SellerRefund() public {
        (uint256 id,) = _creditViaSellerRefund();
        _withdrawAndCheck(id, other);
    }

    function test_AfterUnblock_AdvertiserCallPaysSelf_Release() public {
        (uint256 id,) = _creditViaRelease();
        _withdrawAndCheck(id, advertiser);
    }

    function test_AfterUnblock_ReferrerCallCannotRedirectFunds() public {
        (uint256 id,) = _creditViaClaim();
        _withdrawAndCheck(id, referrer);
    }

    // ------------------------------------------------------------------ revert matrix
    function test_SecondCallReverts_NothingToWithdraw() public {
        (uint256 id,) = _creditViaClaim();
        _heal();
        _withdraw(stranger, id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingToWithdraw.selector, id));
        plug.withdrawClosedBudget(id);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingToWithdraw.selector, id));
        plug.withdrawClosedBudget(id);
    }

    function test_ClosedCampaignWithNothingCredited_Reverts() public {
        uint256 id = _createP();
        _endAs(advertiser, id); // refund consumed the whole budget
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingToWithdraw.selector, id));
        plug.withdrawClosedBudget(id);
    }

    function test_ActiveCampaign_RevertsCampaignStillActive() public {
        uint256 id = _createP(); // budget BUDGET > 0
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignStillActive.selector, id));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), BUDGET, "active budget untouched");
    }

    function test_ActiveCampaignWithZeroBudget_RevertsCampaignStillActive() public {
        uint256 id = _createP(PRICE, BPS, 0, WINDOW);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignStillActive.selector, id));
        plug.withdrawClosedBudget(id);
    }

    function test_ExpiredButNotEndedCampaign_RevertsCampaignStillActive() public {
        uint256 id = _createP();
        skip(DURATION + 1);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignStillActive.selector, id));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), BUDGET);
    }

    function test_BadId_RevertsCampaignNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, uint256(0)));
        plug.withdrawClosedBudget(0);
        uint256 id = _createP();
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, id + 1));
        plug.withdrawClosedBudget(id + 1);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignNotFound.selector, type(uint256).max));
        plug.withdrawClosedBudget(type(uint256).max);
    }

    function test_InstantCampaign_EndedWithRefund_NothingToWithdraw() public {
        vm.prank(advertiser);
        uint256 id = plug.createCampaign("T", "u", PRICE, BPS, BUDGET, _end(), 0, address(0));
        _endAs(advertiser, id);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingToWithdraw.selector, id));
        plug.withdrawClosedBudget(id);
    }

    // ------------------------------------------------------------------ never touches reserved / escrow
    function test_NeverTouchesReservedCommissionOrEscrowedPrice() public {
        uint256 id = _createP();
        uint256 o1 = _place(id, referrer);
        uint256 o2 = _place(id, referrer);
        _endAs(advertiser, id); // refunds BUDGET - 2*COMMISSION; two reserved commissions stay
        bl.setBlocklisted(advertiser, true);
        _dispute(o1);
        skip(DISPUTE_PERIOD);
        _claim(o1); // credit COMMISSION; o2 still open
        assertEq(_budget(id), COMMISSION);
        assertEq(plug.reservedCommission(), COMMISSION);
        assertEq(plug.escrowedPrice(), PRICE);

        _heal();
        uint256 reserved = plug.reservedCommission();
        uint256 escrow = plug.escrowedPrice();
        _withdraw(stranger, id);
        assertEq(plug.reservedCommission(), reserved, "reservedCommission untouched");
        assertEq(plug.escrowedPrice(), escrow, "escrowedPrice untouched");
        assertEq(token.balanceOf(address(plug)), PRICE + COMMISSION, "open order still fully backed");
        _assertSolvent();

        // The open order still settles normally afterwards.
        uint256 advBefore = token.balanceOf(advertiser);
        uint256 refBefore = token.balanceOf(referrer);
        _confirm(o2);
        assertEq(token.balanceOf(advertiser), advBefore + PRICE);
        assertEq(token.balanceOf(referrer), refBefore + COMMISSION);
        assertEq(token.balanceOf(address(plug)), 0);
        _assertSolvent();
    }

    function test_ClosedCampaignOnlyOpenOrders_NothingToWithdrawAndEscrowIntact() public {
        (uint256 id, uint256 oid) = _setupOrder();
        _endAs(advertiser, id);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingToWithdraw.selector, id));
        plug.withdrawClosedBudget(id);
        assertEq(plug.reservedCommission(), COMMISSION);
        assertEq(plug.escrowedPrice(), PRICE);
        assertTrue(_status(oid) == PENDING);
        _assertSolvent();
    }

    function test_WithdrawOnlyAffectsTheNamedCampaign() public {
        (uint256 idA,) = _creditViaClaim();
        // second campaign: its own credit, created while the advertiser is blocklisted? create before blocking.
        _heal();
        uint256 idB = _createP();
        uint256 oB = _place(idB, referrer);
        _endAs(advertiser, idB);
        bl.setBlocklisted(advertiser, true);
        _sellerRefund(oB);
        assertEq(_budget(idA), COMMISSION);
        assertEq(_budget(idB), COMMISSION);
        _heal();
        _withdraw(stranger, idA);
        assertEq(_budget(idA), 0);
        assertEq(_budget(idB), COMMISSION, "other campaign's credit untouched");
        assertEq(token.balanceOf(address(plug)), COMMISSION);
        _assertSolvent();
        _withdraw(stranger, idB);
        assertEq(token.balanceOf(address(plug)), 0);
    }

    function test_ClosedCampaign_StillRejectsTopUpAndBuy() public {
        (uint256 id,) = _creditViaClaim();
        bl.setBlocklisted(advertiser, false);
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.topUp(id, 1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.CampaignInactive.selector, id));
        plug.buy(id, referrer);
        assertEq(_budget(id), COMMISSION);
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_WithdrawPaysExactCredit(uint256 priceIn, uint16 bpsIn, uint256 callerSeed) public {
        uint256 price = bound(priceIn, 1, 1e24);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        uint256 commission = (price * bps) / 10000;
        flex.mint(advertiser, 2 * price);
        flex.mint(buyer, 2 * price);
        uint256 id = _createP(price, bps, price, WINDOW);
        uint256 oid = _place(id, referrer);
        _endAs(advertiser, id);
        bl.setBlocklisted(advertiser, true);
        _sellerRefund(oid);
        assertEq(_budget(id), commission);
        _assertSolvent();

        address caller = address(uint160(bound(callerSeed, 1, type(uint160).max)));
        if (caller == address(plug) || caller == address(0)) caller = stranger;
        if (commission == 0) {
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.NothingToWithdraw.selector, id));
            plug.withdrawClosedBudget(id);
            return;
        }
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(BlocklistUSDC.Blocklisted.selector, advertiser));
        plug.withdrawClosedBudget(id);
        assertEq(_budget(id), commission);

        bl.setBlocklisted(advertiser, false);
        uint256 advBefore = token.balanceOf(advertiser);
        uint256 callerBefore = token.balanceOf(caller);
        _withdraw(caller, id);
        assertEq(token.balanceOf(advertiser), advBefore + commission);
        if (caller != advertiser) assertEq(token.balanceOf(caller), callerBefore);
        assertEq(_budget(id), 0);
        assertEq(token.balanceOf(address(plug)), 0);
        _assertSolvent();
    }
}
