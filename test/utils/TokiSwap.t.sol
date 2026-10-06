// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {ITokiHook} from "src/interfaces/ITokiHook.sol";

import {TokiSwap} from "src/utils/TokiSwap.sol";
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract Dummy {}

contract TokiSwapTest is Test {
    using SafeCastLib for *;

    function testFuzz_Ternary(bool condition, int256 x, int256 y) public pure {
        assertEq(TokiSwap.ternary(condition, x, y), condition ? x : y);
    }

    function testFuzz_Sign(int256 x) public pure {
        assertEq(TokiSwap.sign(x), x > 0 ? int256(1) : x < 0 ? int256(-1) : int256(0));
    }

    function test_ConvertToUnderlying() public pure {
        // zero
        assertEq(TokiSwap.convertToUnderlying({assets: 0, maxscale: 1.2e18, roundUp: false}), 0);
        assertEq(TokiSwap.convertToUnderlying({assets: 0, maxscale: 1.2e18, roundUp: true}), 0);

        // positive
        assertEq(TokiSwap.convertToUnderlying({assets: 1e6, maxscale: 2e18, roundUp: false}), 0.5e6);
        assertEq(TokiSwap.convertToUnderlying({assets: 1e6, maxscale: 2e18, roundUp: true}), 0.5e6);

        // negative
        assertEq(TokiSwap.convertToUnderlying({assets: -1e6, maxscale: 2e18, roundUp: false}), -0.5e6);
        assertEq(TokiSwap.convertToUnderlying({assets: -1e6, maxscale: 2e18, roundUp: true}), -0.5e6);

        // positive with round up
        assertEq(TokiSwap.convertToUnderlying({assets: 1e6, maxscale: 3e18, roundUp: false}), int256(1e6) * 1e18 / 3e18);
        assertEq(
            TokiSwap.convertToUnderlying({assets: 1e6, maxscale: 3e18, roundUp: true}), int256(1e6) * 1e18 / 3e18 + 1
        );

        // negative with round up
        assertEq(
            TokiSwap.convertToUnderlying({assets: -1e6, maxscale: 3e18, roundUp: false}), -int256(1e6) * 1e18 / 3e18
        );
        assertEq(
            TokiSwap.convertToUnderlying({assets: -1e6, maxscale: 3e18, roundUp: true}),
            -(int256(1e6) * 1e18 / 3e18 + 1)
        );
    }

    /// @dev feeRateWad must not be zero
    function testFuzz_ConvertToExchangeRate_NonZero(uint256 lnImpliedRate, uint256 timeToExpiry) public pure {
        lnImpliedRate = bound(lnImpliedRate, lnWad(1e18), lnWad(1000e18));
        timeToExpiry = bound(timeToExpiry, 1, 5 * 365 days);
        assertGt(TokiSwap.convertToExchangeRate({lnImpliedRate: lnImpliedRate, timeToExpiry: timeToExpiry}), 0);
    }

    function test_ConvertToExchangeRate() public pure {
        assertEq(TokiSwap.convertToExchangeRate({lnImpliedRate: 0, timeToExpiry: 365 days}), 1e18);

        assertApproxEqRel(
            TokiSwap.convertToExchangeRate({
                lnImpliedRate: FixedPointMathLib.lnWad(1.0441e18).toUint256(), // IR: 4.41%
                timeToExpiry: 365 days
            }),
            1.0441e18,
            1e12
        );
        assertApproxEqRel(
            TokiSwap.convertToExchangeRate({
                lnImpliedRate: FixedPointMathLib.lnWad(1.1203e18).toUint256(), // IR: 12.03%
                timeToExpiry: 365 days / 4 // 3 months
            }),
            1.0288065844e18,
            1e12
        );
    }

    /// @dev Chapter 3.4 p_trade
    /// forge-config: default.allow_internal_expect_revert = true
    function test_RevertWhen_ProportionTooHigh() public {
        vm.expectRevert(Errors.TokiSwap_MarketProportionTooHigh.selector);
        TokiSwap._getExchangeRateNoFee({
            totalAssets: 1e10,
            totalPt: 1e10,
            rateScalar: 1e18,
            rateAnchor: 0,
            netPtToAccount: -0.96e10 // Negative - User sells principal token
        });
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_RevertWhen_ProportionGreaterThanOne() public {
        vm.expectRevert(Errors.TokiSwap_ProportionGreaterThanOne.selector);
        TokiSwap._lnProportion(1e18 + 1);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_RevertWhen_InsufficientPrincipalsLiquidity() public {
        uint256 totalAssets = 31e10;
        uint256 totalPt = 41e10;
        vm.expectRevert(Errors.TokiSwap_InsufficientPrincipalsLiquidity.selector);
        TokiSwap._getExchangeRateNoFee({
            totalAssets: totalAssets,
            totalPt: totalPt,
            rateScalar: 1e18,
            rateAnchor: 0,
            netPtToAccount: int256(totalPt) + 1
        });
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_RevertWhen_RateScalarZero() public {
        vm.expectRevert(Errors.TokiSwap_RateScalarZero.selector);
        TokiSwap._getRateScalar({scalarRoot: 0, timeToExpiry: 192 days});
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_RevertWhen_NoLiquidity() public {
        TokiSwap.PoolState memory state;
        ITokiHook.ImmutableParams memory immutables;

        state.balances = Packing.pack_uint128x2(212, 0); // No liquidity
        state.totalLiquidity = 0.9 ether;

        vm.expectRevert(Errors.TokiSwap_ZeroLiquidity.selector);
        TokiSwap.computeAmmParams(
            state,
            immutables,
            FeePctsPoolLib.pack({
                splitFeePct: 0,
                ammFeeParams: uint128(uint256(lnWad(1.01e18)) * uint256(Constants.TOKI_SWAP_FEE_SCALE) / Constants.WAD),
                reserveFeePct: 0
            })
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_Swap_RevertIf_InsufficientPrincipalTokenLiquidity(int256 amountSpecified) public {
        uint256 totalAssets = 1000_000e6;
        uint256 totalPt = 1300_000e6;
        amountSpecified = bound(amountSpecified, int256(totalPt), type(int256).max);

        TokiSwap.PoolState memory state = TokiSwap.PoolState({
            balances: Packing.pack_uint128x2(uint128(totalAssets), uint128(totalPt)),
            fees: Packing.pack_uint128x2(0, 0),
            totalLiquidity: 1,
            lnImpliedRate: lnWad(1.09e18)
        });
        TokiSwap.TokiAmmParams memory params; // It doesn't matter
        vm.expectRevert(Errors.TokiSwap_InsufficientPrincipalsLiquidity.selector);
        TokiSwap.computeSwapExactPrincipal(state, params, amountSpecified);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_Swap_RevertIf_ExactUnderlyingOut() public {
        TokiSwap.PoolState memory state = TokiSwap.PoolState({
            balances: Packing.pack_uint128x2(uint128(390_000e6), uint128(100_000e6)),
            fees: Packing.pack_uint128x2(0, 0),
            totalLiquidity: 100_000e6,
            lnImpliedRate: lnWad(1.09e18)
        });
        TokiSwap.TokiAmmParams memory params; // It doesn't matter

        vm.expectRevert(Errors.TokiSwap_OnlyExactInSupported.selector);
        TokiSwap.computeSwapExactUnderlying(
            state, params, 100_000e6, ApproximationParams({guessMin: 0, guessMax: 1000, eps: 0})
        );

        vm.expectRevert(Errors.TokiSwap_OnlyExactInSupported.selector);
        TokiSwap.computeSwapExactUnderlying(
            state, params, 100_000e6, ApproximationParams({guessMin: 10, guessMax: 1000, eps: 100})
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_Swap_RevertIf_InvalidApproximationParams() public {
        TokiSwap.PoolState memory state = TokiSwap.PoolState({
            balances: Packing.pack_uint128x2(uint128(390_000e6), uint128(100_000e6)),
            fees: Packing.pack_uint128x2(0, 0),
            totalLiquidity: 100_000e6,
            lnImpliedRate: lnWad(1.09e18)
        });
        TokiSwap.TokiAmmParams memory params; // It doesn't matter

        vm.expectRevert(Errors.ApproximationParams_InvalidGuess.selector);
        TokiSwap.computeSwapExactUnderlying(
            state, params, -100_000e6, ApproximationParams({guessMin: 1000, guessMax: 199, eps: 0})
        );

        vm.expectRevert(Errors.ApproximationParams_InvalidGuess.selector);
        TokiSwap.computeSwapExactUnderlying(
            state, params, -100_000e6, ApproximationParams({guessMin: -10, guessMax: -1000, eps: 100})
        );

        vm.expectRevert(Errors.ApproximationParams_InvalidGuess.selector);
        TokiSwap.computeSwapExactUnderlying(
            state, params, -100e6, ApproximationParams({guessMin: -10, guessMax: 10, eps: 100})
        );
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_Swap_RevertIf_InvalidEps() public {
        TokiSwap.PoolState memory state = TokiSwap.PoolState({
            balances: Packing.pack_uint128x2(uint128(390_000e6), uint128(100_000e6)),
            fees: Packing.pack_uint128x2(0, 0),
            totalLiquidity: 100_000e6,
            lnImpliedRate: lnWad(1.09e18)
        });
        TokiSwap.TokiAmmParams memory params; // It doesn't matter

        vm.expectRevert(Errors.ApproximationParams_InvalidEps.selector);
        TokiSwap.computeSwapExactUnderlying(
            state,
            params,
            -10e6,
            ApproximationParams({guessMin: 0, guessMax: 100000, eps: TokiSwap.MAX_BINSEARCH_EPSILON + 1})
        );
    }

    function test_ComputeSwapExactPrincipal_WhenAmountSpecifiedZero() public pure {
        TokiSwap.PoolState memory state = TokiSwap.PoolState({
            balances: Packing.pack_uint128x2(uint128(1_000_000e6), uint128(800_000e6)),
            fees: Packing.pack_uint128x2(0, 0),
            totalLiquidity: 1,
            lnImpliedRate: lnWad(1.1e18)
        });

        TokiSwap.TokiAmmParams memory params = TokiSwap.TokiAmmParams({
            totalAssets: 1_000_000e6,
            rateScalar: int256(12e17),
            rateAnchor: int256(13e17),
            feeRateWad: int256(101e16),
            maxscale: 1e18,
            feePcts: FeePctsPoolLib.pack({splitFeePct: 0, ammFeeParams: 0, reserveFeePct: 0})
        });

        (int256 underlyingAmount, int256 principals, uint256 swapFee, uint256 feeToCuratorAndProtocol) =
            TokiSwap.computeSwapExactPrincipal(state, params, 0);

        assertEq(underlyingAmount, 0, "underlyingAmount");
        assertEq(principals, 0, "principals");
        assertEq(swapFee, 0, "swapFee");
        assertEq(feeToCuratorAndProtocol, 0, "feeToCuratorAndProtocol");
    }

    function test_ComputeSwapExactUnderlying_WhenAmountSpecifiedZero() public pure {
        TokiSwap.PoolState memory state = TokiSwap.PoolState({
            balances: Packing.pack_uint128x2(uint128(1_000_000e6), uint128(800_000e6)),
            fees: Packing.pack_uint128x2(0, 0),
            totalLiquidity: 1,
            lnImpliedRate: lnWad(1.1e18)
        });

        TokiSwap.TokiAmmParams memory params = TokiSwap.TokiAmmParams({
            totalAssets: 1_000_000e6,
            rateScalar: int256(12e17),
            rateAnchor: int256(13e17),
            feeRateWad: int256(101e16),
            maxscale: 1e18,
            feePcts: FeePctsPoolLib.pack({splitFeePct: 0, ammFeeParams: 0, reserveFeePct: 0})
        });

        (int256 underlyingAmount, int256 principals, uint256 swapFee, uint256 feeToCuratorAndProtocol) = TokiSwap
            .computeSwapExactUnderlying(state, params, 0, ApproximationParams({guessMin: 0, guessMax: 0, eps: 1}));

        assertEq(underlyingAmount, 0, "underlyingAmount");
        assertEq(principals, 0, "principals");
        assertEq(swapFee, 0, "swapFee");
        assertEq(feeToCuratorAndProtocol, 0, "feeToCuratorAndProtocol");
    }

    function test_ComputeOptimalParameters_1() public {
        // reference: https://etherscan.io/tx/0x525ba39d9ea8c0f7f07687f88985cb0a08e4a78918128c326532e7068152acd9
        vm.warp(1739971391);

        uint256 rateMin = 85000000000000000; // 8.5 %
        uint256 rateMax = 385000000000000000; // 38.5 %
        uint256 expiry = 1748476800;
        uint256 expectedScalarRoot = 17036083029428535284;
        int256 expectedInitialRateAnchor = 1057031453471802941;

        (uint256 scalarRoot, int256 initialRateAnchor) = TokiSwap.computeOptimalParameters(rateMin, rateMax, expiry);

        assertApproxEqRel(scalarRoot, expectedScalarRoot, 0.01e18, "scalarRoot");
        assertApproxEqRel(initialRateAnchor, expectedInitialRateAnchor, 0.01e18, "initialRateAnchor");
    }

    function test_ComputeOptimalParameters_2() public {
        // reference: https://etherscan.io/tx/0x07a010b9103385364b2bb3e7c1ec9a80994f8786cd924c770b2ef9ad9a881f0b
        vm.warp(1742297675);

        uint256 rateMin = 55000000000000000; // 5.5 %
        uint256 rateMax = 350000000000000000; // 35 %
        uint256 expiry = 1758758400;
        uint256 expectedScalarRoot = 16240223350842364143;
        int256 expectedInitialRateAnchor = 1098960161431879138;

        (uint256 scalarRoot, int256 initialRateAnchor) = TokiSwap.computeOptimalParameters(rateMin, rateMax, expiry);

        assertApproxEqRel(scalarRoot, expectedScalarRoot, 0.01e18, "scalarRoot");
        assertApproxEqRel(initialRateAnchor, expectedInitialRateAnchor, 0.01e18, "initialRateAnchor");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ComputeOptimalParameters_RevertWhen_BadRateRange() public {
        uint256 rateMin = 12321321431434214214;
        uint256 rateMax = rateMin;
        uint256 expiry = block.timestamp + 231 days;

        vm.expectRevert(Errors.TokiSwap_BadRateRange.selector);
        TokiSwap.computeOptimalParameters(rateMin, rateMax, expiry);
    }

    function test_ComputeInitialProportion_1() public {
        // reference: https://etherscan.io/tx/0x525ba39d9ea8c0f7f07687f88985cb0a08e4a78918128c326532e7068152acd9
        // 1 Underlying -> 1 PT
        vm.warp(1739971391);

        uint256 desiredImpliedRate = 185000000000000000; // 18.5 %
        uint256 expiry = 1748476800;
        uint256 scalarRoot = 17036083029428535284;
        int256 rateAnchor = 1057031453471802941;
        uint256 seedUnderlyingLiquidity = 1000000000000000000;
        uint256 underlyingsToPrincipals = 344463977114087244;

        uint256 principals = 344463977114087244;
        uint256 underlyings = seedUnderlyingLiquidity - underlyingsToPrincipals;

        uint256 initialProportion =
            TokiSwap.computeInitialProportion(expiry, scalarRoot, rateAnchor, desiredImpliedRate);

        uint256 proportion = principals * 1e18 / (underlyings * 1e18 / 1e18 + principals);

        assertLt(initialProportion, 1e18);
        assertApproxEqRel(initialProportion * seedUnderlyingLiquidity / 1e18, underlyingsToPrincipals, 1e12);
        assertApproxEqRel(proportion, initialProportion, 1e12, "proportion");
    }

    function test_ComputeInitialProportion_2() public {
        // reference: https://etherscan.io/tx/0x07a010b9103385364b2bb3e7c1ec9a80994f8786cd924c770b2ef9ad9a881f0b
        // 1 Underlying -> 0.93 PT
        vm.warp(1742297675);

        uint256 desiredImpliedRate = 120000000000000000; // 12 %
        uint256 expiry = 1758758400;
        uint256 scalarRoot = 16240223350842364143;
        int256 rateAnchor = 1098960161431879138;
        uint256 seedUnderlyingLiquidity = 934112184342400176;
        uint256 underlyingsToPrincipals = 219062629824436077; // Underlying converted to principals
        // reserves
        uint256 principals = 234514262308496290;
        uint256 underlyings = seedUnderlyingLiquidity - underlyingsToPrincipals;

        uint256 scale = principals * 1e18 / underlyingsToPrincipals;

        uint256 initialProportion =
            TokiSwap.computeInitialProportion(expiry, scalarRoot, rateAnchor, desiredImpliedRate);

        uint256 proportion = principals * 1e18 / (underlyings * scale / 1e18 + principals);

        assertLt(initialProportion, 1e18);
        assertApproxEqRel(initialProportion * seedUnderlyingLiquidity / 1e18, underlyingsToPrincipals, 1e12);
        assertApproxEqRel(proportion, initialProportion, 1e12, "proportion");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    /// forge-config: default.fuzz.runs = 64
    function test_Swap_RevertIf_SolutionNotFound() public {
        vm.skip(true);
    }

    function lnWad(int256 x) public pure returns (uint96) {
        return FixedPointMathLib.lnWad(x).toUint256().toUint96();
    }
}
