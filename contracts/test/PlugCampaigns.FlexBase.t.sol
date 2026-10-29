// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsV2Base} from "./PlugCampaigns.V2Base.t.sol";
import {FlexUSDC} from "./mocks/FlexMocks.sol";

/// @dev Fixtures for closed-budget credit scenarios. Uses FlexUSDC (blocklist + quota + hooks).
///      Contains no tests. Default campaign: PRICE 100e6, 10% commission (10e6), BUDGET 50e6, 7 day window.
abstract contract PlugCampaignsFlexBase is PlugCampaignsV2Base {
    FlexUSDC internal flex;
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual override {
        vm.warp(1_000_000);
        flex = new FlexUSDC();
        bl = flex;
        usdc = flex;
        token = IERC20(address(flex));
        plug = new PlugCampaigns(address(flex));
        address[3] memory who = [advertiser, buyer, other];
        for (uint256 i; i < 3; i++) {
            flex.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            flex.approve(address(plug), type(uint256).max);
        }
    }

    function _endAs(address who, uint256 id) internal {
        vm.prank(who);
        plug.endCampaign(id);
    }

    function _withdraw(address who, uint256 id) internal {
        vm.prank(who);
        plug.withdrawClosedBudget(id);
    }

    function _budget(uint256 id) internal view returns (uint256) {
        return plug.getCampaign(id).budgetRemaining;
    }

    /// Order on the default campaign, campaign ended by the advertiser (unspent budget refunded),
    /// advertiser then blocklisted, buyer refunded after dispute timeout => COMMISSION credited
    /// to the inactive campaign's budgetRemaining.
    function _creditViaClaim() internal returns (uint256 id, uint256 oid) {
        (id, oid) = _setupOrder();
        _endAs(advertiser, id);
        bl.setBlocklisted(advertiser, true);
        _dispute(oid);
        skip(DISPUTE_PERIOD);
        _claim(oid);
    }

    /// Same credit, produced by the arbiter ruling for the buyer.
    function _creditViaResolve() internal returns (uint256 id, uint256 oid) {
        (id, oid) = _setupOrder();
        _endAs(advertiser, id);
        bl.setBlocklisted(advertiser, true);
        _dispute(oid);
        _contest(oid);
        _resolve(oid, true);
    }

    /// Same credit, produced by a voluntary seller refund.
    function _creditViaSellerRefund() internal returns (uint256 id, uint256 oid) {
        (id, oid) = _setupOrder();
        _endAs(advertiser, id);
        bl.setBlocklisted(advertiser, true);
        _sellerRefund(oid);
    }

    /// Release with an undeliverable commission on an ended campaign: the seller accepts exactly
    /// one inflow (the sale price), the referrer is blocklisted, so the commission return to the
    /// seller fails and stays credited to the inactive campaign.
    function _creditViaRelease() internal returns (uint256 id, uint256 oid) {
        (id, oid) = _setupOrder();
        _endAs(advertiser, id);
        flex.setQuota(advertiser, true, 1);
        bl.setBlocklisted(referrer, true);
        skip(WINDOW);
        _release(oid);
    }

    /// Lift every restriction the credit helpers put on the advertiser / referrer.
    function _heal() internal {
        bl.setBlocklisted(advertiser, false);
        bl.setBlocklisted(referrer, false);
        flex.setQuota(advertiser, false, 0);
    }
}
