// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BlocklistUSDC} from "./BlocklistMocks.sol";
import {IHookReceiver} from "./Mocks.sol";

/// @dev Blocklist token plus two knobs used by the closed-budget tests:
///      - quota: a limited recipient accepts only `quota` more inflows, then every inflow reverts
///        (lets a seller receive a release price but NOT the later commission return);
///      - hooked: ERC777-style callback into the recipient after it receives tokens.
contract FlexUSDC is BlocklistUSDC {
    error QuotaExhausted(address account);

    mapping(address => bool) public limited;
    mapping(address => uint256) public quota;
    mapping(address => bool) public hooked;

    function setQuota(address who, bool on, uint256 q) external {
        limited[who] = on;
        quota[who] = q;
    }

    function setHooked(address who, bool on) external {
        hooked[who] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (limited[to]) {
            if (quota[to] == 0) revert QuotaExhausted(to);
            quota[to] -= 1;
        }
        super._update(from, to, value);
        if (hooked[to] && from != address(0)) IHookReceiver(to).onTokenReceived();
    }
}
