// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TokenNameLib} from "src/utils/TokenNameLib.sol";

contract TokenNameLibTest is Test {
    address target = address(this);
    uint256 expiry = 1630454400; // September 1, 2021 at 7:00:00 Indochina Time

    function name() public pure returns (string memory) {
        return "TokenName";
    }

    function symbol() public pure returns (string memory) {
        return "SYMBOL";
    }

    function test_principalTokenName() public view {
        string memory result = TokenNameLib.principalTokenName(target, expiry);
        console2.log(result);
    }

    function test_principalTokenSymbol() public view {
        string memory result = TokenNameLib.principalTokenSymbol(target, expiry);
        console2.log(result);
    }

    function test_yieldTokenName() public view {
        string memory result = TokenNameLib.yieldTokenName(target, expiry);
        console2.log(result);
    }

    function test_yieldTokenSymbol() public view {
        string memory result = TokenNameLib.yieldTokenSymbol(target, expiry);
        console2.log(result);
    }

    function test_lpTokenName() public view {
        string memory result = TokenNameLib.lpTokenName(target, expiry);
        console2.log(result);
    }

    function test_lpTokenSymbol() public view {
        string memory result = TokenNameLib.lpTokenSymbol(target, expiry);
        console2.log(result);
    }
}
