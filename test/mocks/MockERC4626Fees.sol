// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {MockERC4626} from "./MockERC4626.sol";
import {ERC4626, ERC20} from "solady/src/tokens/ERC4626.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

/// @dev MODIFIED FROM: https://github.com/OpenZeppelin/openzeppelin-contracts/blob/29090987554039a82519c894c8cab1146fb4ca17/contracts/mocks/docs/ERC4626Fees.sol
contract MockERC4626Fees is MockERC4626 {
    using FixedPointMathLib for uint256;

    uint256 private constant BASIS_POINT = 10_000;

    uint256 public s_entryFeeBasisPoints;
    uint256 public s_exitFeeBasisPoints;
    uint256 public s_withdrawCap = type(uint256).max;
    address public immutable i_feeRecipient;

    constructor(
        ERC20 asset_,
        bool useVirtualShares,
        uint256 entryFeeBasisPoints,
        uint256 exitFeeBasisPoints,
        address feeRecipient
    ) MockERC4626(asset_, useVirtualShares) {
        require(entryFeeBasisPoints <= BASIS_POINT, "Entry fee exceeds 100%");
        require(exitFeeBasisPoints <= BASIS_POINT, "Exit fee exceeds 100%");
        require(feeRecipient != address(0), "Fee recipient cannot be zero address");

        s_entryFeeBasisPoints = entryFeeBasisPoints;
        s_exitFeeBasisPoints = exitFeeBasisPoints;
        i_feeRecipient = feeRecipient;
    }

    // === Overrides ===

    function previewDeposit(uint256 assets) public view virtual override returns (uint256) {
        uint256 fee = _feeOnTotal(assets, s_entryFeeBasisPoints);
        return super.previewDeposit(assets - fee);
    }

    function previewMint(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = super.previewMint(shares);
        return assets + _feeOnRaw(assets, s_entryFeeBasisPoints);
    }

    function previewWithdraw(uint256 assets) public view virtual override returns (uint256) {
        uint256 fee = _feeOnRaw(assets, s_exitFeeBasisPoints);
        return super.previewWithdraw(assets + fee);
    }

    function previewRedeem(uint256 shares) public view virtual override returns (uint256) {
        uint256 assets = super.previewRedeem(shares);
        return assets - _feeOnTotal(assets, s_exitFeeBasisPoints);
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal virtual override {
        uint256 fee = _feeOnTotal(assets, s_entryFeeBasisPoints);
        address recipient = i_feeRecipient;

        super._deposit(caller, receiver, assets, shares);

        if (fee > 0 && recipient != address(this)) {
            ERC20(asset()).transfer(recipient, fee);
        }
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        uint256 fee = _feeOnRaw(assets, s_exitFeeBasisPoints);
        address recipient = i_feeRecipient;

        super._withdraw(caller, receiver, owner, assets, shares);

        if (fee > 0 && recipient != address(this)) {
            ERC20(asset()).transfer(recipient, fee);
        }
    }

    // === Fee configuration ===

    function setEntryFeeBasisPoints(uint256 newFee) external {
        require(newFee <= BASIS_POINT, "Fee exceeds 100%");
        s_entryFeeBasisPoints = newFee;
    }

    function setExitFeeBasisPoints(uint256 newFee) external {
        require(newFee <= BASIS_POINT, "Fee exceeds 100%");
        s_exitFeeBasisPoints = newFee;
    }

    /// @dev Models a liquidity-aware vault such as `ATokenWrapper`: capacity is bounded by the underlying
    /// market, independently of the owner's share balance.
    function setWithdrawCap(uint256 newCap) external {
        s_withdrawCap = newCap;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return FixedPointMathLib.min(s_withdrawCap, super.maxWithdraw(owner));
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        if (s_withdrawCap == type(uint256).max) return super.maxRedeem(owner);
        return FixedPointMathLib.min(convertToShares(s_withdrawCap), super.maxRedeem(owner));
    }

    // === Fee operations ===

    /// @dev Calculates the fees that should be added to an amount `assets` that does not already include fees.
    /// Used in {IERC4626-mint} and {IERC4626-withdraw} operations.
    function _feeOnRaw(uint256 assets, uint256 feeBasisPoints) private pure returns (uint256) {
        return assets.mulDiv(feeBasisPoints, BASIS_POINT);
    }

    /// @dev Calculates the fee part of an amount `assets` that already includes fees.
    /// Used in {IERC4626-deposit} and {IERC4626-redeem} operations.
    function _feeOnTotal(uint256 assets, uint256 feeBasisPoints) private pure returns (uint256) {
        return assets.mulDivUp(feeBasisPoints, feeBasisPoints + BASIS_POINT);
    }
}
