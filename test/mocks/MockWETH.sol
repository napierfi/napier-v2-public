// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {WETH} from "solady/src/tokens/WETH.sol";

interface _Vm {
    function deal(address to, uint256 give) external;
}

contract MockWETH is WETH {
    _Vm private constant vm = _Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Cheat code to mint WETH for testing purposes for compatibility with MockERC20
    function mint(address to, uint256 amount) external {
        vm.deal(address(this), address(this).balance + amount);
        _mint(to, amount);
    }
}
