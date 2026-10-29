// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlugCampaigns} from "../PlugCampaigns.sol";
import {MockUSDC} from "./mocks/Mocks.sol";

/// @dev Shared fixtures and helpers. Contains no test functions.
abstract contract PlugCampaignsBase is Test {
    PlugCampaigns internal plug;
    MockUSDC internal usdc;

    address internal advertiser = makeAddr("advertiser");
    address internal buyer = makeAddr("buyer");
    address internal referrer = makeAddr("referrer");
    address internal other = makeAddr("other");
    address internal aliasRef = makeAddr("aliasRef"); // second address of the same entity

    uint256 internal constant PRICE = 100e6;
    uint16 internal constant BPS = 1000; // 10% => 10e6
    uint256 internal constant COMMISSION = 10e6;
    uint256 internal constant BUDGET = 50e6;
    uint64 internal constant DURATION = 1 days;

    function setUp() public virtual {
        vm.warp(1_000_000);
        usdc = new MockUSDC();
        plug = new PlugCampaigns(address(usdc));
        address[3] memory who = [advertiser, buyer, other];
        for (uint256 i; i < 3; i++) {
            usdc.mint(who[i], 1_000_000e6);
            vm.prank(who[i]);
            usdc.approve(address(plug), type(uint256).max);
        }
    }

    function _end() internal view returns (uint64) {
        return uint64(block.timestamp + DURATION);
    }

    function _create(uint256 price, uint16 bps, uint256 budget) internal returns (uint256 id) {
        vm.prank(advertiser);
        id = plug.createCampaign("Title", "https://x.y", price, bps, budget, _end(), 0, address(0));
    }

    function _create() internal returns (uint256) {
        return _create(PRICE, BPS, BUDGET);
    }

    function _buy(uint256 id, address ref) internal {
        vm.prank(buyer);
        plug.buy(id, ref);
    }
}
