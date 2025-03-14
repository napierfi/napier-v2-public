// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {Token} from "../../Types.sol";
import {IWETH} from "../../interfaces/IWETH.sol";

abstract contract VaultConnector {
    function asset() public view virtual returns (address);

    function target() public view virtual returns (address);

    /// @notice ERC4626-like conversion function.
    function convertToAssets(uint256 shares) public view virtual returns (uint256);

    /// @notice ERC4626-like conversion function.
    function convertToShares(uint256 assets) public view virtual returns (uint256);

    function previewDeposit(Token token, uint256 tokens) public view virtual returns (uint256 shares);
    function previewRedeem(Token token, uint256 shares) public view virtual returns (uint256 tokens);

    /// @notice ERC4626-like deposit function but `token` can be several assets.
    /// @param token The token to deposit. Native ETH, WETH and stETH for wsETH.
    /// @param tokens The amount of `token` to deposit.
    /// @param receiver The address to receive the shares.
    /// @return shares The amount of vault shares to be received.
    function deposit(Token token, uint256 tokens, address receiver) public payable virtual returns (uint256 shares);

    /// @notice ERC4626-like redeem function but `token` can be several assets.
    /// @param token The token we want to be paid out in.
    /// @param shares The amount of vault shares to redeem. It is NOT the amount of `token` to redeem.
    /// @param receiver The address to receive the tokens.
    /// @return tokens The amount of `token` to be received.
    function redeem(Token token, uint256 shares, address receiver) public virtual returns (uint256 tokens);

    /// @notice The tokens that can be used as `token` in `deposit` function.
    function getTokenInList() public view virtual returns (Token[] memory);

    /// @notice The tokens that can be used as `token` in `redeem` function.
    function getTokenOutList() public view virtual returns (Token[] memory);

    function _getWETHAddress() internal view virtual returns (address);

    function _wrapETH(uint256 amount) internal {
        address weth = _getWETHAddress();
        IWETH(weth).deposit{value: amount}();
    }

    function _unwrapWETH(address receiver, uint256 amount) internal {
        address weth = _getWETHAddress();
        IWETH(weth).withdraw(amount);
        SafeTransferLib.safeTransferETH(receiver, amount);
    }
}
