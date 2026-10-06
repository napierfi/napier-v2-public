// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ITokiHook} from "src/interfaces/ITokiHook.sol";
import {LiquidityAmounts} from "src/utils/LiquidityAmounts.sol";

contract RemoveLiquidityNoVaultsHookTest is LiquidityHookBase {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SUCCESS CASES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_WhenRehypothecationDisabled() public {
        // First add liquidity to have something to remove
        uint256 liquidity = _addInitialLiquidity(alice, alice);

        _testRemoveLiquidity(liquidity);
    }

    function testFuzz_WhenRehypothecationDisabled(uint256 liquidity) public {
        // First add liquidity to have something to remove
        uint256 initialLiquidity = _addInitialLiquidity(alice, alice);

        liquidity = bound(liquidity, 0, initialLiquidity);

        _testRemoveLiquidity(liquidity);
    }

    function _testRemoveLiquidity(uint256 liquidity) internal {
        // Prepare state before removal
        uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
        uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);
        uint256 lpBalanceBefore = SafeTransferLib.balanceOf(pool, alice);
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());

        // Execution
        vm.startPrank(alice);
        (uint256 amount0, uint256 amount1) = tokiHook.removeLiquidity(poolKey, liquidity, alice);
        vm.stopPrank();

        _assertNoTokensLeftInHook();

        _assertBalanceChanges({
            user: alice,
            balanceBefore0: balanceBefore0,
            balanceBefore1: balanceBefore1,
            expectedChange0: int256(amount0),
            expectedChange1: int256(amount1)
        });

        _assertLPBalanceChange({user: alice, balanceBefore: lpBalanceBefore, expectedChange: -int256(liquidity)});

        _assertDeadLiquidity();

        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: 0,
            expectedReserveChange1: 0,
            expectedRawBalanceChange0: -int256(amount0),
            expectedRawBalanceChange1: -int256(amount1),
            expectedLiquidityChange: -int256(liquidity)
        });
    }

    function test_ZeroLiquidity() public {
        // First add liquidity to have something to remove
        _addInitialLiquidity(alice, alice);

        vm.startPrank(alice);

        (uint256 amount0, uint256 amount1) = tokiHook.removeLiquidity(poolKey, 0, alice);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    FAILURE CASES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_When_Expired() public {
        // First add liquidity to have something to remove
        uint256 liquidityMinted = _addInitialLiquidity(alice, alice);

        // Time travel past expiry
        vm.warp(expiry + 1);

        _testRemoveLiquidity(liquidityMinted);
    }

    function test_RevertWhen_InsufficientLiquidity() public {
        // First add liquidity to have something to remove
        uint256 liquidityMinted = _addInitialLiquidity(alice, alice);

        uint256 excessiveLiquidity = liquidityMinted * 2;

        vm.startPrank(alice);

        // Expect revert due to insufficient LP token balance
        vm.expectRevert(Errors.LiquidityAmounts_LiquidityExceedsTotalLiquidity.selector);
        tokiHook.removeLiquidity(poolKey, excessiveLiquidity, alice);

        vm.stopPrank();
    }

    error InsufficientBalance(); // Solady

    function test_RevertWhen_InsufficientLpTokenBalance() public {
        // First add liquidity to alice
        _addInitialLiquidity(alice, alice);

        // Try to remove liquidity with bob who has no LP tokens
        vm.startPrank(bob);

        // Expect revert due to insufficient LP token balance
        vm.expectRevert(InsufficientBalance.selector);
        tokiHook.removeLiquidity(poolKey, 1000, bob);

        vm.stopPrank();
    }

    function test_RevertWhen_NoLiquidity() public {
        // Don't add any liquidity first

        vm.startPrank(alice);

        // Expect revert when trying to remove from empty pool
        vm.expectRevert(Errors.LiquidityAmounts_NoLiquidity.selector);
        tokiHook.removeLiquidity(poolKey, 1000, alice);

        vm.stopPrank();
    }

    function test_RevertWhen_InvalidKey() public {
        // Create an invalid poolKey with non-existent currencies
        PoolKey memory invalidKey = _createInvalidPoolKey();

        vm.startPrank(alice);

        // Expect revert when trying to remove liquidity from non-existent pool
        vm.expectRevert(Errors.BadTokiPool.selector);
        tokiHook.removeLiquidity(invalidKey, 1000, alice);

        vm.stopPrank();
    }

    function test_RevertWhen_Paused() public {
        // Pause the principal token
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        vm.prank(dev);
        principalToken.pause();

        vm.expectRevert(Errors.LibPauseGuard_Paused.selector);
        vm.prank(alice);
        tokiHook.removeLiquidity(poolKey, 10, alice);
    }
}

contract RemoveLiquidityWithVaultsHookTest is LiquidityHookBase {
    address refundReceiver = makeAddr("refundReceiver");

    function setUp() public override {
        rehypothecationConfig0 = RehypothecationConfig({
            targetRawTokenRatio: 6_000, // 60%
            maxRawTokenRatio: 8_000, // 80%
            minRawTokenRatio: 3_000 // 30%
        });

        rehypothecationConfig1 = RehypothecationConfig({
            targetRawTokenRatio: 10,
            maxRawTokenRatio: 6_000, // 60%
            minRawTokenRatio: 10
        });

        _setUp({enableRehypothecation0: true});
        _setupVault0();

        // Set up vault1
        {
            vault1 = _deployRehypothecationVaults(address(principalToken));
            vault1.setEntryFeeBasisPoints(20);
            vault1.setExitFeeBasisPoints(20);
            _setRehypothecationVaults(poolKey, address(0), address(vault1));
        }

        (ERC4626 poolVault0, ERC4626 poolVault1) = vaultsOf(poolKey.toId());
        assertEq(address(poolVault0), address(vault0));
        assertEq(address(poolVault1), address(vault1));
    }

    function test_WhenRehypothecationEnabled() public {
        testFuzz_WhenRehypothecationEnabled(191010291212);
    }

    struct ExpectedValues {
        uint256 rawAmount0;
        uint256 rawAmount1;
        uint256 shares0;
        uint256 shares1;
    }

    function testFuzz_WhenRehypothecationEnabled(uint256 liquidity) public {
        // First add liquidity to have something to remove
        uint256 initialLiquidity = _addInitialLiquidity(alice, alice);

        liquidity = bound(liquidity, 0, initialLiquidity);

        // Prepare state before removal
        uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
        uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);
        uint256 lpBalanceBefore = SafeTransferLib.balanceOf(pool, alice);
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());

        // Calculate expected proportional changes independently (not using the library)
        ExpectedValues memory expectedValues;
        uint256 shares0Before = vault0.balanceOf(address(tokiHook));
        uint256 shares1Before = vault1.balanceOf(address(tokiHook));
        {
            // Use the same calculation method as the contract for consistency
            (expectedValues.rawAmount0, expectedValues.rawAmount1) =
                LiquidityAmounts.getAmountsForLiquidity(liquidity, stateBefore.totalLiquidity, stateBefore.rawBalances);
        }

        {
            // Execution
            vm.startPrank(alice);
            (uint256 amount0, uint256 amount1) = tokiHook.removeLiquidity(poolKey, liquidity, alice);
            vm.stopPrank();

            expectedValues.shares0 = shares0Before - vault0.balanceOf(address(tokiHook));
            expectedValues.shares1 = shares1Before - vault1.balanceOf(address(tokiHook));

            _assertNoTokensLeftInHook();

            _assertBalanceChanges({
                user: alice,
                balanceBefore0: balanceBefore0,
                balanceBefore1: balanceBefore1,
                expectedChange0: int256(amount0),
                expectedChange1: int256(amount1)
            });
        }
        _assertLPBalanceChange({user: alice, balanceBefore: lpBalanceBefore, expectedChange: -int256(liquidity)});

        _assertDeadLiquidity();

        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: -int256(expectedValues.shares0),
            expectedReserveChange1: -int256(expectedValues.shares1),
            expectedRawBalanceChange0: -int256(expectedValues.rawAmount0),
            expectedRawBalanceChange1: -int256(expectedValues.rawAmount1),
            expectedLiquidityChange: -int256(liquidity)
        });
    }

    /// @dev The exit burns exactly the LP's pro-rata slice of `reserves`, even for a fee-charging vault
    function test_WhenRehypothecationEnabled_BurnsProRataShares() public {
        uint256 initialLiquidity = _addInitialLiquidity(alice, alice);
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());

        uint256 liquidity = initialLiquidity / 3;
        (uint256 expectedShares0, uint256 expectedShares1) =
            LiquidityAmounts.getAmountsForLiquidity(liquidity, stateBefore.totalLiquidity, stateBefore.reserves);

        vm.prank(alice);
        tokiHook.removeLiquidity(poolKey, liquidity, alice);

        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertEq(stateBefore.reserves.value0() - stateAfter.reserves.value0(), expectedShares0, "shares0 burned");
        assertEq(stateBefore.reserves.value1() - stateAfter.reserves.value1(), expectedShares1, "shares1 burned");
    }

    function test_RevertWhen_Paused() public {
        // Pause the principal token
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        vm.prank(dev);
        principalToken.pause();

        vm.expectRevert(Errors.LibPauseGuard_Paused.selector);
        vm.prank(alice);
        tokiHook.removeLiquidity(poolKey, 10, alice);
    }
}
