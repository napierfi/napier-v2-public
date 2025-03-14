// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../Types.sol";

/// @notice This wrapper interface is used to wrap rebase tokens or non-tokenized vaults into a tokenized vault.
/// - The underlying token of PT has to be set to the wrapper vault instead of the original underlying token.
/// - `asset()` must return the base asset of the underlying token, which represents the unit of the wrapper vault `totalAssets()`.
/// - If the underlying vault is a non-tokenized vault, `target()` must return the address of this wrapper.
/// @dev Glossary in the context of wrapper:
/// - `token`: the token we want to be paid out or paid in.
/// - `tokens`: the amount of `token`
/// - `underlying`: the yield-bearing token originally meant to be the underlying token of a PT. e.g. aToken
/// - `underlyings`: the amount of underlying tokens
/// - `shares`: the amount of this wrapper vault. e.g. np-aToken
interface IERC4626Wrapper {
    /// @notice The address of the original underlying vault that this wrapper wraps.
    /// @dev Vault may be a non-tokenized vault.
    function vault() external view returns (address);

    /// @notice ERC4626-like deposit function but `token` can be several assets.
    /// @dev Revert `ERC4626Wrapper_TokenNotListed()` if `token` is not supported.
    /// @param token The token to deposit. Native ETH, WETH and stETH for wsETH.
    /// @param tokens The amount of `token` to deposit.
    /// @param receiver The address to receive the shares.
    /// @return The amount of shares minted.
    function deposit(Token token, uint256 tokens, address receiver) external payable returns (uint256);

    /// @notice ERC4626-like redeem function but `token` can be several assets.
    /// @dev Revert `ERC4626Wrapper_TokenNotListed()` if `token` is not supported.
    /// @param token The token we want to be paid out in.
    /// @param shares The amount of vault shares to redeem. It is NOT the amount of `token` to redeem.
    /// @param receiver The address to receive the tokens.
    /// @return The amount of `token` redeemed.
    function redeem(Token token, uint256 shares, address receiver) external returns (uint256);

    /// @notice Preview version of `deposit` function.
    /// @dev Override this function in the derived contract if the underlying vault is a non-tokenized vault.
    function previewDeposit(Token token, uint256 tokens) external view returns (uint256);

    /// @notice Preview version of `redeem` function.
    /// @dev Override this function in the derived contract if the underlying vault is a non-tokenized vault.
    function previewRedeem(Token token, uint256 shares) external view returns (uint256);

    /// @notice Claims rewards from the underlying tokens.
    /// @dev If needed, implement this function in the derived contract.
    function claimRewards() external returns (TokenReward[] memory);

    /// @notice The tokens that can be used as `token` in `deposit` function.
    function getTokenInList() external view returns (Token[] memory);

    /// @notice The tokens that can be used as `token` in `redeem` function.
    function getTokenOutList() external view returns (Token[] memory);
}
