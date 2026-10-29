// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";
import {PlugHandler} from "./PlugCampaigns.Handler.t.sol";

contract PlugCampaignsInvariantTest is Test {
    PlugCampaigns internal plug;
    BlocklistUSDC internal usdc;
    PlugHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        usdc = new BlocklistUSDC();
        plug = new PlugCampaigns(address(usdc));
        handler = new PlugHandler(plug, usdc);
        targetContract(address(handler));
        bytes4[] memory sels = new bytes4[](24);
        sels[0] = PlugHandler.create.selector;
        sels[1] = PlugHandler.buy.selector;
        sels[2] = PlugHandler.topUp.selector;
        sels[3] = PlugHandler.end.selector;
        sels[4] = PlugHandler.confirm.selector;
        sels[5] = PlugHandler.release.selector;
        sels[6] = PlugHandler.dispute.selector;
        sels[7] = PlugHandler.sellerRefund.selector;
        sels[8] = PlugHandler.contest.selector;
        sels[9] = PlugHandler.claimRefund.selector;
        sels[10] = PlugHandler.resolve.selector;
        sels[11] = PlugHandler.blocklist.selector;
        sels[12] = PlugHandler.warp.selector;
        sels[13] = PlugHandler.buy.selector; // buy twice as likely
        sels[14] = PlugHandler.withdrawClosed.selector;
        sels[15] = PlugHandler.warpToArbiterDeadline.selector;
        sels[16] = PlugHandler.resolve.selector; // resolve more often so it lands on the window edge
        sels[17] = PlugHandler.contestFlow.selector;
        sels[18] = PlugHandler.creditScenario.selector;
        sels[19] = PlugHandler.claimOwedRefund.selector;
        sels[20] = PlugHandler.blockedBuyerScenario.selector;
        sels[21] = PlugHandler.blockedBuyerScenario.selector; // scenario twice as likely
        sels[22] = PlugHandler.claimOwedRefund.selector;
        sels[23] = PlugHandler.dispute.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sels}));
    }

    /// CORE: token balance == sum(budgetRemaining) + reservedCommission + escrowedPrice + owedRefunds, always.
    function invariant_BalanceEqualsBudgetsPlusReservedPlusEscrow() public view {
        uint256 sum;
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) sum += plug.getCampaign(i).budgetRemaining;
        assertEq(
            usdc.balanceOf(address(plug)),
            sum + plug.reservedCommission() + plug.escrowedPrice() + plug.owedRefunds()
        );
    }

    /// escrowedPrice / reservedCommission equal the sums over unsettled orders; status counters and
    /// per-campaign pendingOrders / refundedCount / sales match the order book exactly.
    function invariant_OrderBookMatchesCountersAndEscrow() public view {
        uint256 nc = plug.campaignCount();
        uint256 no = plug.orderCount();
        assertEq(no, handler.ghostOrdersPlaced(), "order count");
        uint256[] memory pend = new uint256[](nc);
        uint256[] memory refd = new uint256[](nc);
        uint256[] memory rel = new uint256[](nc);
        uint256 escrow;
        uint256 reserved;
        uint256 releasedTotal;
        uint256 refundedTotal;
        for (uint256 i; i < no; i++) {
            PlugCampaigns.Order memory o = plug.getOrder(i);
            if (o.status == PlugCampaigns.Status.Released) {
                rel[o.campaignId]++;
                releasedTotal++;
            } else if (o.status == PlugCampaigns.Status.Refunded) {
                refd[o.campaignId]++;
                refundedTotal++;
            } else {
                pend[o.campaignId]++;
                escrow += o.price;
                reserved += o.commission;
            }
        }
        assertEq(plug.escrowedPrice(), escrow, "escrowedPrice == sum of unsettled prices");
        assertEq(plug.reservedCommission(), reserved, "reservedCommission == sum of unsettled commissions");
        assertEq(releasedTotal, handler.ghostReleasedOrders(), "released outcomes");
        assertEq(refundedTotal, handler.ghostRefundedOrders(), "refunded outcomes");
        uint256 salesTotal;
        for (uint256 i; i < nc; i++) {
            PlugCampaigns.Campaign memory c = plug.getCampaign(i);
            (uint256 p, uint256 r) = plug.campaignStats(i);
            assertEq(p, pend[i], "pendingOrders == unsettled count");
            assertEq(c.pendingOrders, pend[i]);
            assertEq(r, refd[i], "refundedCount == refunded count");
            assertEq(plug.ordersOfCampaign(i).length, pend[i] + refd[i] + rel[i]);
            if (c.protectionWindow == 0) assertEq(c.arbiter, address(0));
            else assertEq(c.sales, rel[i], "windowed sales == released orders");
            salesTotal += c.sales;
        }
        assertEq(salesTotal, handler.ghostInstantSales() + releasedTotal, "sales == instant + released");
    }

    /// owedRefunds == sum of refundOwedOf over every order; a credit exists only on a Refunded order
    /// and never exceeds that order's price.
    function invariant_OwedRefundsEqualSumOfPerOrderCredits() public view {
        uint256 sum;
        uint256 no = plug.orderCount();
        for (uint256 i; i < no; i++) {
            uint256 owed = plug.refundOwedOf(i);
            if (owed != 0) {
                PlugCampaigns.Order memory o = plug.getOrder(i);
                assertTrue(o.status == PlugCampaigns.Status.Refunded, "refundOwedOf non-zero only if Refunded");
                assertEq(owed, o.price, "credit is exactly the order price");
            }
            sum += owed;
        }
        assertEq(plug.owedRefunds(), sum, "owedRefunds == sum(refundOwedOf)");
    }

    /// Sum of referrerEarnings == sum of commissionPaid == commissions actually delivered (measured
    /// from referrer token balances); commission never exceeds 50% of settled revenue.
    function invariant_EarningsEqualCommissionDelivered() public view {
        uint256 paid;
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) {
            PlugCampaigns.Campaign memory c = plug.getCampaign(i);
            paid += c.commissionPaid;
            assertLe(c.commissionPaid * 2, c.sales * c.price);
        }
        uint256 earned;
        for (uint256 i; i < 4; i++) earned += plug.referrerEarnings(handler.actors(i));
        assertEq(earned, paid, "earnings == commissionPaid");
        assertEq(paid, handler.ghostDelivered(), "commissionPaid == delivered");
    }

    /// Arbiters are never paid anything: their balance never increases (it is always zero).
    function invariant_ArbitersNeverReceiveFunds() public view {
        for (uint256 i; i < 2; i++) {
            assertEq(usdc.balanceOf(handler.arbs(i)), 0);
            assertEq(plug.referrerEarnings(handler.arbs(i)), 0);
        }
    }

    /// A closed campaign only holds budget when the advertiser (or contract) was blocklisted at some point.
    function invariant_InactiveCampaignsHoldNoBudgetUnlessUndeliverable() public view {
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) {
            PlugCampaigns.Campaign memory c = plug.getCampaign(i);
            if (!c.active && c.budgetRemaining != 0) {
                assertTrue(handler.everBlocked(c.advertiser) || handler.everBlocked(address(plug)));
            }
        }
    }

    /// Token conservation across the closed system of actors + arbiters + contract.
    function invariant_TotalSupplyConserved() public view {
        uint256 total = usdc.balanceOf(address(plug));
        for (uint256 i; i < 4; i++) total += usdc.balanceOf(handler.actors(i));
        for (uint256 i; i < 2; i++) total += usdc.balanceOf(handler.arbs(i));
        assertEq(total, 4 * handler.INITIAL_BALANCE());
    }

    /// Per-action payout checks inside the handler never flagged a violation.
    function invariant_NoPayoutOrTransitionViolations() public view {
        assertEq(handler.ghostBadAdvertiserDelta(), 0, "advertiser/seller payout");
        assertEq(handler.ghostBadBuyerDelta(), 0, "buyer payout");
        assertEq(handler.ghostBlockedRefPaid(), 0, "blocklisted referrer credited");
        assertEq(handler.ghostEarningsMismatch(), 0, "earnings vs delivered");
        assertEq(handler.ghostBadTransition(), 0, "illegal status transition");
        assertEq(handler.ghostBadOrderAccounting(), 0, "per-action counters");
        assertEq(handler.ghostBadWithdraw(), 0, "withdrawClosedBudget");
        assertEq(handler.ghostBadSelfReferrer(), 0, "contract-as-referrer");
        assertEq(handler.ghostBadArbiterWindow(), 0, "arbiter window");
        assertEq(handler.ghostBadOwed(), 0, "owed refund bookkeeping / claimOwedRefund");
    }

    /// The contract itself can never be paid or credited as a referrer, however it is supplied.
    function invariant_ContractNeverEarnsAsReferrer() public view {
        assertEq(plug.referrerEarnings(address(plug)), 0);
    }

    /// A closed campaign's credit is bounded by what it could ever have received back, and an
    /// active campaign is never withdrawn from: inactive budget only exists if undeliverable.
    function invariant_ClosedBudgetIsAlwaysWithdrawableByAnyoneWhenPayable() public {
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) {
            PlugCampaigns.Campaign memory c = plug.getCampaign(i);
            if (c.active || c.budgetRemaining == 0) continue;
            if (usdc.isBlocklisted(c.advertiser) || usdc.isBlocklisted(address(plug))) continue;
            uint256 snap = vm.snapshotState();
            uint256 before = usdc.balanceOf(c.advertiser);
            vm.prank(address(0xBEEF));
            plug.withdrawClosedBudget(i);
            assertEq(usdc.balanceOf(c.advertiser), before + c.budgetRemaining, "advertiser paid exactly the credit");
            vm.revertToState(snap);
        }
    }

    /// Coverage summary (visible with -vv): confirms windowed paths and every order action are exercised.
    function afterInvariant() public view {
        console.log("campaigns", plug.campaignCount());
        console.log("orders placed", handler.ghostOrdersPlaced());
        console.log("released", handler.ghostReleasedOrders());
        console.log("refunded", handler.ghostRefundedOrders());
        console.log("disputes", handler.ghostDisputes());
        console.log("contests", handler.ghostContests());
        console.log("instant sales", handler.ghostInstantSales());
        console.log("delivered", handler.ghostDelivered());
        console.log("withdrawals", handler.ghostWithdrawals());
        console.log("credits created", handler.ghostCredits());
        console.log("self-referrer buys", handler.ghostSelfRefBuys());
        console.log("barred resolves", handler.ghostBarredResolves());
        console.log("claims of contested orders", handler.ghostLateClaims());
        console.log("owed refunds created", handler.ghostOwedCreated());
        console.log("owed refunds claimed", handler.ghostOwedClaimed());
        console.log("owed claims blocked", handler.ghostOwedClaimBlocked());
        console.log("blocked-buyer scenarios", handler.ghostBlockedBuyerScenarios());
    }
}
