// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {UniswapV4Base} from "../UniswapV4Base.t.sol";
import {MockMaliciousERC4626} from "../mocks/MockMaliciousERC4626.sol";

import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {TokiHook, ImmutableParamsLib} from "src/hooks/TokiHook.sol";
import {ITokiHook, ImmutableParamsLib} from "src/interfaces/ITokiHook.sol";
import {TokiSwap} from "src/utils/TokiSwap.sol";

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Events.sol";
import "src/Constants.sol" as Constants;

abstract contract SwapPTHookBase is UniswapV4Base {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for *;
    using SafeCastLib for *;

    // Test parameters
    uint256 internal INITIAL_AMOUNT0;
    uint256 internal INITIAL_AMOUNT1;

    address chika = makeAddr("chika");

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            SETUP                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _setUp(bool enableRehypothecation0) internal {
        pauseFlags = Constants.PAUSABLE_LP_SWAPS;

        super.setUp();

        INITIAL_AMOUNT0 = 1120 * 10 ** target.decimals();
        INITIAL_AMOUNT1 = 1409 * 10 ** base.decimals();

        _deployV4PoolDeployer();
        _setUpModules();
        if (enableRehypothecation0) {
            vault0 = _deployRehypothecationVaults(address(target));
        }
        _deployInstance();
        if (enableRehypothecation0) {
            _setupVault0();
        }

        _label();
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
        vault0.deposit(amount * 2 / 4, chika);

        target.transfer(address(vault0), amount * 1 / 4); // Pump up share price.
        assertGt(
            vault0.convertToAssets(10 ** vault0.decimals()),
            10 ** target.decimals(),
            "Vault0 share priceshould be pumped"
        );
        vm.stopPrank();
    }

    function _depositLiquidity(uint256 amount0, uint256 amount1) internal {
        vm.startPrank(curator);
        deal(Currency.unwrap(poolKey.currency0), curator, amount0);
        deal(Currency.unwrap(poolKey.currency1), curator, amount1);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(tokiHook), amount0);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency1), address(tokiHook), amount1);

        tokiHook.addLiquidity(poolKey, amount0, amount1, curator, curator);
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TEST HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Extract amount0 from HookSwap event logs
    /// @param logs Recorded logs to scan
    /// @param poolId The pool ID to match against
    /// @return amount0 The amount0 value from the HookSwap event
    function _getHookSwapAmount0FromLogs(Vm.Log[] memory logs, PoolId poolId) internal view returns (int128 amount0) {
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter != address(tokiHook)) continue;
            if (log.topics[0] != bytes32(Events._HOOK_SWAP_EVENT_SIGNATURE)) continue;
            require(log.topics[1] == poolIdBytes, "PoolId mismatch");
            (amount0,,,) = abi.decode(log.data, (int128, int128, uint128, uint128));
            return amount0;
        }
        revert("HookSwap event not found");
    }

    /// @notice Extract fee totals from HookFeesAccrued event logs
    /// @param logs Recorded logs to scan
    /// @param poolId The pool ID to match against
    /// @return curatorFee The total curator fee from the HookFeesAccrued event
    /// @return protocolFee The total protocol fee from the HookFeesAccrued event
    function _getHookFeesAccruedFromLogs(Vm.Log[] memory logs, PoolId poolId)
        internal
        view
        returns (uint128 curatorFee, uint128 protocolFee)
    {
        bytes32 poolIdBytes = PoolId.unwrap(poolId);
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory log = logs[i - 1];
            if (log.emitter != address(tokiHook)) continue;
            if (log.topics[0] != bytes32(Events._HOOK_FEES_ACCRUED_EVENT_SIGNATURE)) continue;
            require(log.topics[1] == poolIdBytes, "PoolId mismatch");
            (curatorFee, protocolFee) = abi.decode(log.data, (uint128, uint128));
            return (curatorFee, protocolFee);
        }
        revert("HookFeesAccrued event not found");
    }

    struct SwapState {
        uint256 balance0OfUser;
        uint256 balance1OfUser;
        uint256 balance0OfPM;
        uint256 balance1OfPM;
        uint256 shares0OfHook;
        uint256 shares1OfHook;
        ITokiHook.PoolStorage state;
    }

    function cacheSwapState(address user) internal view returns (SwapState memory state) {
        state.balance0OfUser = poolKey.currency0.balanceOf(user);
        state.balance1OfUser = poolKey.currency1.balanceOf(user);
        state.balance0OfPM = poolKey.currency0.balanceOf(address(poolManager));
        state.balance1OfPM = poolKey.currency1.balanceOf(address(poolManager));

        (ERC4626 vault0, ERC4626 vault1) = vaultsOf(poolKey.toId());
        if (address(vault0) != address(0)) {
            state.shares0OfHook = vault0.balanceOf(address(tokiHook));
        }
        if (address(vault1) != address(0)) {
            state.shares1OfHook = vault1.balanceOf(address(tokiHook));
        }
        state.state = stateOf(poolKey.toId());
    }

    function assertBalanceChanges(
        SwapState memory stateBefore,
        SwapState memory stateAfter,
        BalanceDelta delta,
        string memory context
    ) internal pure {
        // User balance assertions
        if (delta.amount0() < 0) {
            assertEq(
                stateAfter.balance0OfUser,
                stateBefore.balance0OfUser - uint256(-int256(delta.amount0())),
                string.concat(context, ": user currency0")
            );
        } else {
            assertEq(
                stateAfter.balance0OfUser,
                stateBefore.balance0OfUser + uint256(int256(delta.amount0())),
                string.concat(context, ": user currency0")
            );
        }

        if (delta.amount1() < 0) {
            assertEq(
                stateAfter.balance1OfUser,
                stateBefore.balance1OfUser - uint256(-int256(delta.amount1())),
                string.concat(context, ": user currency1")
            );
        } else {
            assertEq(
                stateAfter.balance1OfUser,
                stateBefore.balance1OfUser + uint256(int256(delta.amount1())),
                string.concat(context, ": user currency1")
            );
        }
    }

    function assertStateChanges(
        SwapState memory stateBefore,
        SwapState memory stateAfter,
        BalanceDelta delta,
        bool expectImpliedRateIncrease,
        string memory context
    ) internal view {
        // Fee assertions
        assertGt(
            stateAfter.state.fees.value0(), stateBefore.state.fees.value0(), string.concat(context, ": fees.value0")
        );

        if (Constants.DEFAULT_SPLIT_RATIO_BPS == Constants.BASIS_POINTS) {
            if (delta.amount0() < 0) {
                // zeroForOne (currency0 -> currency1)
                // exact-in of currency0 adds dust to protocol fees
                assertGe(
                    stateAfter.state.fees.value1(),
                    stateBefore.state.fees.value1(),
                    string.concat(context, ": fees.value1")
                );
            } else {
                assertEq(
                    stateAfter.state.fees.value1(),
                    stateBefore.state.fees.value1(),
                    string.concat(context, ": fees.value1")
                );
            }
        } else {
            assertGt(
                stateAfter.state.fees.value1(), stateBefore.state.fees.value1(), string.concat(context, ": fees.value1")
            );
        }

        int256 shares0Delta = int256(stateAfter.shares0OfHook) - int256(stateBefore.shares0OfHook); // Positive if hook has more shares
        int256 shares1Delta = int256(stateAfter.shares1OfHook) - int256(stateBefore.shares1OfHook);

        (ERC4626 vault0, ERC4626 vault1) = vaultsOf(poolKey.toId());

        // Reserve assertions
        if (address(vault0) == address(0)) {
            assertEq(stateAfter.state.reserves.value0(), 0, string.concat(context, ": reserves.value0"));
        } else {
            assertEq(
                stateAfter.state.reserves.value0().toInt256(),
                stateBefore.state.reserves.value0().toInt256() + shares0Delta,
                string.concat(context, ": reserves.value0")
            );
        }
        if (address(vault1) == address(0)) {
            assertEq(stateAfter.state.reserves.value1(), 0, string.concat(context, ": reserves.value1"));
        } else {
            assertEq(
                stateAfter.state.reserves.value1().toInt256(),
                stateBefore.state.reserves.value1().toInt256() + shares1Delta,
                string.concat(context, ": reserves.value1")
            );
        }

        // Implied rate assertion
        if (expectImpliedRateIncrease) {
            assertGt(
                stateAfter.state.lnImpliedRate,
                stateBefore.state.lnImpliedRate,
                string.concat(context, ": lnImpliedRate should increase")
            );
        } else {
            assertLt(
                stateAfter.state.lnImpliedRate,
                stateBefore.state.lnImpliedRate,
                string.concat(context, ": lnImpliedRate should decrease")
            );
        }

        // Calculate total fees
        uint256 feesPaid = stateAfter.state.fees.value0() + stateAfter.state.fees.value1()
            - stateBefore.state.fees.value0() - stateBefore.state.fees.value1();

        // rawBalances assertions
        if (address(vault0) == address(0)) {
            // If vault is not set, easy to assert
            if (delta.amount0() >= 0) {
                assertEq(
                    stateAfter.state.rawBalances.value0(),
                    stateBefore.state.rawBalances.value0() - uint256(int256(delta.amount0())) - feesPaid,
                    string.concat(context, ": rawBalances.value0")
                );
            } else {
                assertEq(
                    stateAfter.state.rawBalances.value0(),
                    stateBefore.state.rawBalances.value0() + uint256(-int256(delta.amount0())) - feesPaid,
                    string.concat(context, ": rawBalances.value0")
                );
            }
        }

        if (address(vault1) == address(0)) {
            if (delta.amount1() >= 0) {
                assertEq(
                    stateAfter.state.rawBalances.value1(),
                    stateBefore.state.rawBalances.value1() - uint256(int256(delta.amount1())),
                    string.concat(context, ": rawBalances.value1")
                );
            } else {
                assertEq(
                    stateAfter.state.rawBalances.value1(),
                    stateBefore.state.rawBalances.value1() + uint256(-int256(delta.amount1())),
                    string.concat(context, ": rawBalances.value1")
                );
            }
        }

        // Pool manager consistency check
        assertEq(
            poolKey.currency0.balanceOf(address(poolManager)),
            stateAfter.state.rawBalances.value0() + feesPaid,
            string.concat(context, ": PM currency0")
        );
        assertEq(
            poolKey.currency1.balanceOf(address(poolManager)),
            stateAfter.state.rawBalances.value1(),
            string.concat(context, ": PM currency1")
        );
    }

    function assertSwapDeltas(BalanceDelta delta, bool zeroForOne, int256 amountSpecified, string memory context)
        internal
        pure
    {
        if (amountSpecified < 0) {
            // Exact input
            if (zeroForOne) {
                assertEq(
                    uint256(-int256(delta.amount0())),
                    uint256(-amountSpecified),
                    string.concat(context, ": exact in amount0")
                );
                assertGt(delta.amount1(), 0, string.concat(context, ": amount1 should be positive"));
            } else {
                assertEq(
                    uint256(-int256(delta.amount1())),
                    uint256(-amountSpecified),
                    string.concat(context, ": exact in amount1")
                );
                assertGt(delta.amount0(), 0, string.concat(context, ": amount0 should be positive"));
            }
        } else {
            // Exact output
            if (zeroForOne) {
                assertLt(delta.amount0(), 0, string.concat(context, ": amount0 should be negative"));
                assertEq(
                    uint256(int256(delta.amount1())),
                    uint256(amountSpecified),
                    string.concat(context, ": exact out amount1")
                );
            } else {
                assertLt(delta.amount1(), 0, string.concat(context, ": amount1 should be negative"));
                assertEq(
                    uint256(int256(delta.amount0())),
                    uint256(amountSpecified),
                    string.concat(context, ": exact out amount0")
                );
            }
        }
    }

    function assertSwapDeltas(
        BalanceDelta delta,
        bool zeroForOne,
        int256 amountSpecified,
        uint256 actualAmount0,
        uint256 epsilon,
        string memory context
    ) internal pure {
        if (amountSpecified < 0) {
            // Exact input with approximation
            if (zeroForOne) {
                uint256 requestedUnderlyingIn = uint256(-amountSpecified);
                assertLe(actualAmount0, requestedUnderlyingIn, string.concat(context, ": actual <= requested"));
                assertApproxEqRel(
                    actualAmount0, requestedUnderlyingIn, epsilon, string.concat(context, ": underlying ~= requested")
                );
                assertGt(delta.amount1(), 0, string.concat(context, ": amount1 should be positive"));
            } else {
                assertEq(
                    uint256(-int256(delta.amount1())),
                    uint256(-amountSpecified),
                    string.concat(context, ": exact in amount1")
                );
                assertGt(delta.amount0(), 0, string.concat(context, ": amount0 should be positive"));
            }
        } else {
            // Exact output
            revert("Underlying exact out not supported");
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        MAIN TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Swap_PrincipalTokenSpecified_ExactIn() public {
        // Arrange
        uint256 ptAmountIn = 10 * bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        _test_Swap_PrincipalTokenSpecified_ExactIn(ptAmountIn);

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function _test_Swap_PrincipalTokenSpecified_ExactIn(uint256 ptAmountIn)
        public
        returns (BalanceDelta delta, SwapState memory stateBefore, SwapState memory stateAfter)
    {
        stateBefore = cacheSwapState(alice);

        // Act
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency1), address(swapRouter), ptAmountIn);

        delta = swap({
            _key: poolKey,
            zeroForOne: false, // PT (currency1) -> underlying (currency0)
            amountSpecified: -int256(ptAmountIn), // negative for exact in
            hookData: ""
        });
        vm.stopPrank();

        stateAfter = cacheSwapState(alice);

        // Assert
        assertSwapDeltas({delta: delta, zeroForOne: false, amountSpecified: -int256(ptAmountIn), context: "PT exact in"});
        assertBalanceChanges({stateBefore: stateBefore, stateAfter: stateAfter, delta: delta, context: "PT exact in"});
        assertStateChanges({
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            delta: delta,
            expectImpliedRateIncrease: true, // true = expect rate increase when selling PT
            context: "PT exact in"
        });
    }

    function test_Swap_PrincipalTokenSpecified_ExactOut() public {
        // Arrange
        uint256 ptAmountOut = 8 * bOne;
        uint256 maxUnderlyingIn = 15 * tOne;
        deal(Currency.unwrap(poolKey.currency0), alice, maxUnderlyingIn);

        SwapState memory stateBefore = cacheSwapState(alice);

        // Act
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(swapRouter), maxUnderlyingIn);

        BalanceDelta delta = swap({
            _key: poolKey,
            zeroForOne: true, // underlying (currency0) -> PT (currency1)
            amountSpecified: int256(ptAmountOut), // positive for exact out
            hookData: ""
        });
        vm.stopPrank();

        SwapState memory stateAfter = cacheSwapState(alice);

        // Assert
        assertSwapDeltas({delta: delta, zeroForOne: true, amountSpecified: int256(ptAmountOut), context: "PT exact out"});
        assertBalanceChanges({stateBefore: stateBefore, stateAfter: stateAfter, delta: delta, context: "PT exact out"});
        assertStateChanges({
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            delta: delta,
            expectImpliedRateIncrease: false, // false = expect rate decrease when buying PT
            context: "PT exact out"
        });

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_Swap_UnderlyingTokenSpecified_ExactIn() public {
        // Arrange
        uint256 underlyingAmountIn = 10 * tOne;
        deal(Currency.unwrap(poolKey.currency0), alice, underlyingAmountIn);

        SwapState memory stateBefore = cacheSwapState(alice);

        // Act
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(swapRouter), underlyingAmountIn);

        // Capture HookSwap event
        vm.recordLogs();
        BalanceDelta delta = swap({
            _key: poolKey,
            zeroForOne: true, // underlying (currency0) -> PT (currency1)
            amountSpecified: -int256(underlyingAmountIn), // negative for exact in
            hookData: ""
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        SwapState memory stateAfter = cacheSwapState(alice);

        // Since swap exact-in of currency0 uses binary search, there should be remaining amount0
        int128 hookSwapAmount0 = _getHookSwapAmount0FromLogs(logs, poolKey.toId());
        (uint128 curatorFee, uint128 protocolFee) = _getHookFeesAccruedFromLogs(logs, poolKey.toId());

        // Assert
        assertLt(hookSwapAmount0, 0, "Actual delta0 should be negative (exact input)");
        assertEq(curatorFee, stateAfter.state.fees.value0(), "HookFeesAccrued curator fee mismatch");
        assertEq(protocolFee, stateAfter.state.fees.value1(), "HookFeesAccrued protocol fee mismatch");
        assertSwapDeltas({
            delta: delta,
            zeroForOne: true,
            amountSpecified: -int256(underlyingAmountIn),
            actualAmount0: uint256(int256(-hookSwapAmount0)),
            epsilon: TokiSwap.DEFAULT_BINSEARCH_EPSILON,
            context: "Underlying exact in"
        });
        assertBalanceChanges({
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            delta: delta,
            context: "Underlying exact in"
        });
        assertStateChanges({
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            delta: delta,
            expectImpliedRateIncrease: false, // false = expect rate decrease when buying PT
            context: "Underlying exact in"
        });

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_Swap_UnderlyingTokenSpecified_ExactIn_WithApproximationParams() public {
        // Arrange
        uint256 underlyingAmountIn = 10 * tOne;
        deal(Currency.unwrap(poolKey.currency0), alice, underlyingAmountIn);

        // Encode approximation parameters
        ApproximationParams memory approx = ApproximationParams({
            guessMin: int256(3 * bOne),
            guessMax: int256(15 * bOne),
            eps: 0.00_00005e18 // 0.00005%
        });
        bytes memory hookData = abi.encode(approx);

        SwapState memory stateBefore = cacheSwapState(alice);

        // Act
        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(swapRouter), underlyingAmountIn);

        vm.recordLogs();
        BalanceDelta delta = swap({
            _key: poolKey,
            zeroForOne: true, // underlying -> PT
            amountSpecified: -int256(underlyingAmountIn), // exact in (negative)
            hookData: hookData
        });
        Vm.Log[] memory logs = vm.getRecordedLogs();
        vm.stopPrank();

        SwapState memory stateAfter = cacheSwapState(alice);

        int128 hookSwapAmount0 = _getHookSwapAmount0FromLogs(logs, poolKey.toId());
        (uint128 curatorFee, uint128 protocolFee) = _getHookFeesAccruedFromLogs(logs, poolKey.toId());

        // Assert
        assertLt(hookSwapAmount0, 0, "Actual delta0 should be negative (exact input)");
        assertEq(curatorFee, stateAfter.state.fees.value0(), "HookFeesAccrued curator fee mismatch");
        assertEq(protocolFee, stateAfter.state.fees.value1(), "HookFeesAccrued protocol fee mismatch");
        assertSwapDeltas({
            delta: delta,
            zeroForOne: true,
            amountSpecified: -int256(underlyingAmountIn),
            actualAmount0: uint256(int256(-hookSwapAmount0)),
            epsilon: approx.eps,
            context: "Underlying exact in with custom params"
        });
        assertBalanceChanges({
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            delta: delta,
            context: "Underlying exact in with custom params"
        });
        assertStateChanges({
            stateBefore: stateBefore,
            stateAfter: stateAfter,
            delta: delta,
            expectImpliedRateIncrease: false, // false = expect rate decrease when buying PT
            context: "Underlying exact in with custom params"
        });

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     REVERT TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_RevertWhen_UnderlyingTokenExactOut() public {
        vm.startPrank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(Errors.TokiSwap_OnlyExactInSupported.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap({
            _key: poolKey,
            zeroForOne: false, // PT (currency1) -> underlying (currency0)
            amountSpecified: 10000, // positive for exact out
            hookData: ""
        });
        vm.stopPrank();
    }

    function test_RevertWhen_ZeroAmount() public {
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_RevertWhen_InvalidKey() public {
        vm.expectRevert(Errors.BadTokiPool.selector);
        PoolKey memory invalidKey = poolKey;
        invalidKey.fee = 69;
        vm.prank(address(poolManager));
        tokiHook.beforeSwap(
            alice,
            invalidKey,
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0}),
            ""
        );
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
        vm.prank(address(poolManager));
        tokiHook.beforeSwap(
            alice, poolKey, IPoolManager.SwapParams({zeroForOne: false, amountSpecified: 0, sqrtPriceLimitX96: 0}), ""
        );
    }

    function test_RevertWhen_Expired() public {
        vm.warp(expiry + 1);

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false, // PT (currency1) for underlying (currency0)
            amountSpecified: -10e18, // negative for exact in (10 PT tokens)
            sqrtPriceLimitX96: 0
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(Errors.Expired.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
    }

    function test_RevertWhen_InsufficientLiquidity() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(Errors.TokiSwap_InsufficientPrincipalsLiquidity.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap({_key: poolKey, zeroForOne: true, amountSpecified: int256(INITIAL_AMOUNT1 + 1), hookData: ""});
    }

    function test_RevertWhen_InvalidGuess() public {
        ApproximationParams memory approx = ApproximationParams({guessMin: 1300e18, guessMax: 30e18, eps: 0.001e18});
        bytes memory hookData = abi.encode(approx);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(Errors.ApproximationParams_InvalidGuess.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap({_key: poolKey, zeroForOne: false, amountSpecified: 1121290, hookData: hookData});
    }

    function test_RevertWhen_InvalidApproximationParams() public {
        bytes memory badHookData = abi.encode(0, 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(Errors.ApproximationParams_OutOfBounds.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap({_key: poolKey, zeroForOne: false, amountSpecified: 1121290, hookData: badHookData});
    }

    function test_RevertWhen_NoSolutionFound() public {
        vm.skip(true);
    }
}

contract SwapPTNoVaultsHookTest is SwapPTHookBase {
    function setUp() public override {
        _setUp({enableRehypothecation0: false});

        _depositLiquidity(INITIAL_AMOUNT0, INITIAL_AMOUNT1);
    }
}

contract SwapPTWithVaultsHookTest is SwapPTHookBase {
    using CurrencyLibrary for Currency;
    using SafeTransferLib for *;
    using SafeCastLib for *;

    function setUp() public override {
        _setUp({enableRehypothecation0: true});

        _depositLiquidity(INITIAL_AMOUNT0, INITIAL_AMOUNT1);
    }

    function test_When_WithdrawIsNeeded() public {
        // Deposit initial liquidity and make raw/balance ratio unbalanced
        rehypothecationConfig0 = RehypothecationConfig({
            targetRawTokenRatio: 10,
            maxRawTokenRatio: 1000, // No rebalance triggered
            minRawTokenRatio: 0 // No rebalance triggered
        });

        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;

        ITokiHook.ImmutableParams memory newImmutableParams = ImmutableParamsLib.parse(immutableParamsPointer);
        newImmutableParams.targetRawTokenRatio0 = rehypothecationConfig0.targetRawTokenRatio;
        newImmutableParams.maxRawTokenRatio0 = rehypothecationConfig0.maxRawTokenRatio;
        newImmutableParams.minRawTokenRatio0 = rehypothecationConfig0.minRawTokenRatio;

        cheat_setImmutableParamsPointer(immutableParamsPointer, newImmutableParams);
        _depositLiquidity(INITIAL_AMOUNT0, INITIAL_AMOUNT1);

        // Buying currency0 should trigger a withdrawal from vault0

        // Arrange
        uint256 ptAmountIn = INITIAL_AMOUNT1 * 70 / 100;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        (, SwapState memory stateBefore, SwapState memory stateAfter) =
            _test_Swap_PrincipalTokenSpecified_ExactIn(ptAmountIn);
        assertLt(
            stateAfter.state.reserves.value0(), stateBefore.state.reserves.value0(), "withdrawal should have happened"
        );

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_When_RawBalanceRatioGreaterThanMinRatio() public {
        testFuzz_When_RawBalanceRatioLessThanMinRatio(6000, 5500, 7000);
    }

    function testFuzz_When_RawBalanceRatioLessThanMinRatio(
        uint16 newTargetRawTokenRatio,
        uint16 newMinRawTokenRatio,
        uint16 newMaxRawTokenRatio
    ) public {
        // Arrange
        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(immutableParamsPointer);

        // so, it's slightly off from the actual rebalance threshold
        uint16 currentRawRatio;
        {
            ITokiHook.PoolStorage memory currentState = stateOf(poolKey.toId());
            uint256 rawBalances0Before = currentState.rawBalances.value0();
            uint256 balances0Before = vault0.previewRedeem(currentState.reserves.value0()) + rawBalances0Before;
            currentRawRatio = (rawBalances0Before * Constants.BASIS_POINTS / balances0Before).toUint16();
        }

        // Bound inputs to ensure we trigger withdrawal from vault0
        // For withdrawal: currentRawRatio < minRawTokenRatio
        newMinRawTokenRatio = bound(newMinRawTokenRatio, currentRawRatio, Constants.BASIS_POINTS).toUint16();
        newTargetRawTokenRatio = bound(newTargetRawTokenRatio, currentRawRatio, Constants.BASIS_POINTS).toUint16();
        newMaxRawTokenRatio = bound(newMaxRawTokenRatio, newTargetRawTokenRatio, Constants.BASIS_POINTS).toUint16();

        params.targetRawTokenRatio0 = newTargetRawTokenRatio;
        params.minRawTokenRatio0 = newMinRawTokenRatio;
        params.maxRawTokenRatio0 = newMaxRawTokenRatio;
        cheat_setImmutableParamsPointer(immutableParamsPointer, params);

        // Any swap should trigger a withdrawal from vault0
        uint256 ptAmountIn = bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        (, SwapState memory stateBefore, SwapState memory stateAfter) =
            _test_Swap_PrincipalTokenSpecified_ExactIn(ptAmountIn);

        {
            bool rebalanced = stateAfter.state.reserves.value0() < stateBefore.state.reserves.value0();

            if (rebalanced) {
                // Verify target ratio is approximately reached
                uint256 newRawBalances0 = stateAfter.state.rawBalances.value0();
                uint256 balances0 = vault0.previewRedeem(stateAfter.state.reserves.value0()) + newRawBalances0;
                assertApproxEqRel(
                    newRawBalances0,
                    balances0 * newTargetRawTokenRatio / Constants.BASIS_POINTS,
                    0.05e18,
                    "rebalance amount should reach target"
                );
            } else {
                assertEq(stateAfter.state.reserves.value0(), stateBefore.state.reserves.value0(), "vault0 no rebalance");
                assertEq(stateAfter.state.reserves.value1(), stateBefore.state.reserves.value1(), "vault1 no rebalance");
            }
        }

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_When_RawBalanceRatioGreaterThanMaxRatio() public {
        testFuzz_When_RawBalanceRatioGreaterThanMaxRatio(4000, 0, 4500);
    }

    function testFuzz_When_RawBalanceRatioGreaterThanMaxRatio(
        uint16 newTargetRawTokenRatio,
        uint16 newMinRawTokenRatio,
        uint16 newMaxRawTokenRatio
    ) public {
        // Arrange
        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(immutableParamsPointer);

        // Note: Estimate current raw ratio from pool state but actual rebalance threshold is calculated based on post-swap state
        // so, it's slightly off from the actual rebalance threshold
        uint16 currentRawRatio;
        {
            ITokiHook.PoolStorage memory currentState = stateOf(poolKey.toId());
            uint256 rawBalances0Before = currentState.rawBalances.value0();
            uint256 balances0Before = vault0.previewRedeem(currentState.reserves.value0()) + rawBalances0Before;
            currentRawRatio = (rawBalances0Before * Constants.BASIS_POINTS / balances0Before).toUint16();
        }

        // Bound inputs to ensure we trigger deposit to vault0
        // For deposit to occur: currentRawRatio > maxRawTokenRatio
        newMaxRawTokenRatio = bound(newMaxRawTokenRatio, 0, currentRawRatio).toUint16();
        newTargetRawTokenRatio = bound(newTargetRawTokenRatio, 0, newMaxRawTokenRatio).toUint16();
        newMinRawTokenRatio = bound(newMinRawTokenRatio, 0, newTargetRawTokenRatio).toUint16();

        params.targetRawTokenRatio0 = newTargetRawTokenRatio;
        params.minRawTokenRatio0 = newMinRawTokenRatio;
        params.maxRawTokenRatio0 = newMaxRawTokenRatio;
        cheat_setImmutableParamsPointer(immutableParamsPointer, params);

        // Any swap should trigger a deposit to vault0
        uint256 ptAmountIn = bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        (, SwapState memory stateBefore, SwapState memory stateAfter) =
            _test_Swap_PrincipalTokenSpecified_ExactIn(ptAmountIn);

        {
            bool rebalanced = stateAfter.state.reserves.value0() > stateBefore.state.reserves.value0();

            if (rebalanced) {
                // Verify target ratio is approximately reached
                uint256 newRawBalances0 = stateAfter.state.rawBalances.value0();
                uint256 balances0 = vault0.previewRedeem(stateAfter.state.reserves.value0()) + newRawBalances0;
                assertApproxEqRel(
                    newRawBalances0,
                    balances0 * newTargetRawTokenRatio / Constants.BASIS_POINTS,
                    0.05e18,
                    "rebalance amount should reach target"
                );
            } else {
                assertEq(stateAfter.state.reserves.value0(), stateBefore.state.reserves.value0(), "vault0 no rebalance");
                assertEq(stateAfter.state.reserves.value1(), stateBefore.state.reserves.value1(), "vault1 no rebalance");
            }
        }

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    /// @dev A vault refusing withdrawal capacity must not abort the swap through the rebalance leg
    function test_When_RebalanceWithdrawCapped() public {
        _setRawTokenRatios0({target: 6000, min: 5500, max: 7000});

        vault0.setWithdrawCap(0);

        uint256 ptAmountIn = bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        (, SwapState memory stateBefore, SwapState memory stateAfter) =
            _test_Swap_PrincipalTokenSpecified_ExactIn(ptAmountIn);

        uint256 rawBalance0 = stateAfter.state.rawBalances.value0();
        uint256 balance0 = vault0.previewRedeem(stateAfter.state.reserves.value0()) + rawBalance0;
        assertLt(rawBalance0, balance0 * 5500 / Constants.BASIS_POINTS, "swap must leave the raw ratio below min");
        assertEq(
            stateAfter.state.reserves.value0(), stateBefore.state.reserves.value0(), "no rebalance withdrawal at cap 0"
        );
    }

    /// @dev The rebalance withdrawal is capped at the vault's capacity instead of the target deficit
    function test_When_RebalanceWithdrawPartiallyCapped() public {
        _setRawTokenRatios0({target: 6000, min: 5500, max: 7000});

        uint256 cap = tOne;
        vault0.setWithdrawCap(cap);

        uint256 ptAmountIn = bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        (, SwapState memory stateBefore, SwapState memory stateAfter) =
            _test_Swap_PrincipalTokenSpecified_ExactIn(ptAmountIn);

        uint256 sharesBurned = stateBefore.state.reserves.value0() - stateAfter.state.reserves.value0();
        assertApproxEqAbs(vault0.previewRedeem(sharesBurned), cap, 2, "withdrawal clamped to capacity");
    }

    function _setRawTokenRatios0(uint16 target, uint16 min, uint16 max) internal {
        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(immutableParamsPointer);

        params.targetRawTokenRatio0 = target;
        params.minRawTokenRatio0 = min;
        params.maxRawTokenRatio0 = max;
        cheat_setImmutableParamsPointer(immutableParamsPointer, params);
    }

    function test_RevertWhen_CriticalVaultLoss() public {
        // Configure very low raw ratio to force most liquidity into vault0
        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(immutableParamsPointer);

        params.targetRawTokenRatio0 = 1; // Low raw ratio
        params.minRawTokenRatio0 = 1000;
        params.maxRawTokenRatio0 = 3000;
        cheat_setImmutableParamsPointer(immutableParamsPointer, params);

        uint256 dust = 100000;
        deal(Currency.unwrap(poolKey.currency1), alice, dust);
        _test_Swap_PrincipalTokenSpecified_ExactIn(dust); // Trigger rebalance

        // Simulate critical losses
        vm.startPrank(address(vault0));
        SafeTransferLib.safeTransfer(address(target), chika, target.balanceOf(address(vault0)) * 90 / 100);
        vm.stopPrank();

        uint256 ptAmountIn = bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        vm.startPrank(alice);
        // Vault may pull more shares than pool has, causing an underflow/overflow or swap calculation may be broken because of pool balance is lost
        vm.expectRevert();
        swap({
            _key: poolKey,
            zeroForOne: false, // PT → Underlying (triggers vault0 withdrawal)
            amountSpecified: -int256(ptAmountIn), // Exact input swap
            hookData: ""
        });

        vm.stopPrank();
    }

    function test_RevertWhen_VaultWithdrawMoreThanReserves() public {
        // Configure very low raw ratio to force most liquidity into vault0
        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(immutableParamsPointer);

        params.targetRawTokenRatio0 = uint16(Constants.BASIS_POINTS); // Trigger rebalance
        params.minRawTokenRatio0 = uint16(Constants.BASIS_POINTS);
        params.maxRawTokenRatio0 = uint16(Constants.BASIS_POINTS);
        cheat_setImmutableParamsPointer(immutableParamsPointer, params);

        MockMaliciousERC4626 maliciousVault0 = new MockMaliciousERC4626(target, true);
        vm.etch(address(vault0), address(maliciousVault0).code);

        // Activate faulty code and set up vault shares
        vm.startPrank(chika);
        deal(address(base), chika, 1000000);
        base.approve(address(target), 1000000);
        uint256 v = target.deposit(1000000, chika);
        vault0.deposit(v, address(tokiHook)); // Set up reserves from other pools
        MockMaliciousERC4626(address(vault0)).setUpAttack(true, address(0xbad));
        vm.stopPrank();

        uint256 ptAmountIn = bOne;
        deal(Currency.unwrap(poolKey.currency1), alice, ptAmountIn);

        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency1), address(swapRouter), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(Errors.TokiHook_VaultWithdrawMoreThanReserves.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swap({
            _key: poolKey,
            zeroForOne: false, // PT → Underlying (triggers vault0 withdrawal)
            amountSpecified: -int256(ptAmountIn), // Exact input swap
            hookData: ""
        });
        vm.stopPrank();
    }

    function test_RevertWhen_VaultDepositMoreThanRequested() public {
        MockMaliciousERC4626 maliciousVault1 = new MockMaliciousERC4626(principalToken, true);
        _setRehypothecationVaults(poolKey, address(0), address(maliciousVault1));

        // Give the vault some initial balance so it can transfer extra tokens
        deal(address(principalToken), address(maliciousVault1), 1000 * bOne);

        // Activate malicious code
        maliciousVault1.setUpAttack(true, address(0xbad));

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(tokiHook),
                tokiHook.beforeSwap.selector,
                abi.encodeWithSelector(SafeTransferLib.TransferFromFailed.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        vm.startPrank(alice);
        swap({
            _key: poolKey,
            zeroForOne: false, // PT (currency1) -> underlying (currency0)
            amountSpecified: -90523, // negative for exact in
            hookData: ""
        });
        vm.stopPrank();
    }
}
