// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {IMerkl} from "../../interfaces/external/IMerkl.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IAToken} from "./interfaces/IAToken.sol";
import {WrapperFactory} from "../WrapperFactory.sol";

import "src/Types.sol";
import "src/Errors.sol";
import {AaveV3PoolLens} from "./utils/AaveV3PoolLens.sol";

import {AccessManaged, AccessManager} from "src/modules/AccessManager.sol";
import {StandardERC4626Wrapper} from "../StandardERC4626Wrapper.sol";

/// @dev A wrapper for Aave v3 aTokens meant to be deployed via clone with immutable args:
/// abi.encode(address aToken)
/// - address aToken: the address of the aToken
/// @dev Glossary in the context of wrapper:
/// - `token`: the token we want to be paid out or paid in.
/// - `tokens`: the amount of `token`
/// - `underlyings`: the amount of aToken
/// - `shares`: the amount of the wrapper vault. e.g. np-aToken
/// @dev Important note:
/// - Aave v3 distributes two ways of rewards today:
///   - RewardsController: the normal incentive distributor by Aave protocol, most of them are moved to Angle Merkl distributor
///   - Angle Merkl distributor: Merkle distributor by Angle
/// - The wrapper doesn't support rewards distributed by RewardsController
/// - If reward is same as the underlying aToken itself, the reward will be combined with the underlying aToken balance, which increases the vault share price instantly.
/// - The accumulated rewards will be swept by a trusted account
/// - Angle Merkl distributor allows anyone else to claim rewards on behalf of the wrapper
contract ATokenWrapper is StandardERC4626Wrapper, ReentrancyGuard, Initializable, AccessManaged {
    /// @notice The access manager for this wrapper
    AccessManager internal s_accessManager;

    /// @inheritdoc StandardERC4626Wrapper
    function initialize() external override initializer {
        (, address assetAddr, IPool pool) = _parseImmutableArgs();

        s_accessManager = WrapperFactory(msg.sender).i_accessManager();
        // Assumption: Aave v3 pool never changes after initialization, so we can safely approve the asset once
        SafeTransferLib.safeApprove(assetAddr, address(pool), type(uint256).max);
    }

    /// @notice The total assets == the aToken balance of this wrapper
    function totalAssets() public view override returns (uint256) {
        (address aToken,,) = _parseImmutableArgs();
        // aTokens use rebasing to accrue interest, so the total assets is just the aToken balance
        return SafeTransferLib.balanceOf(aToken, address(this));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*        ERC4626 DEPOSIT / WITHDRAWAL LOGIC OVERRIDE         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function deposit(uint256 assets, address to) public override nonReentrant returns (uint256 shares) {
        return super.deposit(assets, to);
    }

    function mint(uint256 shares, address to) public override nonReentrant returns (uint256 assets) {
        return super.mint(shares, to);
    }

    function withdraw(uint256 assets, address to, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        return super.withdraw(assets, to, owner);
    }

    function redeem(uint256 shares, address to, address owner) public override nonReentrant returns (uint256 assets) {
        return super.redeem(shares, to, owner);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*       ERC4626 AFTER DEPOSIT / BEFORE WITHDRAW LOGIC        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Supply assets to Aave v3 pool after ERC4626 regular deposit workflow
    function _afterDeposit(uint256 assets, uint256 /* shares */ ) internal override {
        (, address assetAddr, IPool pool) = _parseImmutableArgs();

        if (assets > 0) pool.supply(assetAddr, assets, address(this), 0); // Aave v3 pool will revert if assets == 0
    }

    /// @dev Withdraw assets from Aave v3 pool after ERC4626 regular withdraw workflow
    function _beforeWithdraw(uint256 assets, uint256 /* shares */ ) internal override {
        (, address assetAddr, IPool pool) = _parseImmutableArgs();

        if (assets > 0) pool.withdraw(assetAddr, assets, address(this)); // Aave v3 pool will revert if assets == 0
    }

    function deposit(Token token, uint256 tokens, address receiver)
        external
        payable
        override
        nonReentrant
        returns (uint256)
    {
        // No check for msg.value
        (address aToken, address assetAddr,) = _parseImmutableArgs();

        if (token.unwrap() == assetAddr) return super.deposit(tokens, receiver); // ERC4626 regular deposit
        if (token.unwrap() == aToken) {
            // aToken/asset exchange rate is always 1:1 so here we just use the ERC4626 previewDeposit
            uint256 shares = previewDeposit(tokens);
            SafeTransferLib.safeTransferFrom(aToken, msg.sender, address(this), tokens);
            _mint(receiver, shares);
            return shares;
        }
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    function redeem(Token token, uint256 shares, address receiver) external override nonReentrant returns (uint256) {
        (address aToken, address assetAddr,) = _parseImmutableArgs();

        if (token.unwrap() == assetAddr) return super.redeem(shares, receiver, msg.sender); // ERC4626 regular redeem
        if (token.unwrap() == aToken) {
            // aToken/asset exchange rate is always 1:1 so here we just use the ERC4626 previewRedeem
            uint256 underlyings = previewRedeem(shares);
            _burn(msg.sender, shares);
            SafeTransferLib.safeTransfer(aToken, receiver, underlyings);
            return underlyings;
        }
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       REWARD LOGIC                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct MerklParams {
        IMerkl distributor;
        address[] users;
        address[] tokens;
        uint256[] amounts;
        bytes32[][] proofs;
    }

    /// @notice Claim rewards from Angle Merkl distributor and/or sweep them
    /// @dev Pass zero address for distributor to skip claiming or already claimed.
    /// @dev Revert if sweepTokens contains the underlying aToken
    function sweepRewards(MerklParams calldata params, address[] calldata sweepTokens, address rewardsReceiver)
        external
        restricted
    {
        if (params.distributor != IMerkl(address(0))) {
            params.distributor.claim(params.users, params.tokens, params.amounts, params.proofs);
        }

        (address aToken,,) = _parseImmutableArgs();
        for (uint256 i = 0; i < sweepTokens.length; i++) {
            address token = sweepTokens[i];
            if (token == aToken) revert Errors.ATokenWrapper_CannotSweepUnderlyingToken();
            SafeTransferLib.safeTransferAll(token, rewardsReceiver);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PREVIEW LOGIC                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function previewDeposit(Token token, uint256 tokens) public view override returns (uint256) {
        (address aToken, address assetAddr,) = _parseImmutableArgs();
        if (token.unwrap() == aToken || token.unwrap() == assetAddr) {
            return super.previewDeposit(tokens);
        }
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    function previewRedeem(Token token, uint256 shares) public view override returns (uint256) {
        (address aToken, address assetAddr,) = _parseImmutableArgs();

        if (token.unwrap() == aToken || token.unwrap() == assetAddr) {
            return super.previewRedeem(shares);
        }
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    /// @notice Max deposit is limited by Aave v3 pool supply cap
    /// Returns 0 if reserve is not active, frozen, or paused
    /// Returns max uint256 value if supply cap is 0 (not capped)
    /// Returns supply cap - current amount supplied as max suppliable if there is a supply cap for this reserve
    function maxDeposit(address) public view override returns (uint256) {
        (address aToken,,) = _parseImmutableArgs();
        return AaveV3PoolLens.maxSuppliable(IAToken(aToken));
    }

    function maxMint(address) public view override returns (uint256) {
        uint256 max = maxDeposit(address(0));
        if (max == type(uint256).max) return type(uint256).max;
        return convertToShares(max);
    }

    /// @notice `min(maxWithdrawFromPool, convertToAssets(balanceOf(owner)))`
    function maxWithdraw(address owner) public view override returns (uint256) {
        (address aToken,,) = _parseImmutableArgs();
        uint256 maxWithdrawFromPool = AaveV3PoolLens.maxWithdrawFromPool(IAToken(aToken));
        return FixedPointMathLib.min(maxWithdrawFromPool, super.maxWithdraw(owner));
    }

    /// @notice `min(convertToShares(maxWithdrawFromPool), balanceOf(owner))`
    function maxRedeem(address owner) public view override returns (uint256) {
        (address aToken,,) = _parseImmutableArgs();
        uint256 maxWithdrawFromPool = AaveV3PoolLens.maxWithdrawFromPool(IAToken(aToken));
        return FixedPointMathLib.min(convertToShares(maxWithdrawFromPool), super.maxRedeem(owner));
    }

    /// @dev Get the list of tokens that are listed in the wrapper
    function getTokenInList() external view override returns (Token[] memory tokens) {
        (address aToken, address assetAddr,) = _parseImmutableArgs();

        if (maxDeposit(address(0)) == 0) {
            // Exact 0 means the reserve is not active, paused or frozen
            tokens = new Token[](1);
            tokens[0] = Token.wrap(aToken);
            return tokens;
        }

        tokens = new Token[](2);
        tokens[0] = Token.wrap(assetAddr); // It may already reach the supply cap
        tokens[1] = Token.wrap(aToken);
    }

    function getTokenOutList() external view override returns (Token[] memory tokens) {
        (address aToken, address assetAddr,) = _parseImmutableArgs();

        if (AaveV3PoolLens.isNotActiveOrPaused(IAToken(aToken))) {
            tokens = new Token[](1);
            tokens[0] = Token.wrap(aToken);
            return tokens;
        }

        tokens = new Token[](2);
        tokens[0] = Token.wrap(assetAddr);
        tokens[1] = Token.wrap(aToken);
    }

    function asset() public view override returns (address assetAddr) {
        (, assetAddr,) = _parseImmutableArgs();
    }

    function vault() public view override returns (address aToken) {
        (aToken,,) = _parseImmutableArgs();
    }

    function i_accessManager() public view override returns (AccessManager) {
        return s_accessManager;
    }

    /// @dev Parse metadata from the immutable args
    function _parseImmutableArgs() internal view returns (address, address, IPool) {
        bytes memory args = LibClone.argsOnClone(address(this));
        address aToken = abi.decode(args, (address));
        return (aToken, IAToken(aToken).UNDERLYING_ASSET_ADDRESS(), IAToken(aToken).POOL());
    }
}
