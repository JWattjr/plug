// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockUSDC} from "./Mocks.sol";

/// @dev Mock USDC with an issuer blocklist: any transfer/mint/transferFrom whose `from` or `to`
///      is blocklisted reverts (mirrors Circle USDC semantics). Burns/mints of address(0) are exempt.
contract BlocklistUSDC is MockUSDC {
    error Blocklisted(address account);

    mapping(address => bool) public isBlocklisted;

    function setBlocklisted(address who, bool on) external {
        isBlocklisted[who] = on;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isBlocklisted[from]) revert Blocklisted(from);
        if (isBlocklisted[to]) revert Blocklisted(to);
        super._update(from, to, value);
    }
}

/// @dev Mock USDC whose `transfer` (NOT transferFrom) misbehaves for flagged recipients, to model
///      non-reverting / non-standard return paths of a low-level token call.
contract MisbehavingUSDC is ERC20 {
    enum Mode {
        Normal, //     standard behaviour
        ReturnFalse, //  returns false, moves nothing
        ReturnNoData, // moves tokens, returns no data (USDT-style)
        ReturnNoDataNoMove, // returns no data but moves nothing (success without delivery is NOT detectable; control)
        ReturnTwoWords, // moves nothing, returns 64 bytes (first word == 1)
        ReturnBlob, //   moves nothing, returns a huge (64KB) blob starting with word 1
        ReturnWordTwo, // returns uint256(2) (not exactly true), moves nothing
        BurnAllGas //    consumes all forwarded gas via INVALID
    }

    mapping(address => Mode) public modeOf;

    constructor() ERC20("Misbehaving USDC", "xUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(address to, Mode m) external {
        modeOf[to] = m;
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        Mode m = modeOf[to];
        if (m == Mode.Normal) return super.transfer(to, value);
        if (m == Mode.ReturnFalse) return false;
        if (m == Mode.ReturnNoData) {
            _transfer(msg.sender, to, value);
            assembly {
                return(0, 0)
            }
        }
        if (m == Mode.ReturnNoDataNoMove) {
            assembly {
                return(0, 0)
            }
        }
        if (m == Mode.ReturnTwoWords) {
            assembly {
                mstore(0x00, 1)
                mstore(0x20, 1)
                return(0x00, 0x40)
            }
        }
        if (m == Mode.ReturnBlob) {
            assembly {
                mstore(0x00, 1)
                return(0x00, 65536)
            }
        }
        if (m == Mode.ReturnWordTwo) {
            assembly {
                mstore(0x00, 2)
                return(0x00, 0x20)
            }
        }
        assembly {
            invalid()
        }
    }
}
