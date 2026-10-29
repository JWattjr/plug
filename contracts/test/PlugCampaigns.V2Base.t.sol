// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsBase} from "./PlugCampaigns.Base.t.sol";
import {BlocklistUSDC} from "./mocks/BlocklistMocks.sol";

/// @dev v2 fixtures: windowed campaigns, order actions with correct callers, solvency check.
///      Uses BlocklistUSDC by default so any test can blocklist an account. Contains no tests.
abstract contract PlugCampaignsV2Base is PlugCampaignsBase {
    BlocklistUSDC internal bl;
    IERC20 internal token;

    address internal arbiter = makeAddr("arbiter");
    uint64 internal constant WINDOW = 7 days;
    uint64 internal constant DISPUTE_PERIOD = 3 days;
    uint64 internal constant ARBITER_TIMEOUT = 14 days;
    uint256 internal constant NO_ORDER = type(uint256).max;

    PlugCampaigns.Status internal constant PENDING = PlugCampaigns.Status.Pending;
    PlugCampaigns.Status internal constant DISPUTED = PlugCampaigns.Status.Disputed;
    PlugCampaigns.Status internal constant CONTESTED = PlugCampaigns.Status.Contested;
    PlugCampaigns.Status internal constant RELEASED = PlugCampaigns.Status.Released;
    PlugCampaigns.Status internal constant REFUNDED = PlugCampaigns.Status.Refunded;

    function setUp() public virtual override {
        vm.warp(1_000_000);
        bl = new BlocklistUSDC();
        usdc = bl;
        token = IERC20(address(bl));
        plug = new PlugCampaigns(address(bl));
        address[3] memory who = [advertiser, buyer, other];
        for (uint256 i; i < 3; i++) {
            bl.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            bl.approve(address(plug), type(uint256).max);
        }
    }

    // ---------- creation / placement ----------
    function _createP(uint256 price, uint16 bps, uint256 budget, uint64 window) internal returns (uint256 id) {
        vm.prank(advertiser);
        id = plug.createCampaign("Title", "https://x.y", price, bps, budget, _end(), window, arbiter);
    }

    /// Default protected campaign: PRICE 100, 10% commission, BUDGET 50, 7 day window.
    function _createP() internal returns (uint256) {
        return _createP(PRICE, BPS, BUDGET, WINDOW);
    }

    function _place(uint256 id, address ref) internal returns (uint256 oid) {
        vm.prank(buyer);
        oid = plug.buy(id, ref);
    }

    /// Default campaign + one order with `referrer`; returns (campaignId, orderId).
    function _setupOrder() internal returns (uint256 id, uint256 oid) {
        id = _createP();
        oid = _place(id, referrer);
    }

    // ---------- order actions with the correct caller ----------
    function _dispute(uint256 oid) internal {
        vm.prank(buyer);
        plug.dispute(oid, "not as described");
    }

    function _contest(uint256 oid) internal {
        vm.prank(advertiser);
        plug.contest(oid);
    }

    function _resolve(uint256 oid, bool refundBuyer) internal {
        vm.prank(arbiter);
        plug.resolve(oid, refundBuyer);
    }

    function _sellerRefund(uint256 oid) internal {
        vm.prank(advertiser);
        plug.refund(oid);
    }

    function _claim(uint256 oid) internal {
        vm.prank(buyer);
        plug.claimRefund(oid);
    }

    function _confirm(uint256 oid) internal {
        vm.prank(buyer);
        plug.confirm(oid);
    }

    function _release(uint256 oid) internal {
        vm.prank(other);
        plug.release(oid);
    }

    function _status(uint256 oid) internal view returns (PlugCampaigns.Status) {
        return plug.getOrder(oid).status;
    }

    function _releaseAt(uint256 oid) internal view returns (uint64) {
        return plug.getOrder(oid).releaseAt;
    }

    // ---------- solvency ----------
    function _sumBudgets() internal view returns (uint256 sum) {
        uint256 n = plug.campaignCount();
        for (uint256 i; i < n; i++) sum += plug.getCampaign(i).budgetRemaining;
    }

    /// token balance == sum(budgetRemaining) + reservedCommission + escrowedPrice + owedRefunds
    function _assertSolvent() internal view {
        assertEq(
            token.balanceOf(address(plug)),
            _sumBudgets() + plug.reservedCommission() + plug.escrowedPrice() + plug.owedRefunds(),
            "solvency"
        );
    }

    /// Sum of refundOwedOf over every order must equal the global owedRefunds counter.
    function _assertOwedConsistent() internal view {
        uint256 sum;
        uint256 n = plug.orderCount();
        for (uint256 i; i < n; i++) sum += plug.refundOwedOf(i);
        assertEq(plug.owedRefunds(), sum, "owedRefunds == sum(refundOwedOf)");
    }
}
