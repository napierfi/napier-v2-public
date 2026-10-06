// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {MockERC4626Fees} from "./MockERC4626Fees.sol";
import {ERC20} from "solady/src/tokens/ERC4626.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @dev Conforming vault whose strategy touches Uniswap v4 while paying out, as `DeltaResolver._settle` does.
contract MockResyncingERC4626 is MockERC4626Fees {
    IPoolManager immutable i_poolManager;

    constructor(ERC20 asset_, bool useVirtualShares, address feeRecipient, IPoolManager poolManager_)
        MockERC4626Fees(asset_, useVirtualShares, 0, 0, feeRecipient)
    {
        i_poolManager = poolManager_;
    }

    function withdraw(uint256 assets, address to, address owner) public override returns (uint256 shares) {
        shares = super.withdraw(assets, to, owner);
        i_poolManager.sync(Currency.wrap(asset()));
    }

    function redeem(uint256 shares, address to, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, to, owner);
        i_poolManager.sync(Currency.wrap(asset()));
    }
}
