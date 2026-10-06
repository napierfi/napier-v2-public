// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {IBooster} from "./interfaces/IBooster.sol";
import {IBaseRewardPool} from "./interfaces/IBaseRewardPool.sol";
import {ITokenWrapper} from "./interfaces/ITokenWrapper.sol";
import {WrapperFactory} from "../WrapperFactory.sol";

import "src/Types.sol";
import "src/Errors.sol";

import {AccessManaged, AccessManager} from "src/modules/AccessManager.sol";
import {StandardERC4626Wrapper} from "../StandardERC4626Wrapper.sol";

/// @dev A wrapper for Convex LP tokens meant to be deployed via clone with immutable args:
/// abi.encode(uint256 poolId, address booster)
/// - uint256 poolId: the Convex pool ID for the LP token
/// - address booster: the address of the Convex Booster contract
/// @dev Glossary in the context of wrapper:
/// - `token`: the token we want to be paid out or paid in.
/// - `tokens`: the amount of `token`
/// - `underlyings`: the amount of Curve LP token
/// - `shares`: the amount of the wrapper vault. e.g. np-cvxLP
/// @dev Important note:
/// - Convex distributes rewards through BaseRewardPool contract
/// - The wrapper will forward all rewards (base + extra) to the PrincipalToken
contract ConvexWrapper is StandardERC4626Wrapper, ReentrancyGuard, Initializable, AccessManaged {
    /// @notice The access manager for this wrapper
    AccessManager internal s_accessManager;

    /// @notice The PrincipalToken address that this wrapper is associated with
    address public s_principalToken;

    /// @notice The total assets == the staked amount in Convex's BaseRewardPool
    function totalAssets() public view override returns (uint256) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (,,, address rewardPool,,) = booster.poolInfo(poolId);
        return IBaseRewardPool(rewardPool).balanceOf(address(this));
    }

    /// @inheritdoc StandardERC4626Wrapper
    function initialize() external override initializer {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);

        s_accessManager = WrapperFactory(msg.sender).i_accessManager();
        // Approve Curve LP token to Convex Booster
        SafeTransferLib.safeApprove(lpToken, address(booster), type(uint256).max);
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

    /// @dev Deposit assets to Convex after ERC4626 regular deposit workflow
    function _afterDeposit(uint256 assets, uint256 /* shares */ ) internal override {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        if (assets > 0) booster.deposit(poolId, assets, true); // Deposit and stake in one transaction
    }

    /// @dev Withdraw assets from Convex before ERC4626 regular withdraw workflow
    function _beforeWithdraw(uint256 assets, uint256 /* shares */ ) internal override {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (,,, address rewardPool,,) = booster.poolInfo(poolId);

        if (assets > 0) {
            // Withdraw from reward pool and unwrap from Convex
            IBaseRewardPool(rewardPool).withdrawAndUnwrap(assets, false); // Don't claim rewards
        }
    }

    function deposit(Token token, uint256 tokens, address receiver)
        external
        payable
        override
        nonReentrant
        returns (uint256)
    {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);

        if (token.unwrap() == lpToken) return super.deposit(tokens, receiver);
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    function redeem(Token token, uint256 shares, address receiver) external override nonReentrant returns (uint256) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);

        if (token.unwrap() == lpToken) return super.redeem(shares, receiver, msg.sender);
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       REWARD LOGIC                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Set the PrincipalToken address. Can only be called once by the factory.
    /// @dev This is called after PrincipalToken creation
    function setPrincipalToken(address principalToken) external restricted {
        if (s_principalToken != address(0)) revert Errors.Wrapper_PrincipalTokenAlreadySet();
        if (principalToken == address(this)) revert Errors.Wrapper_InvalidPrincipalToken();
        s_principalToken = principalToken;
    }

    /// @notice Claim rewards from Convex BaseRewardPool and send all rewards to PrincipalToken
    /// @dev All reward tokens (base + extra rewards) will be sent to PrincipalToken
    function claimRewards() public override nonReentrant returns (TokenReward[] memory) {
        address principalToken = s_principalToken;
        if (principalToken != msg.sender || principalToken == address(0)) {
            return new TokenReward[](0);
        }

        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (,,, address rewardPool,,) = booster.poolInfo(poolId);
        IBaseRewardPool baseRewardPool = IBaseRewardPool(rewardPool);

        // Get all reward tokens (base + extra)
        address[] memory rewardTokens = _getRewardTokens(poolId, baseRewardPool);

        // Claim rewards from BaseRewardPool
        baseRewardPool.getReward(address(this), true);
        TokenReward[] memory rewards = new TokenReward[](rewardTokens.length);
        // Send all reward tokens to PrincipalToken
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            uint256 balance = SafeTransferLib.balanceOf(rewardTokens[i], address(this));
            rewards[i] = TokenReward({token: rewardTokens[i], amount: balance});
            SafeTransferLib.safeTransfer(rewardTokens[i], principalToken, balance);
        }
        return rewards;
    }

    /// @dev Get all reward tokens (base + extra) from BaseRewardPool
    function _getRewardTokens(uint256 poolId, IBaseRewardPool baseRewardPool)
        internal
        view
        returns (address[] memory)
    {
        uint256 extraRewardsLength = baseRewardPool.extraRewardsLength();
        address[] memory rewardTokens = new address[](extraRewardsLength + 1);

        // Add base reward token (usually CRV)
        rewardTokens[0] = baseRewardPool.rewardToken();

        // Add extra reward tokens
        for (uint256 i = 0; i < extraRewardsLength; i++) {
            address extraReward = baseRewardPool.extraRewards(i);
            address rewardToken = IBaseRewardPool(extraReward).rewardToken();

            // For newer pools (poolId >= 151), reward tokens might be wrapped
            // We need to get the underlying token from the wrapper
            if (poolId >= 151) {
                try ITokenWrapper(rewardToken).token() returns (address realToken) {
                    rewardToken = realToken;
                } catch {
                    // If the call fails, it means the token is not wrapped
                    // Keep the original reward token
                }
            }
            rewardTokens[i + 1] = rewardToken;
        }

        return rewardTokens;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PREVIEW LOGIC                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function previewDeposit(Token token, uint256 tokens) public view override returns (uint256) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);
        if (token.unwrap() == lpToken) {
            return super.previewDeposit(tokens);
        }
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    function previewRedeem(Token token, uint256 shares) public view override returns (uint256) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);
        if (token.unwrap() == lpToken) {
            return super.previewRedeem(shares);
        }
        revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    /// @dev Get the list of tokens that are listed in the wrapper
    function getTokenInList() external view override returns (Token[] memory tokens) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);
        tokens = new Token[](1);
        tokens[0] = Token.wrap(lpToken);
    }

    function getTokenOutList() external view override returns (Token[] memory tokens) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);
        tokens = new Token[](1);
        tokens[0] = Token.wrap(lpToken);
    }

    function asset() public view override returns (address) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (address lpToken,,,,,) = booster.poolInfo(poolId);
        return lpToken;
    }

    function vault() public view override returns (address) {
        (uint256 poolId, IBooster booster) = _parseImmutableArgs();
        (, address cvxLpToken,,,,) = booster.poolInfo(poolId);
        return cvxLpToken;
    }

    function i_accessManager() public view override returns (AccessManager) {
        return s_accessManager;
    }

    /// @dev Convex Name and symbol are way too long. TwoCrypto allows max 64 chars for the pool name.
    function name() public view override returns (string memory) {
        // Pool name:
        // prefix - 12 chars: "NapierV2-PT/"
        // suffix - Max 11 chars: "@19/12/2026"
        // remaining - 41 chars: underlying name
        return ERC20(vault()).name();
    }

    /// @dev Override this function in the derived contract if the underlying vault is not ERC20 standard.
    function symbol() public view override returns (string memory) {
        // TwoCrypto allows max 32 chars for the pool symbol.
        // prefix - 7 chars: "NPR-PT/"
        // suffix - Max 11 chars: "@19/12/2026"
        // remaining - 14 chars: underlying symbol
        return ERC20(vault()).symbol();
    }

    /// @dev Parse metadata from the immutable args
    function _parseImmutableArgs() internal view returns (uint256 poolId, IBooster booster) {
        bytes memory args = LibClone.argsOnClone(address(this));
        return abi.decode(args, (uint256, IBooster));
    }
}
