// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {CustomRevert} from "./CustomRevert.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Constants.sol" as Constants;

library LibRehypothecation {
    using CustomRevert for *;
    using SafeCastLib for *;
    using FixedPointMathLib for uint256;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Validation                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function validateVault(ERC4626 vault, address asset) internal view {
        if (address(vault) != address(0) && vault.asset() != asset) {
            Errors.Rehypothecation_VaultAssetMismatch.selector.revertWith();
        }
    }

    function validateRehypothecationParams(
        uint256 targetRawTokenRatio0,
        uint256 maxRawTokenRatio0,
        uint256 minRawTokenRatio0
    ) internal pure {
        if (minRawTokenRatio0 > targetRawTokenRatio0) {
            Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector.revertWith();
        }
        if (targetRawTokenRatio0 > maxRawTokenRatio0) {
            Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector.revertWith();
        }
        if (maxRawTokenRatio0 > Constants.BASIS_POINTS) {
            Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector.revertWith();
        }
    }

    function isParamsFrozen(uint16 vaultFlags) internal pure returns (bool) {
        return vaultFlags & Constants.REHYPO_RATIOS_FROZEN != 0;
    }

    function validateParamsFrozen(uint16 vaultFlags) internal pure {
        if (isParamsFrozen(vaultFlags)) {
            Errors.Rehypothecation_ParamsFrozen.selector.revertWith();
        }
    }

    function validateVaultFrozen(uint16 vaultFlags) internal pure {
        if (vaultFlags & Constants.REHYPO_VAULT_FROZEN != 0) {
            Errors.Rehypothecation_VaultFrozen.selector.revertWith();
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           Views                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getReservesInUnderlying(ERC4626 vault, uint256 reserveAmount) internal view returns (uint256) {
        if (address(vault) == address(0)) return 0;
        return vault.previewRedeem(reserveAmount);
    }

    function getTotalBalances(ERC4626 vault0, ERC4626 vault1, Uint128x2 reserves, Uint128x2 rawBalances)
        internal
        view
        returns (Uint128x2 balances)
    {
        balances = Packing.pack_uint128x2(
            getReservesInUnderlying(vault0, reserves.value0()).toUint128(),
            getReservesInUnderlying(vault1, reserves.value1()).toUint128()
        ).radd(rawBalances);
    }

    function calculateDepositAmount(uint256 amount, uint256 targetRawTokenRatio) internal pure returns (uint256) {
        return amount - amount.mulDiv(targetRawTokenRatio, Constants.BASIS_POINTS);
    }

    function calculateDepositAmount(ERC4626 vault, uint256 amount, uint256 targetRawTokenRatio)
        internal
        view
        returns (uint256)
    {
        if (address(vault) == address(0)) return 0;
        uint256 depositAmount = calculateDepositAmount(amount, targetRawTokenRatio);

        if (depositAmount == 0) return 0;

        uint256 maxDeposit = vault.maxDeposit(address(this));
        return FixedPointMathLib.min(depositAmount, maxDeposit);
    }

    function calculateRawBalanceBounds(
        uint256 balance,
        uint256 targetRawTokenRatio,
        uint256 maxRawTokenRatio,
        uint256 minRawTokenRatio
    ) internal pure returns (uint256 targetRawBalance, uint256 minRawBalance, uint256 maxRawBalance) {
        minRawBalance = FixedPointMathLib.mulDiv(balance, minRawTokenRatio, Constants.BASIS_POINTS);
        maxRawBalance = FixedPointMathLib.mulDiv(balance, maxRawTokenRatio, Constants.BASIS_POINTS);
        targetRawBalance = FixedPointMathLib.mulDiv(balance, targetRawTokenRatio, Constants.BASIS_POINTS);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Vault Operations                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Assumption:
    /// - `asset` is the same as `vault.asset()`.
    /// - `vault` takes the exact amount of `asset` as specified.
    /// @dev Reverts if vault tries to spend more assets than requested
    /// @dev `shares` is measured from this contract's share balance, not the vault's return value
    function depositToVault(ERC4626 vault, address asset, uint256 amount)
        internal
        returns (uint256 shares, uint256 sharesInAsset, uint256 assetsSpent)
    {
        if (amount == 0) return (0, 0, 0);

        // Approve the vault to transfer tokens
        SafeTransferLib.safeApproveWithRetry(asset, address(vault), amount);
        // Deposit into vault
        uint256 balanceBefore = SafeTransferLib.balanceOf(asset, address(this));
        uint256 sharesBefore = SafeTransferLib.balanceOf(address(vault), address(this));
        vault.deposit(amount, address(this));
        shares = SafeTransferLib.balanceOf(address(vault), address(this)) - sharesBefore;
        sharesInAsset = vault.previewRedeem(shares);
        assetsSpent = balanceBefore - SafeTransferLib.balanceOf(asset, address(this));

        // Somehow lost more tokens than requested. This should never happen unless something is seriously wrong
        if (assetsSpent > amount) Errors.Rehypothecation_VaultDepositMoreThanRequested.selector.revertWith();
        if (assetsSpent != amount) {
            // Reset approval to vault to avoid any allowance abuse by malicious vault in some other piece of codebase
            SafeTransferLib.safeApproveWithRetry(asset, address(vault), 0);
        }
    }

    /// @dev Any left over will be refunded to `refundReceiver`
    /// @dev Assumption: See `depositToVault`
    function depositToVaultWithRefund(ERC4626 vault, address asset, uint256 amount, address refundReceiver)
        internal
        returns (uint256 shares, uint256 sharesInAsset, uint256 assetsSpent)
    {
        (shares, sharesInAsset, assetsSpent) = depositToVault(vault, asset, amount);

        // Edge case: Refund if any amount that vault didn't spend.
        if (assetsSpent < amount) {
            unchecked {
                SafeTransferLib.safeTransfer(asset, refundReceiver, amount - assetsSpent);
            }
        }
    }

    /// @dev Preview of `depositToVault`
    function previewDeposit(ERC4626 vault, uint256 amount)
        internal
        view
        returns (uint256 shares, uint256 sharesInAsset)
    {
        if (amount == 0) return (0, 0);

        shares = vault.previewDeposit(amount);
        sharesInAsset = vault.previewRedeem(shares);
    }

    /// @dev Redeem shares from vault and ensure no more shares are redeemed than requested
    function redeemFromVault(ERC4626 vault, address asset, uint256 shares, address receiver)
        internal
        returns (uint256 sharesRedeemed, uint256 assets)
    {
        if (shares == 0) return (0, 0);

        // Execute redeem from this contract and deliver assets to receiver
        uint256 balanceBefore = SafeTransferLib.balanceOf(asset, receiver);
        uint256 sharesBefore = SafeTransferLib.balanceOf(address(vault), address(this));

        vault.redeem(shares, receiver, address(this));

        uint256 balanceAfter = SafeTransferLib.balanceOf(asset, receiver);
        uint256 sharesAfter = SafeTransferLib.balanceOf(address(vault), address(this));

        sharesRedeemed = sharesBefore - sharesAfter;
        assets = balanceAfter - balanceBefore;

        // Invariant: sharesRedeemed must be <= requested shares
        if (sharesRedeemed > shares) {
            Errors.Rehypothecation_VaultRedeemMoreThanRequested.selector.revertWith();
        }
    }
}
