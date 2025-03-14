// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 s_decimals;

    constructor(uint8 _decimals) {
        s_decimals = _decimals;
    }

    function name() public pure override returns (string memory) {
        return "MockERC20";
    }

    function symbol() public pure override returns (string memory) {
        return "MOCK";
    }

    function decimals() public view override returns (uint8) {
        return s_decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }
}
