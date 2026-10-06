// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {MockERC4626} from "./MockERC4626.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

contract MockERC4626TakeLess is MockERC4626 {
    constructor(ERC20 asset_, bool useVirtualShares) MockERC4626(asset_, useVirtualShares) {}

    function deposit(uint256 assets, address to) public override returns (uint256 shares) {
        assets = assets * 90 / 100; // Take 90% of the assets
        return super.deposit(assets, to);
    }
}
