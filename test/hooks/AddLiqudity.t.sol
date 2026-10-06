// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";
import {MockERC4626Fees} from "../mocks/MockERC4626Fees.sol";
import {MockMaliciousERC4626} from "../mocks/MockMaliciousERC4626.sol";
import {MockERC4626TakeLess} from "../mocks/MockERC4626TakeLess.sol";

import {ERC20, ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;
import {BASIS_POINTS} from "src/Constants.sol";
import {Events} from "src/Events.sol";

import {ITokiHook} from "src/interfaces/ITokiHook.sol";
import {LiquidityAmounts} from "src/utils/LiquidityAmounts.sol";

contract AddLiquidityNoVaultsHookTest is LiquidityHookBase {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SUCCESS CASES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_InitialDeposit_WhenRehypothecationDisabled() public {
        uint256 amount0Desired = INITIAL_AMOUNT0;
        uint256 amount1Desired = INITIAL_AMOUNT1;

        // Record initial balances and state
        vm.startPrank(alice);
        uint256 initialBalance0 = poolKey.currency0.balanceOf(alice);
        uint256 initialBalance1 = poolKey.currency1.balanceOf(alice);

        // Verify pool starts empty
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        assertEq(stateBefore.totalLiquidity, 0, "Initial total liquidity should be 0");
        assertEq(stateBefore.reserves.value0(), 0, "Initial reserve0 should be 0");
        assertEq(stateBefore.reserves.value1(), 0, "Initial reserve1 should be 0");
        assertEq(stateBefore.rawBalances.value0(), 0, "Initial raw balance0 should be 0");
        assertEq(stateBefore.rawBalances.value1(), 0, "Initial raw balance1 should be 0");
        assertEq(stateBefore.lnImpliedRate, 0, "Initial implied rate should be 0");
        assertEq(SafeTransferLib.balanceOf(pool, address(0)), 0, "Dead address should start with zero LP tokens");
        (ERC4626 poolVault0, ERC4626 poolVault1) = vaultsOf(poolKey.toId());
        assertEq(address(poolVault0), address(0), "Initial vault0 should be 0");
        assertEq(address(poolVault1), address(0), "Initial vault1 should be 0");

        // Add liquidity
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, alice);

        vm.stopPrank();

        // Verify basic functionality using helpers
        assertGt(liquidity, 0, "Should mint liquidity tokens");
        assertEq(amount0Spent, amount0Desired, "Should spend all amount0");
        assertEq(amount1Spent, amount1Desired, "Should spend all amount1");

        // alice balances change
        _assertBalanceChanges({
            user: alice,
            balanceBefore0: initialBalance0,
            balanceBefore1: initialBalance1,
            expectedChange0: -int256(amount0Spent),
            expectedChange1: -int256(amount1Spent)
        });

        // bob balances change
        _assertLPBalanceChange({user: bob, balanceBefore: 0, expectedChange: int256(liquidity)});

        _assertDeadLiquidity();

        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: 0,
            expectedReserveChange1: 0,
            expectedRawBalanceChange0: int256(amount0Spent),
            expectedRawBalanceChange1: int256(amount1Spent),
            expectedLiquidityChange: int256(liquidity + LiquidityAmounts.MINIMUM_LIQUIDITY)
        });

        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertGt(stateAfter.lnImpliedRate, 0, "Implied rate");

        _assertNoTokensLeftInHook();
    }

    function testFuzz_SubsequentDeposit_WhenRehypothecationDisabled(uint256 amount0Desired, uint256 amount1Desired)
        public
    {
        amount0Desired = bound(amount0Desired, 1001, 10 ** 20);
        amount1Desired = bound(amount1Desired, amount0Desired / 10, amount0Desired * 10);

        deal(Currency.unwrap(poolKey.currency0), alice, INITIAL_AMOUNT0 + amount0Desired);
        deal(Currency.unwrap(poolKey.currency1), alice, INITIAL_AMOUNT1 + amount1Desired);

        // First deposit to initialize the pool
        vm.startPrank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

        // Prepare state before second deposit
        uint256 lpBalanceBefore = SafeTransferLib.balanceOf(pool, bob);
        uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
        uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());

        // Add liquidity
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, alice);
        vm.stopPrank();

        // Sanity check
        assertGt(amount0Spent, 0);
        assertGt(amount1Spent, 0);
        assertGt(liquidity, 0);

        _assertBalanceChanges({
            user: alice,
            balanceBefore0: balanceBefore0,
            balanceBefore1: balanceBefore1,
            expectedChange0: -int256(amount0Spent),
            expectedChange1: -int256(amount1Spent)
        });

        _assertLPBalanceChange({user: bob, balanceBefore: lpBalanceBefore, expectedChange: int256(liquidity)});

        _assertDeadLiquidity();

        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: 0,
            expectedReserveChange1: 0,
            expectedRawBalanceChange0: int256(amount0Spent),
            expectedRawBalanceChange1: int256(amount1Spent),
            expectedLiquidityChange: int256(liquidity)
        });

        _assertImpliedRateUnchanged(stateBefore);

        _assertNoTokensLeftInHook();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    FAILURE CASES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_RevertWhen_Expired() public {
        // Time travel past expiry
        vm.warp(expiry + 1);

        // Expect revert
        vm.expectRevert(Errors.Expired.selector);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);
    }

    error TransferFromFailed(); // Solady

    function test_RevertWhen_InsufficientBalance() public {
        uint256 excessiveAmount = INITIAL_AMOUNT0 * 100;

        // Expect revert due to insufficient balance
        vm.expectRevert(TransferFromFailed.selector);
        tokiHook.addLiquidity(poolKey, excessiveAmount, INITIAL_AMOUNT1, alice, alice);
    }

    function test_RevertWhen_MinimumLiquidityViolation() public {
        // Expect revert for amounts less than minimum liquidity
        vm.expectRevert(Errors.LiquidityAmounts_InsufficientInitialLiquidity.selector);
        tokiHook.addLiquidity(poolKey, 100, 100, alice, alice);
    }

    function test_RevertWhen_InvalidKey() public {
        // Use helper to create invalid key
        PoolKey memory invalidKey = _createInvalidPoolKey();

        vm.startPrank(alice);

        // Expect revert when trying to add liquidity to non-existent pool
        vm.expectRevert(Errors.BadTokiPool.selector);
        tokiHook.addLiquidity(invalidKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

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
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);
    }
}

contract AddLiquidityWithVaultsHookTest is LiquidityHookBase {
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

        (ERC4626 poolVault0, ERC4626 poolVault1) = vaultsOf(poolKey.toId());
        assertEq(address(poolVault0), address(vault0));
        assertEq(address(poolVault1), address(0));
    }

    /// @notice vault0: enabled, vault1: disabled
    function test_InitialDeposit() public {
        uint256 amount0Desired = INITIAL_AMOUNT0;
        uint256 amount1Desired = INITIAL_AMOUNT1;

        // Record initial balances and state
        vm.startPrank(alice);
        uint256 initialBalance0 = poolKey.currency0.balanceOf(alice);
        uint256 initialBalance1 = poolKey.currency1.balanceOf(alice);

        // Verify pool starts empty
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        assertEq(stateBefore.totalLiquidity, 0, "Initial total liquidity should be 0");
        assertEq(stateBefore.reserves.value0(), 0, "Initial reserve0 should be 0");
        assertEq(stateBefore.reserves.value1(), 0, "Initial reserve1 should be 0");
        assertEq(stateBefore.rawBalances.value0(), 0, "Initial raw balance0 should be 0");
        assertEq(stateBefore.rawBalances.value1(), 0, "Initial raw balance1 should be 0");
        assertEq(stateBefore.lnImpliedRate, 0, "Initial implied rate should be 0");
        assertEq(SafeTransferLib.balanceOf(pool, address(0)), 0, "Dead address should start with zero LP tokens");

        // Add liquidity
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, alice);

        vm.stopPrank();

        // Verify basic functionality using helpers
        assertGt(liquidity, 0, "Should mint liquidity tokens");
        // With rehypothecation enabled, vault rounding may cause slightly less to be spent
        assertApproxEqAbs(amount0Spent, amount0Desired, 2, "Should spend approximately all amount0");
        assertEq(amount1Spent, amount1Desired, "Should spend all amount1");

        // alice balances change
        _assertBalanceChanges({
            user: alice,
            balanceBefore0: initialBalance0,
            balanceBefore1: initialBalance1,
            expectedChange0: -int256(amount0Spent),
            expectedChange1: -int256(amount1Spent)
        });

        // bob balances change
        _assertLPBalanceChange({user: bob, balanceBefore: 0, expectedChange: int256(liquidity)});

        _assertDeadLiquidity();

        uint256 vault0Balance = vault0.balanceOf(address(tokiHook));

        // Calculate vault deposit amount (the amount that goes to vault0)
        // If targetRawTokenRatio = 6000 (60%), then 40% goes to vault, 60% stays raw
        uint256 depositAmount0 =
            (amount0Desired * (BASIS_POINTS - rehypothecationConfig0.targetRawTokenRatio)) / BASIS_POINTS;

        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: int256(vault0Balance),
            expectedReserveChange1: 0,
            expectedRawBalanceChange0: int256(amount0Spent - depositAmount0),
            expectedRawBalanceChange1: int256(amount1Spent),
            expectedLiquidityChange: int256(liquidity + LiquidityAmounts.MINIMUM_LIQUIDITY)
        });

        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertGt(stateAfter.lnImpliedRate, 0, "Implied rate");

        _assertNoTokensLeftInHook();
    }

    /// @notice vault0: enabled, vault1: disabled
    function testFuzz_SubsequentDeposit(uint256 amount0Desired, uint256 amount1Desired) public {
        amount0Desired = bound(amount0Desired, 1001, 10 ** 20);
        amount1Desired = bound(amount1Desired, amount0Desired / 10, amount0Desired * 10);

        deal(Currency.unwrap(poolKey.currency0), alice, INITIAL_AMOUNT0 + amount0Desired);
        deal(Currency.unwrap(poolKey.currency1), alice, INITIAL_AMOUNT1 + amount1Desired);

        // First deposit to initialize the pool
        vm.startPrank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

        // Prepare state before second deposit
        uint256 lpBalanceBefore = SafeTransferLib.balanceOf(pool, bob);
        uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
        uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());

        uint256 vault0BalanceBefore = vault0.balanceOf(address(tokiHook));

        // Add liquidity
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, alice);
        vm.stopPrank();

        // Sanity check
        assertGt(amount0Spent, 0);
        assertGt(amount1Spent, 0);
        assertGt(liquidity, 0);

        _assertBalanceChanges({
            user: alice,
            balanceBefore0: balanceBefore0,
            balanceBefore1: balanceBefore1,
            expectedChange0: -int256(amount0Spent),
            expectedChange1: -int256(amount1Spent)
        });

        _assertLPBalanceChange({user: bob, balanceBefore: lpBalanceBefore, expectedChange: int256(liquidity)});

        _assertDeadLiquidity();

        // For subsequent deposits with vaults enabled, we need to check the actual vault activity

        // Calculate vault deposit amounts (amount that goes to vaults)
        uint256 depositAmount0 =
            (amount0Spent * (BASIS_POINTS - rehypothecationConfig0.targetRawTokenRatio)) / BASIS_POINTS;
        uint256 vault0BalanceAfter = vault0.balanceOf(address(tokiHook));

        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: int256(vault0BalanceAfter - vault0BalanceBefore),
            expectedReserveChange1: 0,
            expectedRawBalanceChange0: int256(amount0Spent - depositAmount0),
            expectedRawBalanceChange1: int256(amount1Spent),
            expectedLiquidityChange: int256(liquidity)
        });

        _assertImpliedRateUnchanged(stateBefore);

        _assertNoTokensLeftInHook();
    }

    /// @notice vault0: enabled, vault1: disabled
    function test_When_MaxDepositReached() public {
        deal(Currency.unwrap(poolKey.currency0), alice, type(uint128).max);
        deal(Currency.unwrap(poolKey.currency1), alice, type(uint128).max);

        // Prepare
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice); // Initialize pool

        uint256 maxDeposit = 12345678;
        vm.mockCall(address(vault0), abi.encodeWithSelector(vault0.maxDeposit.selector), abi.encode(maxDeposit));

        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        uint256 totalAssetsBefore = vault0.totalAssets();
        uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
        uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);
        uint256 vault0BalanceBefore = vault0.balanceOf(address(tokiHook));

        uint256 amount0Desired = INITIAL_AMOUNT0; // larger than max deposit
        uint256 amount1Desired = INITIAL_AMOUNT1;

        vm.prank(alice);
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, alice);

        _assertNoTokensLeftInHook();

        // Even if vault hits deposit cap, hook pulls tokens to make up the difference
        assertApproxEqRel(amount0Spent, amount0Desired, 0.0000001e18, "amount0Spent");
        assertApproxEqRel(amount1Spent, amount1Desired, 0.0000001e18, "amount1Spent");

        _assertBalanceChanges({
            user: alice,
            balanceBefore0: balanceBefore0,
            balanceBefore1: balanceBefore1,
            expectedChange0: -int256(amount0Spent),
            expectedChange1: -int256(amount1Spent)
        });

        uint256 vault0BalanceAfter = vault0.balanceOf(address(tokiHook));
        _assertStateChanges({
            stateBefore: stateBefore,
            expectedReserveChange0: int256(vault0BalanceAfter - vault0BalanceBefore),
            expectedReserveChange1: 0,
            expectedRawBalanceChange0: int256(amount0Spent - maxDeposit), // Rest of them lies in raw balances
            expectedRawBalanceChange1: int256(amount1Spent),
            expectedLiquidityChange: int256(liquidity)
        });

        // hook deposits as many tokens as possible to vault
        assertEq(vault0.totalAssets(), totalAssetsBefore + maxDeposit, "max deposit");
    }

    /// @dev The test case should cover the cases where refunding is needed.
    /// @notice vault0: enabled, vault1: enabled
    function testFuzz_When_VaultsEnabled(
        uint256 entryFeeBasisPoints0,
        uint256 exitFeeBasisPoints0,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) public {
        deal(Currency.unwrap(poolKey.currency0), alice, type(uint128).max);
        deal(Currency.unwrap(poolKey.currency1), alice, type(uint128).max);

        // Initialize pool with first deposit (no fees)
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

        // Set up vault with fuzzed fees
        {
            // Bound fees to realistic ranges (0% to 70%)
            entryFeeBasisPoints0 = bound(entryFeeBasisPoints0, 10, 8000);
            exitFeeBasisPoints0 = bound(exitFeeBasisPoints0, 10, 9900);

            vault0.setEntryFeeBasisPoints(entryFeeBasisPoints0);
            vault0.setExitFeeBasisPoints(exitFeeBasisPoints0);
        }

        // Set up vault1
        {
            uint256 entryFeeBasisPoints1 = 20;
            uint256 exitFeeBasisPoints1 = 10;
            vault1 = _deployRehypothecationVaults(address(principalToken));
            vault1.setEntryFeeBasisPoints(entryFeeBasisPoints1);
            vault1.setExitFeeBasisPoints(exitFeeBasisPoints1);
            _setRehypothecationVaults(poolKey, address(0), address(vault1));
        }

        // Record state before second deposit
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        uint256 vault0BalanceBefore = vault0.balanceOf(address(tokiHook));
        uint256 vault1BalanceBefore = vault1.balanceOf(address(tokiHook));

        {
            uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
            uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);
            Uint128x2 balances = tokiHook.getTotalBalances(poolKey.toId());

            amount0Desired = bound(amount0Desired, 10000, 10 ** 20);
            amount1Desired = bound(amount1Desired, amount0Desired / 10, amount0Desired * 10);

            // Perform second deposit with fees
            vm.prank(alice);
            (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
                tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, refundReceiver);

            _assertNoTokensLeftInHook();
            assertLe(amount0Spent, amount0Desired);
            assertLe(amount1Spent, amount1Desired);

            // Proportionality check (accounts for vault fees affecting only currency0)
            assertApproxEqRel(
                amount0Spent * balances.value1(), amount1Spent * balances.value0(), 0.005e18, "proportionality"
            );

            _assertBalanceChanges({
                user: alice,
                balanceBefore0: balanceBefore0,
                balanceBefore1: balanceBefore1,
                expectedChange0: -int256(amount0Spent),
                expectedChange1: -int256(amount1Spent)
            });
        }

        uint256 vault0BalanceAfter = vault0.balanceOf(address(tokiHook));
        uint256 vault1BalanceAfter = vault1.balanceOf(address(tokiHook));
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertEq(
            stateAfter.reserves.value0(),
            stateBefore.reserves.value0() + vault0BalanceAfter - vault0BalanceBefore,
            "reserves0"
        );
        assertEq(
            stateAfter.reserves.value1(),
            stateBefore.reserves.value1() + vault1BalanceAfter - vault1BalanceBefore,
            "reserves1"
        );
    }

    /// @notice vault0: enabled, vault1: enabled
    function test_NoVaultFees() public {
        uint256 entryFeeBasisPoints0 = 0;
        uint256 exitFeeBasisPoints0 = 0;
        uint256 amount0Desired = 4374554985444589;
        uint256 amount1Desired = 5345384309984091;
        testFuzz_When_VaultsEnabled(entryFeeBasisPoints0, exitFeeBasisPoints0, amount0Desired, amount1Desired);
    }

    /// @notice vault0: super high fees
    function test_HighVaultFees() public {
        uint256 entryFeeBasisPoints0 = 320;
        uint256 exitFeeBasisPoints0 = 7000;
        uint256 amount0Desired = 4374554985444589;
        uint256 amount1Desired = 5345384309984091;
        testFuzz_When_VaultsEnabled(entryFeeBasisPoints0, exitFeeBasisPoints0, amount0Desired, amount1Desired);

        uint256 refundAmount0 = target.balanceOf(refundReceiver);
        uint256 refundAmount1 = principalToken.balanceOf(refundReceiver);
        assertEq(refundAmount0, 0, "no refund amount0");
        assertGt(refundAmount1, 0, "non-zero refund amount1");
    }

    function test_EmitVaultWithdraw_When_AddLiquidityRefundRedeemsShares() public {
        deal(Currency.unwrap(poolKey.currency0), alice, type(uint128).max);
        deal(Currency.unwrap(poolKey.currency1), alice, type(uint128).max);

        // Initialize pool with first deposit (no fees)
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

        // Configure both vaults with fees so the second deposit takes the refund-share redemption path.
        vault0.setEntryFeeBasisPoints(320);
        vault0.setExitFeeBasisPoints(7000);

        vault1 = _deployRehypothecationVaults(address(principalToken));
        vault1.setEntryFeeBasisPoints(20);
        vault1.setExitFeeBasisPoints(10);
        _setRehypothecationVaults(poolKey, address(0), address(vault1));

        vm.recordLogs();
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, 4374554985444589, 5345384309984091, bob, refundReceiver);

        // Sanity check: refund happened on currency1 branch.
        assertGt(principalToken.balanceOf(refundReceiver), 0, "expected non-zero currency1 refund");

        bytes32 vaultWithdrawSig = keccak256("VaultWithdraw(bytes32,uint256,address,uint8,uint256,uint256)");
        bytes32 expectedCurrency1Topic = bytes32(uint256(ITokiHook.CurrencyIndex.CURRENCY_1));
        bytes32 expectedVault1Topic = bytes32(uint256(uint160(address(vault1))));

        bool foundVaultWithdrawForVault1;
        uint8 withdrawFlowType;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            if (
                log.topics.length == 4 && log.topics[0] == vaultWithdrawSig && log.topics[2] == expectedCurrency1Topic
                    && log.topics[3] == expectedVault1Topic
            ) {
                foundVaultWithdrawForVault1 = true;
                (withdrawFlowType,,) = abi.decode(log.data, (uint8, uint256, uint256));
                break;
            }
        }
        assertTrue(foundVaultWithdrawForVault1, "missing VaultWithdraw for addLiquidity refund redemption");
        assertEq(withdrawFlowType, Events.VAULT_WITHDRAW_FLOW_REFUND, "unexpected flowType");

        // Reserve shares must stay in sync with actual vault shares after refund redemption.
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertEq(stateAfter.reserves.value0(), vault0.balanceOf(address(tokiHook)), "vault0 reserve/share mismatch");
        assertEq(stateAfter.reserves.value1(), vault1.balanceOf(address(tokiHook)), "vault1 reserve/share mismatch");
    }

    function test_ImbalancedInput0() public {
        uint256 amount0Desired = 4374554;
        uint256 amount1Desired = 5345384309984091;
        _test_ImbalancedInput(amount0Desired, amount1Desired);
    }

    function test_ImbalancedInput1() public {
        uint256 amount0Desired = 92311554;
        uint256 amount1Desired = 323;
        _test_ImbalancedInput(amount0Desired, amount1Desired);
    }

    function _test_ImbalancedInput(uint256 amount0Desired, uint256 amount1Desired) public {
        deal(Currency.unwrap(poolKey.currency0), alice, type(uint128).max);
        deal(Currency.unwrap(poolKey.currency1), alice, type(uint128).max);

        // Initialize pool with first deposit (no fees)
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

        {
            uint256 entryFeeBasisPoints0 = 320;
            uint256 exitFeeBasisPoints0 = 8000;
            vault0.setEntryFeeBasisPoints(entryFeeBasisPoints0);
            vault0.setExitFeeBasisPoints(exitFeeBasisPoints0);
        }
        {
            uint256 entryFeeBasisPoints1 = 320;
            uint256 exitFeeBasisPoints1 = 700;
            vault1 = _deployRehypothecationVaults(address(principalToken));
            vault1.setEntryFeeBasisPoints(entryFeeBasisPoints1);
            vault1.setExitFeeBasisPoints(exitFeeBasisPoints1);
            _setRehypothecationVaults(poolKey, address(0), address(vault1));
        }

        uint256 balanceBefore0 = poolKey.currency0.balanceOf(alice);
        uint256 balanceBefore1 = poolKey.currency1.balanceOf(alice);

        // Perform second deposit with fees
        vm.prank(alice);
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            tokiHook.addLiquidity(poolKey, amount0Desired, amount1Desired, bob, refundReceiver);

        _assertNoTokensLeftInHook();
        assertLe(amount0Spent, amount0Desired);
        assertLe(amount1Spent, amount1Desired);

        _assertBalanceChanges({
            user: alice,
            balanceBefore0: balanceBefore0,
            balanceBefore1: balanceBefore1,
            expectedChange0: -int256(amount0Spent),
            expectedChange1: -int256(amount1Spent)
        });
    }

    /// @dev Condition: There is something wrong with the vault's previewRedeem so that PreviewRedeem(deposit(assets)) > assets
    function test_When_BonusOnDeposit() public {
        // TODO
        vm.skip(true);
    }

    function test_Refund_When_VaultSpendLessThanRequested() public {
        MockERC4626TakeLess faultyVault1 = new MockERC4626TakeLess(principalToken, false);
        _setRehypothecationVaults(poolKey, address(0), address(faultyVault1));

        deal(Currency.unwrap(poolKey.currency0), alice, type(uint128).max);
        deal(Currency.unwrap(poolKey.currency1), alice, type(uint128).max);

        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, refundReceiver);

        assertEq(poolKey.currency0.balanceOf(refundReceiver), 0, "currency0");
        assertNotEq(poolKey.currency1.balanceOf(refundReceiver), 0, "currency1");
    }

    function test_RevertWhen_VaultSpendLessThanRequested() public {
        MockERC4626TakeLess faultyVault1 = new MockERC4626TakeLess(principalToken, false);
        _setRehypothecationVaults(poolKey, address(0), address(faultyVault1));

        deal(Currency.unwrap(poolKey.currency0), alice, INITIAL_AMOUNT0);
        deal(Currency.unwrap(poolKey.currency1), alice, INITIAL_AMOUNT1);

        vm.expectRevert(abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector));
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, refundReceiver);
    }

    function test_RevertWhen_VaultDepositMoreThanRequested() public {
        MockMaliciousERC4626 maliciousVault1 = new MockMaliciousERC4626(principalToken, true);
        _setRehypothecationVaults(poolKey, address(0), address(maliciousVault1));

        deal(Currency.unwrap(poolKey.currency0), alice, type(uint128).max);
        deal(Currency.unwrap(poolKey.currency1), alice, type(uint128).max);

        // Initialize pool with first deposit
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);

        // Activate malicious code
        maliciousVault1.setUpAttack(true, address(0xbad));

        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        vm.prank(alice);
        tokiHook.addLiquidity(poolKey, 100000, 100000, bob, refundReceiver);
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
        tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, alice, alice);
    }
}
