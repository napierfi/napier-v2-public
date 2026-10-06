// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {TokiPoolToken} from "src/tokens/TokiPoolToken.sol";
import {ITokiHook, ImmutableParamsLib} from "src/interfaces/ITokiHook.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract TransferLPTest is LiquidityHookBase, IUnlockCallback {
    constructor() {
        pauseFlags =
            Constants.PAUSABLE_LP_TRANSFERS | Constants.PAUSABLE_LP_DEPOSITS | Constants.PAUSABLE_LP_WITHDRAWALS;
    }

    function setUp() public override {
        super.setUp();
        _addInitialLiquidity(alice, alice);
    }

    function test_PoolKey() public {
        assertEq(keccak256(abi.encode(TokiPoolToken(pool).i_poolKey())), keccak256(abi.encode(poolKey)));
    }

    function test_Transfer() public {
        uint256 balance = ERC20(pool).balanceOf(alice);
        uint256 liquidity = 2190090;

        vm.prank(alice);
        ERC20(pool).transfer(bob, liquidity);

        assertEq(ERC20(pool).balanceOf(alice), balance - liquidity);
        assertEq(ERC20(pool).balanceOf(bob), liquidity);
    }

    function test_Mint_RevertWhen_NotHook() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LiquidityToken_OnlyHook.selector));
        TokiPoolToken(pool).mint(alice, 10);
    }

    function test_Burn_RevertWhen_NotHook() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LiquidityToken_OnlyHook.selector));
        TokiPoolToken(pool).burn(alice, 190);
    }

    function test_Transfer_RevertWhen_PoolManagerLocked() public {
        poolManager.unlock(abi.encode(TokiPoolToken.transfer.selector));
    }

    function test_TransferFrom_RevertWhen_PoolManagerLocked() public {
        poolManager.unlock(abi.encode(TokiPoolToken.transferFrom.selector));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bytes4 selector) = abi.decode(data, (bytes4));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LiquidityToken_PoolManagerMustBeLocked.selector));
        if (selector == TokiPoolToken.transfer.selector) {
            TokiPoolToken(pool).transfer(bob, 10);
        } else if (selector == TokiPoolToken.transferFrom.selector) {
            TokiPoolToken(pool).transferFrom(alice, bob, 100);
        }
        return "";
    }

    function test_Transfer_RevertWhen_Paused() public {
        // Pause the principal token
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        vm.prank(dev);
        principalToken.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LibPauseGuard_Paused.selector));
        TokiPoolToken(pool).transfer(bob, 0);
    }

    function test_TransferFrom_RevertWhen_Paused() public {
        // Pause the principal token
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        vm.prank(dev);
        principalToken.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Errors.LibPauseGuard_Paused.selector));
        TokiPoolToken(pool).transferFrom(alice, bob, 0);
    }
}
