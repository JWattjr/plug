// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev Drives bounded random actions (instant + windowed campaigns, every order action, warps,
///      blocklist toggles) against PlugCampaigns. NEVER donates tokens to the contract.
///      Arbiters are dedicated, unfunded addresses that are never chosen as referrers/buyers.
contract PlugHandler is Test {
    PlugCampaigns public plug;
    BlocklistUSDC public usdc;

    address[4] public actors;
    address[2] public arbs;

    uint256 public constant INITIAL_BALANCE = 1e30;
    uint256 internal constant NO_ORDER = type(uint256).max;

    // ---- ghosts (violation counters must stay zero) ----
    uint256 public ghostBadAdvertiserDelta;
    uint256 public ghostBadBuyerDelta;
    uint256 public ghostBlockedRefPaid;
    uint256 public ghostEarningsMismatch;
    uint256 public ghostBadTransition;
    uint256 public ghostBadOrderAccounting;
    uint256 public ghostBadWithdraw; // withdrawClosedBudget misbehaved
    uint256 public ghostBadSelfReferrer; // address(plug) as referrer earned / moved budget
    uint256 public ghostBadArbiterWindow; // resolve/claimRefund succeeded outside its time window
    uint256 public ghostBadOwed; // owed-refund bookkeeping or claimOwedRefund misbehaved
    // ---- ghosts (counters) ----
    uint256 public ghostInstantSales;
    uint256 public ghostOrdersPlaced;
    uint256 public ghostReleasedOrders;
    uint256 public ghostRefundedOrders;
    uint256 public ghostDelivered; // commission delivered, measured from referrer token balances
    uint256 public ghostBlockToggles;
    uint256 public ghostDisputes;
    uint256 public ghostContests;
    uint256 public ghostWithdrawals;
    uint256 public ghostCredits; // closed campaigns left holding an undeliverable credit
    uint256 public ghostSelfRefBuys;
    uint256 public ghostBarredResolves; // resolve attempts at/after the deadline that correctly reverted
    uint256 public ghostLateClaims; // buyer claims made at/after a contest deadline
    uint256 public ghostOwedCreated; // refunds finalized as owed (buyer undeliverable)
    uint256 public ghostOwedClaimed; // successful claimOwedRefund calls
    uint256 public ghostOwedClaimBlocked; // claimOwedRefund correctly reverted (buyer/contract blocklisted)
    uint256 public ghostBlockedBuyerScenarios; // blocklist-buyer-then-settle scenarios that settled an order
    mapping(address => bool) public everBlocked;

    struct Pre {
        uint256 buyerBal;
        uint256 advBal;
        uint256 refBal;
        uint256 plugBal;
        uint256 owedTotal;
        PlugCampaigns.Campaign c;
        PlugCampaigns.Order o;
    }

    constructor(PlugCampaigns plug_, BlocklistUSDC usdc_) {
        plug = plug_;
        usdc = usdc_;
        for (uint256 i; i < 4; i++) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            usdc.mint(actors[i], INITIAL_BALANCE);
            vm.prank(actors[i]);
            usdc.approve(address(plug), type(uint256).max);
        }
        arbs[0] = makeAddr("arbiter0");
        arbs[1] = makeAddr("arbiter1");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 4];
    }

    function _id(uint256 seed) internal view returns (bool ok, uint256 id) {
        uint256 n = plug.campaignCount();
        if (n == 0) return (false, 0);
        uint256 window = n < 4 ? n : 4;
        return (true, n - 1 - (seed % window));
    }

    function _oid(uint256 seed) internal view returns (bool ok, uint256 oid) {
        uint256 n = plug.orderCount();
        if (n == 0) return (false, 0);
        uint256 window = n < 6 ? n : 6;
        return (true, n - 1 - (seed % window));
    }

    // ---------------- campaign-level actions ----------------
    function create(uint256 aSeed, uint256 price, uint16 bps, uint256 budget, uint256 dur, uint256 wSeed) external {
        _create(
            _actor(aSeed),
            arbs[(aSeed >> 8) % 2],
            bound(price, 1, 1e12),
            uint16(bound(bps, 0, 5000)),
            bound(budget, 0, 1e12),
            uint64(block.timestamp + bound(dur, 5 days, 40 days)),
            _window(wSeed)
        );
    }

    function _window(uint256 wSeed) internal pure returns (uint64 window) {
        if (wSeed % 3 == 0) return 0;
        return uint64(wSeed % 2 == 0 ? bound(wSeed, 1, 3 days) : bound(wSeed, 1, 30 days));
    }

    function _create(address adv, address arb, uint256 price, uint16 bps, uint256 budget, uint64 end_, uint64 window)
        internal
    {
        vm.prank(adv);
        // funding can legitimately fail (blocklisted advertiser)
        try plug.createCampaign("t", "u", price, bps, budget, end_, window, arb) {} catch {}
    }

    struct BuyCtx {
        uint256 id;
        address who;
        address ref;
        uint256 advBefore;
        uint256 buyerBefore;
        uint256 refBefore;
        uint256 earnedBefore;
        bool refBlocked;
        PlugCampaigns.Campaign c;
    }

    function buy(uint256 aSeed, uint256 idSeed, uint256 refSeed) external {
        BuyCtx memory x;
        bool ok;
        (ok, x.id) = _id(idSeed);
        if (!ok) return;
        x.c = plug.getCampaign(x.id);
        uint256 r = refSeed % 9;
        x.ref = r == 0 ? address(0) : r == 5 ? x.c.advertiser : r == 6 ? x.c.arbiter : r >= 7 ? address(plug) : actors[r - 1];
        x.who = _actor(aSeed);
        x.advBefore = usdc.balanceOf(x.c.advertiser);
        x.buyerBefore = usdc.balanceOf(x.who);
        x.refBefore = usdc.balanceOf(x.ref);
        x.earnedBefore = plug.referrerEarnings(x.ref);
        x.refBlocked = x.ref != address(0) && usdc.isBlocklisted(x.ref);
        vm.prank(x.who);
        try plug.buy(x.id, x.ref) returns (uint256 oid) {
            if (x.c.protectionWindow != 0) _afterWindowedBuy(x, oid);
            else _afterInstantBuy(x, oid);
        } catch {}
    }

    function _afterWindowedBuy(BuyCtx memory x, uint256 oid) internal {
        PlugCampaigns.Campaign memory c2 = plug.getCampaign(x.id);
        if (oid != plug.orderCount() - 1 || oid != ghostOrdersPlaced) ghostBadOrderAccounting++;
        ghostOrdersPlaced++;
        // nobody but the buyer moves tokens at placement
        if (usdc.balanceOf(x.who) != x.buyerBefore - x.c.price) ghostBadBuyerDelta++;
        if (x.who != x.c.advertiser && usdc.balanceOf(x.c.advertiser) != x.advBefore) ghostBadAdvertiserDelta++;
        if (x.ref == address(plug)) {
            ghostSelfRefBuys++;
            if (plug.getOrder(oid).commission != 0 || c2.budgetRemaining != x.c.budgetRemaining) {
                ghostBadSelfReferrer++;
            }
        } else if (x.ref != x.who && x.ref != x.c.advertiser && usdc.balanceOf(x.ref) != x.refBefore) {
            ghostBadAdvertiserDelta++;
        }
        if (c2.commissionPaid != x.c.commissionPaid || plug.referrerEarnings(x.ref) != x.earnedBefore) {
            ghostEarningsMismatch++;
        }
        if (c2.sales != x.c.sales) ghostBadOrderAccounting++;
    }

    function _afterInstantBuy(BuyCtx memory x, uint256 oid) internal {
        PlugCampaigns.Campaign memory c2 = plug.getCampaign(x.id);
        if (oid != NO_ORDER) ghostBadOrderAccounting++;
        if (x.refBlocked && c2.commissionPaid != x.c.commissionPaid) ghostBlockedRefPaid++;
        uint256 delivered = c2.commissionPaid - x.c.commissionPaid;
        if (plug.referrerEarnings(x.ref) - x.earnedBefore != delivered) ghostEarningsMismatch++;
        if (x.ref == address(plug)) {
            ghostSelfRefBuys++;
            if (c2.budgetRemaining != x.c.budgetRemaining || delivered != 0) ghostBadSelfReferrer++;
        }
        if (x.ref != address(0) && x.ref != address(plug) && x.ref != x.who && x.ref != x.c.advertiser) {
            uint256 measured = usdc.balanceOf(x.ref) - x.refBefore;
            if (measured != delivered) ghostEarningsMismatch++;
            ghostDelivered += measured;
        } else if (delivered != 0) {
            ghostEarningsMismatch++;
        }
        bool self = x.who == x.c.advertiser;
        if (usdc.balanceOf(x.c.advertiser) != (self ? x.advBefore : x.advBefore + x.c.price)) {
            ghostBadAdvertiserDelta++;
        }
        if (usdc.balanceOf(x.who) != (self ? x.buyerBefore : x.buyerBefore - x.c.price)) ghostBadBuyerDelta++;
        ghostInstantSales++;
    }

    function topUp(uint256 idSeed, uint256 amount) external {
        (bool ok, uint256 id) = _id(idSeed);
        if (!ok) return;
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        vm.prank(c.advertiser);
        try plug.topUp(id, bound(amount, 0, 1e12)) {} catch {}
    }

    function end(uint256 aSeed, uint256 idSeed) external {
        if (idSeed % 4 != 0) return; // closing is rare so most campaigns stay live for buys / orders
        (bool ok, uint256 id) = _id(idSeed / 4);
        if (!ok) return;
        vm.prank(_actor(aSeed));
        try plug.endCampaign(id) {} catch {}
    }

    // ---------------- order actions (correct callers) ----------------
    function _pre(uint256 oid) internal view returns (Pre memory p) {
        p.o = plug.getOrder(oid);
        p.c = plug.getCampaign(p.o.campaignId);
        p.buyerBal = usdc.balanceOf(p.o.buyer);
        p.advBal = usdc.balanceOf(p.c.advertiser);
        p.refBal = usdc.balanceOf(p.o.referrer);
        p.plugBal = usdc.balanceOf(address(plug));
        p.owedTotal = plug.owedRefunds();
    }

    /// mode 1: must be Disputed, 2: must be Contested, 3: must be Refunded, 0: Released or Refunded.
    function _post(uint256 oid, Pre memory p, uint8 mode) internal {
        PlugCampaigns.Order memory o2 = plug.getOrder(oid);
        PlugCampaigns.Campaign memory c2 = plug.getCampaign(p.o.campaignId);
        if (mode == 1 || mode == 2) {
            PlugCampaigns.Status want = mode == 1 ? PlugCampaigns.Status.Disputed : PlugCampaigns.Status.Contested;
            if (o2.status != want || usdc.balanceOf(address(plug)) != p.plugBal) ghostBadTransition++;
            if (c2.pendingOrders != p.c.pendingOrders || c2.budgetRemaining != p.c.budgetRemaining) {
                ghostBadOrderAccounting++;
            }
            return;
        }
        if (c2.pendingOrders + 1 != p.c.pendingOrders) ghostBadOrderAccounting++;
        if (o2.status == PlugCampaigns.Status.Released) {
            if (mode == 3) ghostBadTransition++;
            ghostReleasedOrders++;
            _postReleased(p, c2);
        } else if (o2.status == PlugCampaigns.Status.Refunded) {
            ghostRefundedOrders++;
            _postRefunded(oid, p, c2);
        } else {
            ghostBadTransition++;
        }
    }

    function _postReleased(Pre memory p, PlugCampaigns.Campaign memory c2) internal {
        uint256 delivered = c2.commissionPaid - p.c.commissionPaid;
        if (p.o.commission != 0) {
            uint256 measured = usdc.balanceOf(p.o.referrer) - p.refBal;
            if (measured != delivered) ghostEarningsMismatch++;
            if (usdc.isBlocklisted(p.o.referrer) && delivered != 0) ghostBlockedRefPaid++;
            ghostDelivered += measured;
        } else if (delivered != 0) {
            ghostEarningsMismatch++;
        }
        if (delivered > p.o.commission) ghostBadOrderAccounting++;
        if (c2.sales != p.c.sales + 1 || c2.refundedCount != p.c.refundedCount) ghostBadOrderAccounting++;
        if (usdc.balanceOf(p.c.advertiser) < p.advBal + p.o.price) ghostBadAdvertiserDelta++;
    }

    /// A refund always finalizes. Either the buyer was paid the full price, or (buyer/contract
    /// blocklisted) the price is recorded as owed with the buyer's balance untouched.
    function _postRefunded(uint256 oid, Pre memory p, PlugCampaigns.Campaign memory c2) internal {
        if (c2.refundedCount != p.c.refundedCount + 1) ghostBadOrderAccounting++;
        if (c2.sales != p.c.sales || c2.commissionPaid != p.c.commissionPaid) ghostBadOrderAccounting++;
        uint256 buyerBal = usdc.balanceOf(p.o.buyer);
        uint256 owed = plug.refundOwedOf(oid);
        bool undeliverable = usdc.isBlocklisted(p.o.buyer) || usdc.isBlocklisted(address(plug));
        if (owed != 0) {
            ghostOwedCreated++;
            if (owed != p.o.price || plug.owedRefunds() != p.owedTotal + p.o.price) ghostBadOwed++;
            if (!undeliverable) ghostBadOwed++; // a deliverable refund must be paid, never owed
            if (p.o.buyer != p.c.advertiser) {
                if (buyerBal != p.buyerBal) ghostBadBuyerDelta++; // owed instead of paid
            } else if (buyerBal < p.buyerBal) {
                ghostBadBuyerDelta++;
            }
        } else {
            if (plug.owedRefunds() != p.owedTotal) ghostBadOwed++;
            if (undeliverable) ghostBadOwed++; // an undeliverable refund must be recorded as owed
            if (p.o.buyer != p.c.advertiser) {
                if (buyerBal != p.buyerBal + p.o.price) ghostBadBuyerDelta++;
            } else if (buyerBal < p.buyerBal + p.o.price) {
                ghostBadBuyerDelta++;
            }
        }
        if (p.o.commission != 0 && usdc.balanceOf(p.o.referrer) != p.refBal) ghostEarningsMismatch++;
    }

    function confirm(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(p.o.buyer);
        try plug.confirm(oid) {
            _post(oid, p, 0);
        } catch {}
    }

    function release(uint256 aSeed, uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(_actor(aSeed));
        try plug.release(oid) {
            _post(oid, p, 0);
        } catch {}
    }

    function dispute(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(p.o.buyer);
        try plug.dispute(oid, "reason") {
            ghostDisputes++;
            _post(oid, p, 1);
        } catch {}
    }

    function sellerRefund(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(p.c.advertiser);
        try plug.refund(oid) {
            _post(oid, p, 3);
        } catch {}
    }

    function contest(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(p.c.advertiser);
        try plug.contest(oid) {
            ghostContests++;
            _post(oid, p, 2);
        } catch {}
    }

    function claimRefund(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(p.o.buyer);
        try plug.claimRefund(oid) {
            if (block.timestamp < p.o.disputeDeadline) ghostBadArbiterWindow++;
            if (p.o.status == PlugCampaigns.Status.Contested) ghostLateClaims++;
            _post(oid, p, 3);
        } catch {}
    }

    function resolve(uint256 seed, bool refundBuyer) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        Pre memory p = _pre(oid);
        vm.prank(p.c.arbiter);
        try plug.resolve(oid, refundBuyer) {
            // arbiter may only act on a Contested order strictly before its deadline
            if (block.timestamp >= p.o.disputeDeadline || p.o.status != PlugCampaigns.Status.Contested) {
                ghostBadArbiterWindow++;
            }
            _post(oid, p, refundBuyer ? 3 : 0);
        } catch {
            if (p.o.status == PlugCampaigns.Status.Contested && block.timestamp >= p.o.disputeDeadline) {
                ghostBarredResolves++;
            }
        }
    }

    // ---------------- composite scenarios (reach deep states quickly) ----------------
    /// dispute (buyer) then contest (seller) on a recent order in one step.
    function contestFlow(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        PlugCampaigns.Campaign memory c = plug.getCampaign(o.campaignId);
        vm.prank(o.buyer);
        try plug.dispute(oid, "r") {
            ghostDisputes++;
        } catch {}
        vm.prank(c.advertiser);
        try plug.contest(oid) {
            ghostContests++;
        } catch {}
    }

    /// Close a campaign with an open order, blocklist its advertiser, then seller-refund the order:
    /// the returned commission cannot be delivered and stays credited to the inactive campaign.
    function creditScenario(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        if (o.status == PlugCampaigns.Status.Released || o.status == PlugCampaigns.Status.Refunded) return;
        PlugCampaigns.Campaign memory c = plug.getCampaign(o.campaignId);
        vm.prank(c.advertiser);
        try plug.endCampaign(o.campaignId) {} catch {}
        usdc.setBlocklisted(c.advertiser, true);
        everBlocked[c.advertiser] = true;
        Pre memory p = _pre(oid);
        vm.prank(c.advertiser);
        try plug.refund(oid) {
            _post(oid, p, 3);
        } catch {}
        PlugCampaigns.Campaign memory c2 = plug.getCampaign(o.campaignId);
        if (!c2.active && c2.budgetRemaining != 0) ghostCredits++;
    }

    // ---------------- closed-budget withdrawal ----------------
    function withdrawClosed(uint256 aSeed, uint256 idSeed) external {
        uint256 n = plug.campaignCount();
        if (n == 0) return;
        // wider id window than _id(): credits can sit on old closed campaigns
        uint256 id = idSeed % n;
        for (uint256 k; k < n; k++) {
            // prefer a campaign that actually holds a closed-budget credit
            uint256 cand = (idSeed % n + k) % n;
            PlugCampaigns.Campaign memory cc = plug.getCampaign(cand);
            if (!cc.active && cc.budgetRemaining != 0) {
                id = cand;
                break;
            }
        }
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        address caller = aSeed % 5 == 4 ? c.advertiser : _actor(aSeed);
        uint256 advBal = usdc.balanceOf(c.advertiser);
        uint256 plugBal = usdc.balanceOf(address(plug));
        uint256 reserved = plug.reservedCommission();
        uint256 escrow = plug.escrowedPrice();
        bool canPay = !usdc.isBlocklisted(c.advertiser) && !usdc.isBlocklisted(address(plug));
        vm.prank(caller);
        try plug.withdrawClosedBudget(id) {
            ghostWithdrawals++;
            PlugCampaigns.Campaign memory c2 = plug.getCampaign(id);
            if (c.active || c.budgetRemaining == 0 || !canPay) ghostBadWithdraw++;
            if (c2.budgetRemaining != 0 || c2.active) ghostBadWithdraw++;
            if (usdc.balanceOf(address(plug)) != plugBal - c.budgetRemaining) ghostBadWithdraw++;
            // only the advertiser is ever paid; if caller is the advertiser it is the same balance
            if (usdc.balanceOf(c.advertiser) != advBal + c.budgetRemaining) ghostBadWithdraw++;
            if (plug.reservedCommission() != reserved || plug.escrowedPrice() != escrow) ghostBadWithdraw++;
            if (c2.sales != c.sales || c2.commissionPaid != c.commissionPaid || c2.pendingOrders != c.pendingOrders) {
                ghostBadWithdraw++;
            }
        } catch {
            // an inactive credited campaign with a payable advertiser must never fail
            if (!c.active && c.budgetRemaining != 0 && canPay) ghostBadWithdraw++;
            if (usdc.balanceOf(address(plug)) != plugBal || plug.getCampaign(id).budgetRemaining != c.budgetRemaining) {
                ghostBadWithdraw++;
            }
        }
    }

    // ---------------- owed refunds ----------------
    /// Anyone may call claimOwedRefund; funds go only to the order's buyer. Prefers an order that
    /// actually has a credit, otherwise probes a recent order that must revert NothingOwed.
    function claimOwedRefund(uint256 aSeed, uint256 seed) external {
        uint256 n = plug.orderCount();
        if (n == 0) return;
        uint256 oid = seed % n;
        for (uint256 k; k < n; k++) {
            uint256 cand = (seed % n + k) % n;
            if (plug.refundOwedOf(cand) != 0) {
                oid = cand;
                break;
            }
        }
        _claimOwed(oid, _actor(aSeed));
    }

    function _claimOwed(uint256 oid, address caller) internal {
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        uint256 owed = plug.refundOwedOf(oid);
        uint256 buyerBal = usdc.balanceOf(o.buyer);
        uint256 callerBal = usdc.balanceOf(caller);
        uint256 plugBal = usdc.balanceOf(address(plug));
        uint256 total = plug.owedRefunds();
        bool canPay = !usdc.isBlocklisted(o.buyer) && !usdc.isBlocklisted(address(plug));
        vm.prank(caller);
        try plug.claimOwedRefund(oid) {
            ghostOwedClaimed++;
            if (owed == 0 || !canPay) ghostBadOwed++;
            if (plug.refundOwedOf(oid) != 0 || plug.owedRefunds() != total - owed) ghostBadOwed++;
            if (usdc.balanceOf(o.buyer) != buyerBal + owed) ghostBadOwed++;
            if (usdc.balanceOf(address(plug)) != plugBal - owed) ghostBadOwed++;
            if (caller != o.buyer && usdc.balanceOf(caller) != callerBal) ghostBadOwed++;
            if (plug.getOrder(oid).status != PlugCampaigns.Status.Refunded) ghostBadOwed++;
        } catch {
            // a payable buyer with a credit must always be claimable
            if (owed != 0 && canPay) ghostBadOwed++;
            if (owed != 0) ghostOwedClaimBlocked++;
            // a failed claim preserves the credit and moves nothing
            if (plug.refundOwedOf(oid) != owed || plug.owedRefunds() != total) ghostBadOwed++;
            if (usdc.balanceOf(o.buyer) != buyerBal || usdc.balanceOf(address(plug)) != plugBal) ghostBadOwed++;
        }
    }

    /// Blocklist the buyer of a recent unsettled order, settle it through one of the refund paths
    /// (0 seller refund, 1 buyer claimRefund, 2 arbiter resolve(true), 3 release fallback with the
    /// seller also blocklisted), then optionally unblock everyone and claim the owed refund.
    function blockedBuyerScenario(uint256 seed, uint8 path, bool heal) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        if (o.status == PlugCampaigns.Status.Released || o.status == PlugCampaigns.Status.Refunded) return;
        PlugCampaigns.Campaign memory c = plug.getCampaign(o.campaignId);
        path = path % 4;
        usdc.setBlocklisted(o.buyer, true);
        everBlocked[o.buyer] = true;
        if (path == 3) {
            usdc.setBlocklisted(c.advertiser, true);
            everBlocked[c.advertiser] = true;
        }
        if (_settleBlocked(oid, path, c)) ghostBlockedBuyerScenarios++;
        if (heal) {
            usdc.setBlocklisted(o.buyer, false);
            usdc.setBlocklisted(c.advertiser, false);
            _claimOwed(oid, _actor(seed >> 16));
        }
    }

    function _settleBlocked(uint256 oid, uint8 path, PlugCampaigns.Campaign memory c) internal returns (bool) {
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        if (path == 0) return _tryRefund(oid, c.advertiser, 0);
        if (path == 1) {
            if (o.status == PlugCampaigns.Status.Pending) {
                vm.prank(o.buyer);
                try plug.dispute(oid, "r") {
                    ghostDisputes++;
                } catch {
                    return false;
                }
                o = plug.getOrder(oid);
            }
            if (block.timestamp < o.disputeDeadline) vm.warp(o.disputeDeadline);
            return _tryRefund(oid, o.buyer, 1);
        }
        if (path == 2) {
            if (o.status == PlugCampaigns.Status.Pending) {
                vm.prank(o.buyer);
                try plug.dispute(oid, "r") {
                    ghostDisputes++;
                } catch {
                    return false;
                }
            }
            if (plug.getOrder(oid).status == PlugCampaigns.Status.Disputed) {
                vm.prank(c.advertiser);
                try plug.contest(oid) {
                    ghostContests++;
                } catch {
                    return false;
                }
            }
            return _tryRefund(oid, c.arbiter, 2);
        }
        // path 3: seller unreachable, so a release attempt falls back to a refund
        if (o.status == PlugCampaigns.Status.Pending && block.timestamp < o.releaseAt) vm.warp(o.releaseAt);
        Pre memory p = _pre(oid);
        bool done;
        if (o.status == PlugCampaigns.Status.Contested) {
            vm.prank(c.arbiter);
            try plug.resolve(oid, false) {
                done = true;
            } catch {}
        } else if (o.status == PlugCampaigns.Status.Disputed) {
            vm.prank(o.buyer);
            try plug.confirm(oid) {
                done = true;
            } catch {}
        } else {
            vm.prank(actors[0]);
            try plug.release(oid) {
                done = true;
            } catch {}
        }
        if (done) _post(oid, p, 0);
        return done;
    }

    /// kind 0: seller refund, 1: buyer claimRefund, 2: arbiter resolve(true).
    function _tryRefund(uint256 oid, address caller, uint8 kind) internal returns (bool done) {
        Pre memory p = _pre(oid);
        vm.prank(caller);
        if (kind == 0) {
            try plug.refund(oid) {
                done = true;
            } catch {}
        } else if (kind == 1) {
            try plug.claimRefund(oid) {
                done = true;
            } catch {}
        } else {
            try plug.resolve(oid, true) {
                done = true;
            } catch {}
        }
        if (done) _post(oid, p, 3);
    }

    // ---------------- environment ----------------
    /// Toggle the issuer blocklist for one of the actors or for the PlugCampaigns contract itself.
    function blocklist(uint256 seed, bool on) external {
        uint256 i = seed % 5;
        address who = i == 4 ? address(plug) : actors[i];
        // bias towards unblocking so the happy paths stay well covered
        on = on && (seed / 5) % (i == 4 ? 8 : 4) == 0;
        usdc.setBlocklisted(who, on);
        if (on) everBlocked[who] = true;
        ghostBlockToggles++;
    }

    /// Warp to deadline-1 / deadline / deadline+1 of a recent Contested order, so arbiter and
    /// claimRefund actions land exactly on the window boundary.
    function warpToArbiterDeadline(uint256 seed) external {
        (bool ok, uint256 oid) = _oid(seed);
        if (!ok) return;
        PlugCampaigns.Order memory o = plug.getOrder(oid);
        if (o.status != PlugCampaigns.Status.Contested) return;
        uint256 target = uint256(o.disputeDeadline) - 1 + ((seed / 7) % 3);
        if (target > block.timestamp) vm.warp(target);
    }

    function warp(uint256 secs) external {
        skip(secs % 5 == 0 ? bound(secs, 0, 12 days) : bound(secs, 0, 2 days));
    }
}
