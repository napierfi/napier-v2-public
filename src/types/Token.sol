// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {Token} from "../Types.sol";
import {NATIVE_ETH} from "../Constants.sol";

function unwrap(Token x) pure returns (address result) {
    result = Token.unwrap(x);
}

function erc20(Token token) pure returns (ERC20 result) {
    result = ERC20(Token.unwrap(token));
}

function isNative(Token x) pure returns (bool result) {
    result = Token.unwrap(x) == NATIVE_ETH;
}

function isNotNative(Token x) pure returns (bool result) {
    result = Token.unwrap(x) != NATIVE_ETH;
}

function eq(Token token0, address token1) pure returns (bool result) {
    result = Token.unwrap(token0) == token1;
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     Utils For Test                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

function intoToken(address token) pure returns (Token result) {
    result = Token.wrap(token);
}
