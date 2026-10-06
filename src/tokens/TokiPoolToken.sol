// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Interfaces
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/types/PoolKey.sol";

// Libraries
import {LibClone} from "solady/src/utils/LibClone.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Constants.sol" as Constants;
import {EIP5095} from "../interfaces/EIP5095.sol";
import {IHooklet, HookletLib} from "../utils/HookletLib.sol";
import {TokenNameLib} from "../utils/TokenNameLib.sol";
import {CustomRevert} from "../utils/CustomRevert.sol";
import {LibPauseGuard, Pausable} from "../utils/LibPauseGuard.sol";

// Inherits
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ReentrancyGuardTransient} from "solady/src/utils/ReentrancyGuardTransient.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

/// @notice This token represents the liquidity of a TokiPool
/// @dev This contract is meant to be deployed by clone with the immutable args
/// @dev The immutable args are encoded as follows:
/// ```
/// abi.encode(
///     address hook;
///     address underlying;
///     address principalToken;
///     Flags16 pausableFlags;
///     address hooklet;
///     bytes liquidityTokenImmutableData;
/// )
/// ```
contract TokiPoolToken is ERC20, ReentrancyGuardTransient, Initializable {
    using CustomRevert for *;

    /// @dev Immutable Uniswap V4 PoolManager across all TokiPoolToken instances
    IPoolManager immutable i_poolManager;

    constructor(IPoolManager poolManager) {
        i_poolManager = poolManager;
        _disableInitializers();
    }

    /// @dev For future implementation
    function initialize() external initializer {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          ERC20                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function mint(address to, uint256 amount) external nonReentrant onlyHook {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external nonReentrant onlyHook {
        _burn(from, amount);
    }

    /// @notice Revert if LP transfers are pausable and principal token is paused
    /// @dev Only allow transfers if the PoolManager is locked. It prevents pool state from being modified during liquidity operations.
    function transfer(address to, uint256 amount) public override nonReentrant onlyIfPoolManagerLocked returns (bool) {
        return super.transfer(to, amount);
    }

    /// @notice Revert if LP transfers are pausable and principal token is paused
    /// @dev Only allow transfers if the PoolManager is locked. It prevents pool state from being modified during liquidity operations.
    function transferFrom(address from, address to, uint256 amount)
        public
        override
        nonReentrant
        onlyIfPoolManagerLocked
        returns (bool)
    {
        return super.transferFrom(from, to, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        bytes memory args = LibClone.argsOnClone(address(this));

        (,, Pausable principalToken, Flags16 pausableFlags, IHooklet hooklet) =
            abi.decode(args, (address, address, Pausable, Flags16, IHooklet)); // Ignore the last bytes field

        // Pause check for transfers between addresses
        // Mint and burn are not paused
        if (from != address(0) && to != address(0)) {
            LibPauseGuard.checkNotPaused(principalToken, pausableFlags, Constants.PAUSABLE_LP_TRANSFERS);
        }

        // Hooklet call
        HookletLib.hookletBeforeTransfer(hooklet, msg.sender, i_poolKey(), from, to, amount);
    }

    function _afterTokenTransfer(address from, address to, uint256 amount) internal override {
        bytes memory args = LibClone.argsOnClone(address(this));

        (,,,, IHooklet hooklet) = abi.decode(args, (address, address, address, Flags16, IHooklet));

        // Hooklet call
        HookletLib.hookletAfterTransfer(hooklet, msg.sender, i_poolKey(), from, to, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            View                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function name() public view override returns (string memory) {
        PoolKey memory key = i_poolKey();
        address principalToken = Currency.unwrap(key.currency1);
        return TokenNameLib.lpTokenName(Currency.unwrap(key.currency0), EIP5095(principalToken).maturity());
    }

    function symbol() public view override returns (string memory) {
        PoolKey memory key = i_poolKey();
        address principalToken = Currency.unwrap(key.currency1);
        return TokenNameLib.lpTokenSymbol(Currency.unwrap(key.currency0), EIP5095(principalToken).maturity());
    }

    function i_poolKey() public view returns (PoolKey memory) {
        (IHooks hook, Currency underlying, Currency principalToken) =
            abi.decode(LibClone.argsOnClone(address(this), 0x00, 0x60), (IHooks, Currency, Currency));
        return PoolKey({currency0: underlying, currency1: principalToken, hooks: hook, fee: 0, tickSpacing: 1});
    }

    function i_hook() public view returns (address) {
        bytes memory args = LibClone.argsOnClone(address(this), 0x00, 0x20);
        return abi.decode(args, (address));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           Utils                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier onlyHook() {
        if (msg.sender != i_hook()) Errors.LiquidityToken_OnlyHook.selector.revertWith();
        _;
    }

    /// @notice Enforces that the PoolManager is locked.
    modifier onlyIfPoolManagerLocked() {
        if (TransientStateLibrary.isUnlocked(i_poolManager)) {
            Errors.LiquidityToken_PoolManagerMustBeLocked.selector.revertWith();
        }
        _;
    }

    /// @dev Use TSTORE/TLOAD everywhere.
    function _useTransientReentrancyGuardOnlyOnMainnet() internal pure override returns (bool) {
        return false;
    }
}
