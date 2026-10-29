// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PlugCampaigns} from "../PlugCampaigns.sol";
import {PlugCampaignsBase} from "./PlugCampaigns.Base.t.sol";

contract PlugCampaignsFuzzTest is PlugCampaignsBase {
    function _refFor(uint8 kind) internal view returns (address) {
        uint8 k = kind % 4;
        if (k == 0) return address(0);
        if (k == 1) return buyer;
        if (k == 2) return advertiser;
        return referrer;
    }

    /// Advertiser (the merchant) always gets exactly `price`; referrer gets floor(price*bps/10000) iff eligible.
    function testFuzz_SplitIsExact(uint256 price, uint16 bpsIn, uint8 kind) public {
        price = bound(price, 1, 1e30);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        usdc.mint(advertiser, price);
        usdc.mint(buyer, price);
        uint256 id = _create(price, bps, price); // budget >= max commission (price/2)
        address ref = _refFor(kind);
        bool eligible = ref == referrer;
        uint256 expected = eligible ? (price * bps) / 10000 : 0;

        uint256 mBefore = usdc.balanceOf(advertiser);
        uint256 rBefore = usdc.balanceOf(ref);
        uint256 bBefore = usdc.balanceOf(buyer);
        _buy(id, ref);

        assertEq(usdc.balanceOf(buyer), bBefore - price, "buyer pays exactly price");
        assertEq(usdc.balanceOf(advertiser), mBefore + price, "advertiser exact price");
        if (ref != buyer && ref != address(0) && ref != advertiser) {
            assertEq(usdc.balanceOf(ref) - rBefore, expected, "referrer exact commission");
        }
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining, price - expected);
        assertEq(c.commissionPaid, expected);
        assertEq(c.sales, 1);
        assertEq(plug.referrerEarnings(ref), expected);
        assertEq(usdc.balanceOf(address(plug)), price - expected);
    }

    /// Commission is all-or-nothing depending on budget >= commission.
    function testFuzz_BudgetGate(uint256 price, uint16 bpsIn, uint256 budgetSeed) public {
        price = bound(price, 1, 1e30);
        uint16 bps = uint16(bound(bpsIn, 1, 5000));
        uint256 commission = (price * bps) / 10000;
        uint256 budget = bound(budgetSeed, 0, 2 * commission + 1);
        usdc.mint(advertiser, budget);
        usdc.mint(buyer, price);
        uint256 id = _create(price, bps, budget);
        uint256 advBefore = usdc.balanceOf(advertiser);
        _buy(id, referrer);

        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.sales, 1);
        assertEq(usdc.balanceOf(advertiser), advBefore + price);
        if (budget >= commission) {
            assertEq(usdc.balanceOf(referrer), commission);
            assertEq(c.budgetRemaining, budget - commission);
        } else {
            assertEq(usdc.balanceOf(referrer), 0);
            assertEq(c.budgetRemaining, budget);
        }
        assertEq(usdc.balanceOf(address(plug)), c.budgetRemaining);
    }

    function testFuzz_BpsAbove5000Reverts(uint16 bps) public {
        bps = uint16(bound(bps, 5001, type(uint16).max));
        vm.prank(advertiser);
        vm.expectRevert(abi.encodeWithSelector(PlugCampaigns.InvalidCommissionBps.selector, bps));
        plug.createCampaign("t", "u", PRICE, bps, BUDGET, _end(), 0, address(0));
    }

    /// Buyer == referrer never earns a commission, whatever the parameters.
    function testFuzz_SelfReferralNeverPays(uint256 price, uint16 bpsIn) public {
        price = bound(price, 1, 1e30);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        usdc.mint(advertiser, price);
        usdc.mint(buyer, price);
        uint256 id = _create(price, bps, price);
        uint256 bBefore = usdc.balanceOf(buyer);
        _buy(id, buyer);
        assertEq(usdc.balanceOf(buyer), bBefore - price);
        assertEq(plug.getCampaign(id).budgetRemaining, price);
    }

    /// Escrow + paid-out commission + refund always add back up to deposited budget.
    function testFuzz_EndRefundsExactlyRemaining(uint256 price, uint16 bpsIn, uint8 sales) public {
        price = bound(price, 1, 1e24);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        uint256 n = bound(sales, 0, 8);
        uint256 budget = price * 2;
        usdc.mint(advertiser, budget);
        usdc.mint(buyer, price * n);
        uint256 id = _create(price, bps, budget);
        uint256 advAfterCreate = usdc.balanceOf(advertiser);
        for (uint256 i; i < n; i++) _buy(id, referrer);
        PlugCampaigns.Campaign memory c = plug.getCampaign(id);
        assertEq(c.budgetRemaining + c.commissionPaid, budget);
        vm.warp(_end());
        vm.prank(other);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser), advAfterCreate + n * price + c.budgetRemaining, "sale proceeds + refund");
        assertEq(usdc.balanceOf(address(plug)), 0);
        assertEq(usdc.balanceOf(referrer), c.commissionPaid);
    }

    /// Seller buying from itself through an alias referrer: entity (advertiser+alias) nets exactly zero.
    function testFuzz_SellerSelfBuyViaAliasNetsZero(uint256 price, uint16 bpsIn, uint256 budgetSeed) public {
        price = bound(price, 1, 1e30);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        uint256 budget = bound(budgetSeed, 0, 2 * price);
        usdc.mint(advertiser, budget + price);
        uint256 entityBefore = usdc.balanceOf(advertiser) + usdc.balanceOf(aliasRef);
        uint256 id = _create(price, bps, budget);
        vm.prank(advertiser);
        plug.buy(id, aliasRef);
        vm.prank(advertiser);
        plug.endCampaign(id);
        assertEq(usdc.balanceOf(advertiser) + usdc.balanceOf(aliasRef), entityBefore, "seller wash trade is net zero");
        assertEq(usdc.balanceOf(address(plug)), 0);
    }

    /// A third-party buyer who is the referrer, or who colludes via an alias, strictly loses
    /// at least price - commission >= 50% of price.
    function testFuzz_ThirdPartyBuyerAlwaysLoses(uint256 price, uint16 bpsIn, bool useAlias) public {
        price = bound(price, 1, 1e30);
        uint16 bps = uint16(bound(bpsIn, 0, 5000));
        usdc.mint(advertiser, price);
        usdc.mint(buyer, price);
        uint256 id = _create(price, bps, price); // budget always covers the commission
        address ref = useAlias ? aliasRef : buyer;
        uint256 commission = (price * bps) / 10000;
        int256 before_ = int256(usdc.balanceOf(buyer) + usdc.balanceOf(aliasRef));
        if (!useAlias) before_ = int256(usdc.balanceOf(buyer));
        _buy(id, ref);
        int256 after_ = int256(usdc.balanceOf(buyer) + (useAlias ? usdc.balanceOf(aliasRef) : 0));
        int256 net = after_ - before_;
        assertLe(net, -int256(price - commission), "loss >= price - commission");
        assertLt(net, 0, "strictly negative");
        assertGe((price - commission) * 2, price, "price - commission >= 50% of price");
        // exact: alias earns commission, buyer pays price; own-referral earns nothing
        assertEq(net, useAlias ? int256(commission) - int256(price) : -int256(price));
    }
}
