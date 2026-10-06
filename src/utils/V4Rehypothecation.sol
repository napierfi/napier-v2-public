// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {LibRehypothecation} from "../utils/LibRehypothecation.sol";
import {CurrencySettler} from "../utils/CurrencySettler.sol";
import {CustomRevert} from "../utils/CustomRevert.sol";

import "../Errors.sol";

library V4Rehypothecation {
    using CustomRevert for *;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*             Vault and Claim Tokens Operations              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Assumption:
    /// - `asset` is the same as `vault.asset()`.
    /// - `vault` takes the exact amount of `asset` as specified.
    function depositClaimTokensToVault(IPoolManager poolManager, ERC4626 vault, Currency asset, uint256 amount)
        internal
        returns (uint256 shares, uint256 assetsSpent)
    {
        // If PoolManager doesn't have enough tokens or we're trying to deposit more than the vault accepts
        // then we only deposit what we can
        // We're only maintaining the raw balance ratio so it's fine to deposit less than requested.
        uint256 maxDepositAmount = vault.maxDeposit(address(this));
        uint256 poolManagerBalance = SafeTransferLib.balanceOf(Currency.unwrap(asset), address(poolManager));
        amount = FixedPointMathLib.min(FixedPointMathLib.min(amount, maxDepositAmount), poolManagerBalance);

        // Burn and take real tokens from PoolManager
        CurrencySettler.cashOut(poolManager, asset, amount, address(this));

        (shares,, assetsSpent) = LibRehypothecation.depositToVault(vault, Currency.unwrap(asset), amount);

        if (assetsSpent < amount) {
            // Deposit excess amount back into PoolManager as claim tokens
            uint256 excess = amount - assetsSpent;
            CurrencySettler.cashIn(poolManager, asset, excess);
        }
    }

    /// @dev Assumption:
    /// - `asset` is the same as `vault.asset()`.
    /// - `vault` withdraw the exact amount of `asset` as specified.
    /// @dev `shares` and `assetsWithdrawn` are measured from this contract's balances, not the vault's return value
    function withdrawClaimTokensFromVault(IPoolManager poolManager, ERC4626 vault, Currency asset, uint256 amount)
        internal
        returns (uint256 shares, uint256 assetsWithdrawn)
    {
        if (amount == 0) return (0, 0);

        address token = Currency.unwrap(asset);
        uint256 sharesBefore = SafeTransferLib.balanceOf(address(vault), address(this));
        uint256 assetsBefore = SafeTransferLib.balanceOf(token, address(this));

        vault.withdraw(amount, address(this), address(this));

        shares = sharesBefore - SafeTransferLib.balanceOf(address(vault), address(this));
        assetsWithdrawn = SafeTransferLib.balanceOf(token, address(this)) - assetsBefore;

        CurrencySettler.cashIn(poolManager, asset, assetsWithdrawn);
    }

    /// @dev Assumption:
    /// - `asset` is the same as `vault.asset()`.
    /// - `vault` redeems the exact amount of `shares` as specified.
    /// @dev `sharesRedeemed` and `assets` are measured from this contract's balances, not the vault's return value
    function redeemClaimTokensFromVault(IPoolManager poolManager, ERC4626 vault, Currency asset, uint256 shares)
        internal
        returns (uint256 sharesRedeemed, uint256 assets)
    {
        if (shares == 0) return (0, 0);

        address token = Currency.unwrap(asset);
        uint256 sharesBefore = SafeTransferLib.balanceOf(address(vault), address(this));
        uint256 assetsBefore = SafeTransferLib.balanceOf(token, address(this));

        vault.redeem(shares, address(this), address(this));

        sharesRedeemed = sharesBefore - SafeTransferLib.balanceOf(address(vault), address(this));
        assets = SafeTransferLib.balanceOf(token, address(this)) - assetsBefore;

        // Revert if vault tried to redeem more shares than its requested
        if (sharesRedeemed > shares) {
            Errors.Rehypothecation_VaultRedeemMoreThanRequested.selector.revertWith();
        }

        CurrencySettler.cashIn(poolManager, asset, assets);
    }
}
