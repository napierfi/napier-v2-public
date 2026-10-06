// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {UniswapV4Base} from "test/UniswapV4Base.t.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";

import {ITokiHook} from "src/interfaces/ITokiHook.sol";
import {LiquidityAmounts} from "src/utils/LiquidityAmounts.sol";

/**
 * @title LiquidityHookBase
 * @notice Base contract for liquidity hook tests containing common setup and helper functions
 */
abstract contract LiquidityHookBase is UniswapV4Base {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       CONSTANTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint256 internal constant MAX_BALANCE = type(uint128).max;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         SETUP                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    address chika = makeAddr("chika");
    uint256 INITIAL_AMOUNT0 = 1000e18;
    uint256 INITIAL_AMOUNT1 = 1000e18;

    constructor() {
        pauseFlags = Constants.PAUSABLE_LP_DEPOSITS | Constants.PAUSABLE_LP_WITHDRAWALS;
    }

    function setUp() public virtual override {
        _setUp({enableRehypothecation0: false});
    }

    function _setUp(bool enableRehypothecation0) internal virtual {
        super.setUp();

        INITIAL_AMOUNT0 = 1000 * tOne;
        INITIAL_AMOUNT1 = 1000 * bOne;

        _deployV4PoolDeployer();
        _setUpModules();
        if (enableRehypothecation0) {
            vault0 = _deployRehypothecationVaults(address(target));
        }
        _deployInstance();
        _label();
        _setupTestBalances();
        _setupApprovals();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   SETUP HELPERS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _setupVault0() internal virtual {
        vm.startPrank(chika);
        deal(address(base), chika, 1_500_000 * bOne);
        base.approve(address(target), type(uint256).max);
        uint256 amount = target.deposit(1_500_000 * bOne, chika);
        target.approve(address(vault0), type(uint256).max);
        vault0.deposit(amount * 2 / 3, chika);

        target.transfer(address(vault0), amount * 1 / 3); // Pump up share price.
        assertGt(
            vault0.convertToAssets(10 ** vault0.decimals()),
            10 ** target.decimals(),
            "Vault0 share priceshould be pumped"
        );
        vm.stopPrank();
    }

    function _setupTestBalances() internal {
        // Setup generous balances for testing
        deal(Currency.unwrap(poolKey.currency0), alice, MAX_BALANCE);
        deal(Currency.unwrap(poolKey.currency1), alice, MAX_BALANCE);
        deal(Currency.unwrap(poolKey.currency0), bob, MAX_BALANCE);
        deal(Currency.unwrap(poolKey.currency1), bob, MAX_BALANCE);
    }

    function _setupApprovals() internal {
        // Approve maximum amounts for both users to avoid repeated approvals in tests
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(tokiHook), type(uint256).max);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency1), address(tokiHook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(tokiHook), type(uint256).max);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency1), address(tokiHook), type(uint256).max);
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   LIQUIDITY HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Adds initial liquidity to the pool for testing
     * @param provider The address that provides the liquidity (pays tokens)
     * @param receiver The address that receives the LP tokens
     * @return liquidity The amount of liquidity tokens minted
     */
    function _addInitialLiquidity(address provider, address receiver) internal returns (uint256 liquidity) {
        _approve(Currency.unwrap(poolKey.currency0), provider, address(tokiHook), INITIAL_AMOUNT0);
        _approve(Currency.unwrap(poolKey.currency1), provider, address(tokiHook), INITIAL_AMOUNT1);
        vm.startPrank(provider);
        (liquidity,,) = tokiHook.addLiquidity(poolKey, INITIAL_AMOUNT0, INITIAL_AMOUNT1, receiver, provider);
        vm.stopPrank();
    }

    /**
     * @notice Creates an invalid pool key for testing error conditions
     * @return invalidKey Pool key with non-existent currencies
     */
    function _createInvalidPoolKey() internal view returns (PoolKey memory invalidKey) {
        invalidKey = PoolKey({
            currency0: Currency.wrap(address(0x1234)),
            currency1: Currency.wrap(address(0x5678)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 1,
            hooks: tokiHook
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ASSERTION HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Asserts that token balances changed by expected amounts
     * @param user The user whose balances to check
     * @param balanceBefore0 Previous balance of currency0
     * @param balanceBefore1 Previous balance of currency1
     * @param expectedChange0 Expected change in currency0 balance (positive = increase)
     * @param expectedChange1 Expected change in currency1 balance (positive = increase)
     */
    function _assertBalanceChanges(
        address user,
        uint256 balanceBefore0,
        uint256 balanceBefore1,
        int256 expectedChange0,
        int256 expectedChange1
    ) internal view {
        uint256 balanceAfter0 = poolKey.currency0.balanceOf(user);
        uint256 balanceAfter1 = poolKey.currency1.balanceOf(user);

        if (expectedChange0 >= 0) {
            assertEq(balanceAfter0, balanceBefore0 + uint256(expectedChange0), "Currency0 balance should increase");
        } else {
            assertEq(balanceAfter0, balanceBefore0 - uint256(-expectedChange0), "Currency0 balance should decrease");
        }

        if (expectedChange1 >= 0) {
            assertEq(balanceAfter1, balanceBefore1 + uint256(expectedChange1), "Currency1 balance should increase");
        } else {
            assertEq(balanceAfter1, balanceBefore1 - uint256(-expectedChange1), "Currency1 balance should decrease");
        }
    }

    /**
     * @notice Asserts that LP token balance changed by expected amount
     * @param user The user whose LP balance to check
     * @param balanceBefore Previous LP token balance
     * @param expectedChange Expected change in LP balance (positive = increase)
     */
    function _assertLPBalanceChange(address user, uint256 balanceBefore, int256 expectedChange) internal view {
        uint256 balanceAfter = SafeTransferLib.balanceOf(pool, user);

        if (expectedChange >= 0) {
            assertEq(balanceAfter, balanceBefore + uint256(expectedChange), "LP token balance should increase");
        } else {
            assertEq(balanceAfter, balanceBefore - uint256(-expectedChange), "LP token balance should decrease");
        }
    }

    /**
     * @notice Asserts that pool state variables changed as expected
     * @param stateBefore Pool state before the operation
     * @param expectedReserveChange0 Expected change in reserve0
     * @param expectedReserveChange1 Expected change in reserve1
     * @param expectedLiquidityChange Expected change in total liquidity
     */
    function _assertStateChanges(
        ITokiHook.PoolStorage memory stateBefore,
        int256 expectedReserveChange0,
        int256 expectedReserveChange1,
        int256 expectedRawBalanceChange0,
        int256 expectedRawBalanceChange1,
        int256 expectedLiquidityChange
    ) internal view {
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());

        if (expectedReserveChange0 >= 0) {
            assertEq(
                stateAfter.reserves.value0(),
                stateBefore.reserves.value0() + uint256(expectedReserveChange0),
                "Reserve0 should increase"
            );
        } else {
            assertEq(
                stateAfter.reserves.value0(),
                stateBefore.reserves.value0() - uint256(-expectedReserveChange0),
                "Reserve0 should decrease"
            );
        }

        if (expectedReserveChange1 >= 0) {
            assertEq(
                stateAfter.reserves.value1(),
                stateBefore.reserves.value1() + uint256(expectedReserveChange1),
                "Reserve1 should increase"
            );
        } else {
            assertEq(
                stateAfter.reserves.value1(),
                stateBefore.reserves.value1() - uint256(-expectedReserveChange1),
                "Reserve1 should decrease"
            );
        }

        if (expectedRawBalanceChange0 >= 0) {
            assertApproxEqRel(
                stateAfter.rawBalances.value0(),
                stateBefore.rawBalances.value0() + uint256(expectedRawBalanceChange0),
                0.00000001e18,
                "Raw balance0 should increase"
            );
        } else {
            assertApproxEqRel(
                stateAfter.rawBalances.value0(),
                stateBefore.rawBalances.value0() - uint256(-expectedRawBalanceChange0),
                0.00000001e18,
                "Raw balance0 should decrease"
            );
        }

        if (expectedRawBalanceChange1 >= 0) {
            assertApproxEqRel(
                stateAfter.rawBalances.value1(),
                stateBefore.rawBalances.value1() + uint256(expectedRawBalanceChange1),
                0.00000001e18,
                "Raw balance1 should increase"
            );
        } else {
            assertApproxEqRel(
                stateAfter.rawBalances.value1(),
                stateBefore.rawBalances.value1() - uint256(-expectedRawBalanceChange1),
                0.00000001e18,
                "Raw balance1 should decrease"
            );
        }

        if (expectedLiquidityChange >= 0) {
            assertEq(
                stateAfter.totalLiquidity,
                stateBefore.totalLiquidity + uint256(expectedLiquidityChange),
                "Total liquidity should increase"
            );
        } else {
            assertEq(
                stateAfter.totalLiquidity,
                stateBefore.totalLiquidity - uint256(-expectedLiquidityChange),
                "Total liquidity should decrease"
            );
        }
    }

    function _assertDeadLiquidity() internal view {
        uint256 deadLiquidityBalance = SafeTransferLib.balanceOf(pool, address(0));
        assertEq(
            deadLiquidityBalance, LiquidityAmounts.MINIMUM_LIQUIDITY, "Dead liquidity should equal expected amount"
        );
    }

    function _assertImpliedRateUnchanged(ITokiHook.PoolStorage memory stateBefore) internal view {
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertEq(stateAfter.lnImpliedRate, stateBefore.lnImpliedRate, "Implied rate should remain unchanged");
    }

    function _assertNoTokensLeftInHook() internal view {
        ITokiHook.PoolStorage memory state = stateOf(poolKey.toId());
        if (address(vault0) != address(0)) {
            assertEq(state.reserves.value0(), vault0.balanceOf(address(tokiHook)), "non-zero vault0");
        }
        if (address(vault1) != address(0)) {
            assertEq(state.reserves.value1(), vault1.balanceOf(address(tokiHook)), "non-zero vault1");
        }

        assertEq(target.balanceOf(address(tokiHook)), 0, "non-zero target");
        assertEq(principalToken.balanceOf(address(tokiHook)), 0, "non-zero principal token");
    }
}
