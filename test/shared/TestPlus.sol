// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Token} from "src/Types.sol";

contract TestPlus is Test {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           Helper                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _approve(ERC20 token, address owner, address spender, uint256 amount) internal {
        vm.prank(owner);
        token.approve(spender, amount);
    }

    function _approve(Token token, address owner, address spender, uint256 amount) internal {
        _approve(token.unwrap(), owner, spender, amount);
    }

    function _approve(address token, address owner, address spender, uint256 amount) internal {
        _approve(ERC20(token), owner, spender, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            Cheat                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function deal(Token token, address to, uint256 give) internal {
        if (token.isNative()) {
            deal(to, give);
        } else {
            deal(token.unwrap(), to, give);
        }
    }

    function deal(Token token, address to, uint256 give, bool adjust) internal {
        if (token.isNative()) {
            deal(to, give);
        } else {
            deal(token.unwrap(), to, give, adjust);
        }
    }
}
