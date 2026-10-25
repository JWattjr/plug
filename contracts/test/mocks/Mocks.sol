// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev 6-decimal mock USDC with open mint.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

interface IHookReceiver {
    function onTokenReceived() external;
}

/// @dev 6-decimal token that calls back into a registered hook contract when it receives tokens
///      (ERC777-like). Used to exercise reentrancy protection.
contract HookUSDC is ERC20 {
    mapping(address => bool) public hooked;

    constructor() ERC20("Hook USDC", "hUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setHooked(address who, bool on) external {
        hooked[who] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (hooked[to] && from != address(0)) IHookReceiver(to).onTokenReceived();
    }
}

/// @dev Attacker that tries to reenter PlugCampaigns when it receives tokens.
///      Can act as referrer or advertiser (the advertiser is also the merchant and receives sale proceeds).
contract Reentrant is IHookReceiver {
    enum Action { None, Buy, End, TopUp, Create }

    address public target;
    IERC20 public token;
    Action public action;
    uint256 public campaignId;
    uint256 public hits;
    bool public lastSuccess;
    bytes public lastRet;

    constructor(address target_, address token_) {
        target = target_;
        token = IERC20(token_);
        token.approve(target_, type(uint256).max);
    }

    function arm(Action a, uint256 id) external {
        action = a;
        campaignId = id;
    }

    function call_(bytes calldata data) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    function onTokenReceived() external override {
        if (action == Action.None) return;
        Action a = action;
        action = Action.None; // single attempt
        hits++;
        bytes memory data;
        if (a == Action.Buy) {
            data = abi.encodeWithSignature("buy(uint256,address)", campaignId, address(this));
        } else if (a == Action.End) {
            data = abi.encodeWithSignature("endCampaign(uint256)", campaignId);
        } else if (a == Action.TopUp) {
            data = abi.encodeWithSignature("topUp(uint256,uint256)", campaignId, uint256(1));
        } else {
            data = abi.encodeWithSignature(
                "createCampaign(string,string,uint256,uint16,uint256,uint64)",
                "t", "u", uint256(1), uint16(0), uint256(0), uint64(block.timestamp + 100)
            );
        }
        (lastSuccess, lastRet) = target.call(data);
    }
}
