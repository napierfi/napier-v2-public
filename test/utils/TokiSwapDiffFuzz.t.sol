// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/src/Test.sol";

import {Helpers} from "../shared/Helpers.sol";
import {
    MarketMathCore,
    MarketState,
    MarketPreCompute,
    PYIndex,
    Errors as MarketMathErrors
} from "./reference/MarketMathCore.sol";
// TODO: Remove this file once testing is done
// import {MarketApproxPtInLibV2, MarketApproxPtOutLibV2, ApproxParams} from "./reference/MarketApproxLibV2.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {LibBytes} from "solady/src/utils/LibBytes.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {TokiSwap, ITokiHook} from "src/utils/TokiSwap.sol";
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Snapshot, YieldIndex} from "src/utils/YieldMathLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract Dummy {}

contract TokiSwapDiffFuzzTest is Test, Helpers {
    using LibBytes for *;
    using SafeCastLib for *;
    using FixedPointMathLib for *;

    uint256 constant PY_INDEX_WAD = 1e18;

    address dummy;
    address resolver;
    Snapshot snapshot = Snapshot({globalIndex: YieldIndex.wrap(0), maxscale: uint128(PY_INDEX_WAD)});

    function setUp() public {
        dummy = address(new Dummy());
        resolver = address(new Dummy());
        vm.mockCall(dummy, abi.encodeWithSignature("i_resolver()"), abi.encode(resolver));
        vm.mockCall(dummy, abi.encodeWithSignature("getSnapshot()"), abi.encode(snapshot));
        vm.mockCall(resolver, abi.encodeWithSignature("scale()"), abi.encode(PY_INDEX_WAD));
    }

    struct FuzzInput {
        // immutables
        uint256 expiry;
        int256 scalarRoot;
        // dynamic
        uint128 totalSy;
        uint128 totalPt;
        uint96 lastLnImpliedRate;
        int256 rateAnchor;
        uint256 rateScalar;
        // fee rates - 100 = 100%
        uint128 ammFeeParams; // ln-based fee parameter encoded with 1e-8 resolution
        uint256 reserveFeePct; // 100 units
        uint256 splitFeeBps; // 10_000 units
    }

    // ------------------------------------------------------------------------
    // Helpers for Fuzzing inputs
    // ------------------------------------------------------------------------

    function toMarketState(FuzzInput memory input) internal pure returns (MarketState memory) {
        return MarketState({
            totalSy: input.totalSy.toInt256(),
            totalPt: input.totalPt.toInt256(),
            totalLp: 0, // not used in the test
            treasury: address(0),
            scalarRoot: input.scalarRoot,
            expiry: input.expiry,
            lnFeeRateRoot: uint256(input.ammFeeParams) * Constants.WAD / Constants.TOKI_SWAP_FEE_SCALE,
            reserveFeePercent: input.reserveFeePct,
            lastLnImpliedRate: input.lastLnImpliedRate
        });
    }

    function toPoolStorage(FuzzInput memory input) internal pure returns (TokiSwap.PoolState memory state) {
        state.balances = Packing.pack_uint128x2(input.totalSy, input.totalPt);
        state.fees = Packing.pack_uint128x2(0, 0);
        state.lnImpliedRate = input.lastLnImpliedRate;
    }

    function toFeePcts(FuzzInput memory input) internal pure returns (FeePctsPool feePcts) {
        feePcts = FeePctsPoolLib.pack({
            splitFeePct: uint16(input.splitFeeBps),
            ammFeeParams: input.ammFeeParams,
            // convert to basis points
            reserveFeePct: uint16(input.reserveFeePct * Constants.BASIS_POINTS / 100)
        });
    }

    function toImmutables(FuzzInput memory input) internal view returns (ITokiHook.ImmutableParams memory immutables) {
        immutables.principalToken = PrincipalToken(dummy); // Mock address
        immutables.liquidityToken;
        immutables.underlying;
        immutables.expiry = input.expiry;
        immutables.pausableFlags;
        immutables.hooklet;
        immutables.scalarRoot = input.scalarRoot.toUint256();
        immutables.initialAnchor = input.rateAnchor;
    }

    // ------------------------------------------------------------------------
    // Helpers for Fuzzing
    // ------------------------------------------------------------------------

    function lnWad(int256 x) internal pure returns (int256) {
        return FixedPointMathLib.lnWad(x);
    }

    /// @dev 18 decimal places
    /// @dev This function is used to bound the input of the fuzz test
    /// @dev expiry should be in the range (now, now + 2 years]
    modifier boundInputs(FuzzInput memory input) {
        input.expiry = bound(input.expiry, block.timestamp + 30 days, block.timestamp + 2 * 365 days);
        input.scalarRoot = bound(input.scalarRoot, 1e18, 5000 * 1e18);

        input.totalSy = bound(input.totalSy, 1e6, 1e9 * 1e18).toUint128();
        input.totalPt = bound(input.totalPt, input.totalSy, input.totalSy * 2).toUint128();
        input.lastLnImpliedRate =
            bound(input.lastLnImpliedRate, lnWad(1e18).toUint256(), lnWad(10e18).toUint256()).toUint96(); // 0% to thousands of percents
        input.rateAnchor = bound(input.rateAnchor, 1e18, 5000 * 1e18);
        input.rateScalar = bound(input.rateScalar, 1e18, 5000 * 1e18);

        uint256 minAmmFeeParam = 0;
        uint256 maxAmmFeeParam =
            uint256(uint256(lnWad(1.1e18))) * uint256(Constants.TOKI_SWAP_FEE_SCALE) / Constants.WAD; // 0% to 10%
        uint256 boundedAmmFeeParams = bound(uint256(input.ammFeeParams), minAmmFeeParam, maxAmmFeeParam);
        input.ammFeeParams = uint128(boundedAmmFeeParams);
        input.reserveFeePct =
            bound(input.reserveFeePct, 0, uint256(Constants.MAX_RESERVE_FEE_BPS) * 100 / Constants.BASIS_POINTS);
        input.splitFeeBps = 0;

        assertLe(input.ammFeeParams, Constants.MAX_TOKI_SWAP_FEE_PARAMS, "ammFeeParams should be within bounds");
        assertLe(input.reserveFeePct, 100, "reserveFeePct should be less than 100");
        assertLe(input.splitFeeBps, 10_000, "splitFeeBps should be less than 10000");
        _;
    }

    // ------------------------------------------------------------------------
    // Differential Fuzzing Tests
    // ------------------------------------------------------------------------

    function testFuzz_LnProportion(int256 proportion) public pure {
        proportion = _bound(proportion, 1, 1e18 - 1);
        int256 res = MarketMathCore._logProportion(proportion);
        int256 result = TokiSwap._lnProportion(proportion);
        assertApproxEqAbs(res, result, 100, "LnProportion() should be equal");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_LnProportion_RevertWhen_InvalidProportion() public {
        {
            vm.expectRevert(Errors.TokiSwap_ProportionGreaterThanOne.selector);
            TokiSwap._lnProportion(1e18 + 1);

            vm.expectRevert(MarketMathErrors.MarketProportionMustNotEqualOne.selector);
            MarketMathCore._logProportion(1e18 + 1);
        }

        {
            vm.expectRevert(Errors.TokiSwap_ProportionGreaterThanOne.selector);
            TokiSwap._lnProportion(1e18);

            vm.expectRevert(MarketMathErrors.MarketProportionMustNotEqualOne.selector);
            MarketMathCore._logProportion(1e18);
        }
    }

    function testFuzz_GetRateScalar(uint256 expiry, int256 scalarRoot) public view {
        expiry = _bound(expiry, block.timestamp + 1, block.timestamp + 10 * 365 days);
        scalarRoot = _bound(scalarRoot, 1e15, 50000000 * 1e18);

        MarketState memory market;
        market.expiry = expiry;
        market.scalarRoot = scalarRoot;

        uint256 timeToExpiry = expiry - block.timestamp;
        int256 result0 = TokiSwap._getRateScalar(uint256(scalarRoot), timeToExpiry);
        int256 result1 = MarketMathCore._getRateScalar(market, timeToExpiry);

        assertGt(result0, 0, "rate scalar should be greater than 0");
        assertApproxEqRel(result0, result1, 0.0000001e18, "rate scalar should be equal");
    }

    function test_ConvertToExchangeRate(uint256 timeToExpiry) public pure {
        timeToExpiry = bound(timeToExpiry, 1, 5 * 365 days);
        // Implied rate ranges from 0% to thousands of percents (1.01 for 1% Implied rate)
        // We test the edge cases and some random cases in the middle

        _test_convertToExchangeRate(lnWad(1e18), timeToExpiry);
        _test_convertToExchangeRate(lnWad(1e18 + 1e4), timeToExpiry);
        _test_convertToExchangeRate(lnWad(1e18 + 1e8), timeToExpiry);
        _test_convertToExchangeRate(lnWad(1e18 + 1e12), timeToExpiry);
        _test_convertToExchangeRate(lnWad(1e18 + 1e16), timeToExpiry);
        _test_convertToExchangeRate(lnWad(10e18), timeToExpiry);
        _test_convertToExchangeRate(lnWad(100e18), timeToExpiry);
        _test_convertToExchangeRate(lnWad(1000e18), timeToExpiry);
        _test_convertToExchangeRate(lnWad(12345e18), timeToExpiry);
        _test_convertToExchangeRate(lnWad(1234567890e18), timeToExpiry);

        _test_convertToExchangeRate(lnWad(2718281828459045235), timeToExpiry);
    }

    function _test_convertToExchangeRate(int256 lnImpliedRate, uint256 timeToExpiry) internal pure {
        require(lnImpliedRate >= 0, "lnImpliedRate should be greater than 0");
        int256 result0 = MarketMathCore._getExchangeRateFromImpliedRate(lnImpliedRate.toUint256(), timeToExpiry);
        int256 result1 = TokiSwap.convertToExchangeRate(lnImpliedRate.toUint256(), timeToExpiry);
        assertApproxEqRel(result0, result1, 1e12);
    }

    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_ExchangeRate(FuzzInput memory input, int256 amountSpecified) public view boundInputs(input) {
        amountSpecified = bound(amountSpecified, -input.totalPt.toInt256(), input.totalPt.toInt256());

        TokiSwap.PoolState memory state = toPoolStorage(input);
        MarketState memory market = toMarketState(input);

        (bool s, bytes memory ret) = address(this).staticcall(
            abi.encodeCall(
                this._reference_getExchangeRate,
                (market.totalPt, market.totalSy, market.scalarRoot, input.rateAnchor, amountSpecified)
            )
        );
        vm.assume(s);
        int256 result0 = abi.decode(ret, (int256));

        int256 result1 = TokiSwap._getExchangeRateNoFee({
            totalAssets: state.balances.value0(),
            totalPt: state.balances.value1(),
            rateScalar: input.scalarRoot,
            rateAnchor: input.rateAnchor,
            netPtToAccount: amountSpecified
        });
        assertApproxEqRel(result0, result1, 1e16, "exchange rate no fee");
    }

    function _reference_getExchangeRate(
        int256 totalPt,
        int256 totalSy,
        int256 rateScalar,
        int256 rateAnchor,
        int256 amountSpecified
    ) external pure returns (int256) {
        return MarketMathCore._getExchangeRate(totalPt, totalSy, rateScalar, rateAnchor, amountSpecified);
    }

    function testFuzz_ComputeTokiAmmParams(FuzzInput memory input) public view boundInputs(input) {
        (bool s1, bytes memory ret) =
            address(this).staticcall(abi.encodeCall(this._reference_computePreMarketParams, (toMarketState(input))));
        vm.assume(s1);
        MarketPreCompute memory result0 = abi.decode(ret, (MarketPreCompute));

        TokiSwap.PoolState memory state = toPoolStorage(input);
        ITokiHook.ImmutableParams memory immutables = toImmutables(input);
        TokiSwap.TokiAmmParams memory result1 = TokiSwap.computeAmmParams(state, immutables, toFeePcts(input));

        assertApproxEqRel(uint256(result0.totalAsset), uint256(result1.totalAssets), 0.000001e18, "total assets");
        assertApproxEqRel(result0.rateScalar, result1.rateScalar, 0.000001e18, "rate scalar");
        assertApproxEqRel(result0.rateAnchor, result1.rateAnchor, 0.000001e18, "rate anchor");
        assertApproxEqRel(result0.feeRate, result1.feeRateWad, 0.000001e18, "fee rate");
    }

    function _reference_computePreMarketParams(MarketState memory market)
        external
        view
        returns (MarketPreCompute memory)
    {
        return MarketMathCore.getMarketPreCompute(market, PYIndex.wrap(PY_INDEX_WAD), block.timestamp);
    }

    struct SwapResult {
        TokiSwap.PoolState state;
        int256 underlyingAmount;
        int256 principals;
        uint256 swapFee;
        uint256 feeToCuratorAndProtocol;
    }

    /// forge-config: default.fuzz.runs = 20000
    /// @dev Accepts `input` as memory so the boundInputs modifier's clamps persist into the body.
    function testFuzz_Swap_WhenPrincipalTokenSpecified(FuzzInput memory input, int256 amountSpecified)
        public
        view
        boundInputs(input)
    {
        amountSpecified = bound(amountSpecified, -input.totalPt.toInt256(), input.totalPt.toInt256());

        MarketState memory market;
        TokiSwap.PoolState memory prevState;
        SwapResult memory result;

        {
            (bool s, bytes memory ret) =
                address(this).staticcall(abi.encodeCall(this._reference_swap, (toMarketState(input), amountSpecified)));
            vm.assume(s);

            int256 syOut;
            uint256 syFee;
            uint256 syToReserve;
            (market, syOut, syFee, syToReserve) = abi.decode(ret, (MarketState, int256, uint256, uint256));

            prevState = toPoolStorage(input);
            result = _swap(input, amountSpecified >= 0, amountSpecified);

            // Check return values
            assertEq(result.principals, amountSpecified, "principals");

            if (FixedPointMathLib.abs(result.underlyingAmount) > 1e10) {
                assertApproxEqRel(result.underlyingAmount, syOut, 0.000001e18, "underlying amount");
            } else {
                assertApproxEqAbs(result.underlyingAmount, syOut, 1e5, "underlying amount");
            }

            if (result.swapFee > 1e10) {
                assertApproxEqRel(result.swapFee, syFee, 0.000001e18, "swap fee");
            } else {
                assertApproxEqAbs(result.swapFee, syFee, 1e5, "swap fee");
            }

            if (result.feeToCuratorAndProtocol > 1e10) {
                assertApproxEqRel(result.feeToCuratorAndProtocol, syToReserve, 0.000001e18, "fee to reserve");
            } else {
                assertApproxEqAbs(result.feeToCuratorAndProtocol, syToReserve, 1e5, "fee to reserve");
            }
        }

        // Check memory updates
        TokiSwap.PoolState memory state = result.state;
        if (FixedPointMathLib.abs(result.underlyingAmount) > 1e10) {
            assertApproxEqRel(uint256(market.totalPt), state.balances.value1(), 0.000001e18, "total pt");
            assertApproxEqRel(uint256(market.totalSy), state.balances.value0(), 0.000001e18, "total underlying");
        } else {
            assertApproxEqAbs(uint256(market.totalPt), state.balances.value1(), 1e5, "total pt");
            assertApproxEqAbs(uint256(market.totalSy), state.balances.value0(), 1e5, "total underlying");
        }
        assertApproxEqRel(
            TokiSwap.convertToExchangeRate(uint256(market.lastLnImpliedRate), input.expiry - block.timestamp),
            TokiSwap.convertToExchangeRate(uint256(state.lnImpliedRate), input.expiry - block.timestamp),
            0.0001e18,
            "ln implied rate"
        );

        if (amountSpecified > 0) {
            // Buy Principal Token
            assertEq(state.balances.value1(), prevState.balances.value1() - result.principals.abs(), "total pt (buy)");
            assertEq(
                state.balances.value0(),
                prevState.balances.value0() + result.underlyingAmount.abs() - result.feeToCuratorAndProtocol,
                "total underlying (buy)"
            );
        } else {
            // Sell Principal Token
            assertEq(state.balances.value1(), prevState.balances.value1() + result.principals.abs(), "total pt (sell)");
            assertEq(
                state.balances.value0(),
                prevState.balances.value0() - result.underlyingAmount.abs() - result.feeToCuratorAndProtocol,
                "total underlying (sell)"
            );
        }

        uint256 feesAccumulated = prevState.fees.value0() + prevState.fees.value1() + result.feeToCuratorAndProtocol;
        assertApproxEqRel(state.fees.value0() + state.fees.value1(), feesAccumulated, 0.000001e18, "fees accumulated");
    }

    function testFuzz_SwapExactUnderlyingIn(FuzzInput memory input, int256 amountSpecified)
        public
        view
        boundInputs(input)
    {
        amountSpecified = bound(amountSpecified, -input.totalPt.toInt256() * 100, -1000); // Negative

        TokiSwap.PoolState memory prevState = toPoolStorage(input);
        SwapResult memory result;
        {
            (bool s, bytes memory ret) =
                address(this).staticcall(abi.encodeCall(this._swap, (input, true, amountSpecified)));
            vm.assume(s);
            result = abi.decode(ret, (SwapResult));
        }
        TokiSwap.PoolState memory state = result.state;

        // Check return values
        assertGe(result.underlyingAmount, amountSpecified, "underlying amount");
        assertApproxEqRel(
            result.underlyingAmount,
            amountSpecified,
            TokiSwap.DEFAULT_BINSEARCH_EPSILON,
            "underlying amount approximate"
        );

        if (amountSpecified > 0) {
            // Buy underlying
            assertEq(state.balances.value1(), prevState.balances.value1() + result.principals.abs(), "total pt (buy)");
            assertEq(
                state.balances.value0(),
                prevState.balances.value0() - result.underlyingAmount.abs() - result.feeToCuratorAndProtocol,
                "total underlying (buy)"
            );
        } else {
            // Sell underlying
            assertEq(state.balances.value1(), prevState.balances.value1() - result.principals.abs(), "total pt (sell)");
            assertEq(
                state.balances.value0(),
                prevState.balances.value0() + result.underlyingAmount.abs() - result.feeToCuratorAndProtocol,
                "total underlying (sell)"
            );
        }

        uint256 feesAccumulated = prevState.fees.value0() + prevState.fees.value1() + result.feeToCuratorAndProtocol;
        assertApproxEqRel(state.fees.value0() + state.fees.value1(), feesAccumulated, 0.000001e18, "fees accumulated");
    }

    function _reference_swap(MarketState memory market, int256 amountSpecified)
        external
        view
        returns (MarketState memory, uint256, uint256, uint256)
    {
        (int256 netSyToAccount, int256 netSyFee, int256 netSyToReserve) =
            MarketMathCore.executeTradeCore(market, PYIndex.wrap(PY_INDEX_WAD), amountSpecified, block.timestamp);
        return (market, netSyToAccount.toUint256(), netSyFee.toUint256(), netSyToReserve.toUint256());
    }

    function _swap(FuzzInput memory input, bool zeroForOne, int256 amountSpecified)
        public
        view
        returns (SwapResult memory)
    {
        TokiSwap.PoolState memory state = toPoolStorage(input);
        ITokiHook.ImmutableParams memory immutables = toImmutables(input);
        FeePctsPool feePcts = toFeePcts(input);
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
        (int256 underlyingAmount, int256 principals, uint256 swapFee, uint256 feeToCuratorAndProtocol) =
            TokiSwap.swap(state, immutables, params, emptyApproximationParams(), feePcts);

        return SwapResult({
            state: state,
            underlyingAmount: underlyingAmount,
            principals: principals,
            swapFee: swapFee,
            feeToCuratorAndProtocol: feeToCuratorAndProtocol
        });
    }

    /// forge-config: default.fuzz.runs = 1000
    /// @dev Under the same conditions, if fee is charged, the amount of underlying received by user should be less when selling PT
    /// @dev If fee is charged, the amount of underlying spent by user should be more when buying PT
    function testFuzz_FeesCharged(FuzzInput memory input, int256 amountSpecified) public view boundInputs(input) {
        if (amountSpecified > 0) {
            amountSpecified = bound(amountSpecified, 100000, type(int96).max); // Large enough to avoid rounding down to zero
        } else {
            amountSpecified = bound(amountSpecified, type(int96).min, -100000);
        }
        bool zeroForOne = amountSpecified >= 0; // exact in/out of PT

        SwapResult memory resultNoFee;
        {
            input.ammFeeParams = 0;
            input.reserveFeePct = 0;

            (bool s, bytes memory ret) =
                address(this).staticcall(abi.encodeCall(this._swap, (input, zeroForOne, amountSpecified)));
            vm.assume(s);
            resultNoFee = abi.decode(ret, (SwapResult));
        }

        SwapResult memory resultWithFee;
        {
            input.ammFeeParams =
                uint128(lnWad(1.05e18).toUint256() * uint256(Constants.TOKI_SWAP_FEE_SCALE) / Constants.WAD);
            input.reserveFeePct = 20;

            (bool s, bytes memory ret) =
                address(this).staticcall(abi.encodeCall(this._swap, (input, zeroForOne, amountSpecified)));
            vm.assume(s);
            resultWithFee = abi.decode(ret, (SwapResult));
        }

        if (amountSpecified > 0) {
            // Buy PT
            // The user should spend fewer underlying tokens when fee is not charged
            assertLt(
                resultNoFee.underlyingAmount.abs(), resultWithFee.underlyingAmount.abs(), "underlying amount (buy PT)"
            );
            assertLt(resultNoFee.state.balances.value0(), resultWithFee.state.balances.value0(), "balance0 (buy PT)");
            assertEq(
                resultWithFee.state.balances.value0(),
                resultNoFee.state.balances.value0() + resultWithFee.swapFee - resultWithFee.feeToCuratorAndProtocol,
                "fee (buy PT)"
            );
        } else {
            // Sell PT
            // The user should receive more underlying tokens when fee is not charged
            assertGt(
                resultNoFee.underlyingAmount.abs(), resultWithFee.underlyingAmount.abs(), "underlying amount (sell PT)"
            );
            assertLt(resultNoFee.state.balances.value0(), resultWithFee.state.balances.value0(), "balance0 (sell PT)");
            assertEq(
                resultWithFee.state.balances.value0(),
                resultNoFee.state.balances.value0() + resultWithFee.swapFee - resultWithFee.feeToCuratorAndProtocol,
                "fee (sell PT)"
            );
        }

        assertEq(resultNoFee.swapFee, 0, "swap fee");
        assertEq(resultNoFee.feeToCuratorAndProtocol, 0, "fee");
    }

    /// forge-config: default.fuzz.runs = 2000
    /// @dev Round trip buy->sell or sell->buy should not benefit user
    function testFuzz_RoundTrip_Swap(FuzzInput memory input, int256 amountSpecified) public view boundInputs(input) {
        if (amountSpecified > 0) {
            amountSpecified = bound(amountSpecified, 0, type(int96).max); // Large enough to avoid rounding down to zero
        } else {
            amountSpecified = bound(amountSpecified, type(int96).min, 0);
        }
        // Arrange: Fee zero
        input.ammFeeParams = 0;
        input.reserveFeePct = 0;

        bool zeroForOne = amountSpecified >= 0; // exact in/out of PT

        // Act:
        // Swap Exact in/out of PT
        (bool s, bytes memory ret) =
            address(this).staticcall(abi.encodeCall(this._swap, (input, zeroForOne, amountSpecified)));
        vm.assume(s);
        SwapResult memory result = abi.decode(ret, (SwapResult));

        // Round trip of exact in/out of PT
        (bool s2, bytes memory ret2) =
            address(this).staticcall(abi.encodeCall(this._swap, (input, !zeroForOne, -amountSpecified)));
        vm.assume(s2);
        SwapResult memory result2 = abi.decode(ret2, (SwapResult));

        if (zeroForOne) {
            // Round trip: Buy exact PT -> Sell exact PT
            assertLe(
                result2.underlyingAmount.abs(), result.underlyingAmount.abs(), "Underlying amount net loss (buy PT)"
            );
        } else {
            // Round trip: Sell exact PT -> Buy exact PT
            assertGe(
                result2.underlyingAmount.abs(), result.underlyingAmount.abs(), "Underlying amount net loss (sell PT)"
            );
        }
    }

    function test_InitialImpliedRate() public view {
        _test_InitialImpliedRate(
            FuzzInput({
                expiry: block.timestamp + 365 days,
                scalarRoot: 131e18,
                totalSy: 1e18,
                totalPt: 1.3238e18,
                lastLnImpliedRate: 0,
                rateAnchor: 11e18,
                rateScalar: 501e18,
                ammFeeParams: uint128(lnWad(1.01e18).toUint256() * uint256(Constants.TOKI_SWAP_FEE_SCALE) / Constants.WAD),
                reserveFeePct: 10,
                splitFeeBps: 5000
            })
        );
        _test_InitialImpliedRate(
            FuzzInput({
                expiry: block.timestamp + 90 days,
                scalarRoot: 118e18,
                totalSy: 1_310_901e6,
                totalPt: 1_532_038e6,
                lastLnImpliedRate: 0,
                rateAnchor: 301e18,
                rateScalar: 801e18,
                ammFeeParams: uint128(
                    lnWad(1.0921184314398912e18).toUint256() * uint256(Constants.TOKI_SWAP_FEE_SCALE) / Constants.WAD
                ),
                reserveFeePct: 11,
                splitFeeBps: Constants.BASIS_POINTS
            })
        );
        _test_InitialImpliedRate(
            FuzzInput({
                expiry: block.timestamp + 180 days,
                scalarRoot: 18e18,
                totalSy: 121_832_298_310_901,
                totalPt: 138_103_320_532_038,
                lastLnImpliedRate: 0,
                rateAnchor: 819.389438491038931e18,
                rateScalar: 389.3813319831329381e18,
                ammFeeParams: uint128(
                    lnWad(1.083103913011318e18).toUint256() * uint256(Constants.TOKI_SWAP_FEE_SCALE) / Constants.WAD
                ),
                reserveFeePct: 500,
                splitFeeBps: Constants.BASIS_POINTS
            })
        );
    }

    function _test_InitialImpliedRate(FuzzInput memory input) internal view {
        MarketState memory market = toMarketState(input);
        MarketMathCore.setInitialLnImpliedRate(market, PYIndex.wrap(PY_INDEX_WAD), input.rateAnchor, block.timestamp);

        TokiSwap.PoolState memory state = toPoolStorage(input);
        ITokiHook.ImmutableParams memory immutables = toImmutables(input);
        uint256 result = TokiSwap.computeInitialLnImpliedRate(state, immutables);
        assertApproxEqRel(result, market.lastLnImpliedRate, 0.0000001e18, "initial implied rate");
    }

    /// @dev For some reason, when buying 1 unit of principal token is not possible, the computed maxPtOut is not 0.
    /// forge-config: default.allow_internal_expect_revert = true
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MaxPtOut(FuzzInput memory input) public view boundInputs(input) {
        TokiSwap.PoolState memory state = toPoolStorage(input);
        ITokiHook.ImmutableParams memory immutables = toImmutables(input);
        FeePctsPool feePcts = toFeePcts(input);
        TokiSwap.TokiAmmParams memory ammParams = TokiSwap.computeAmmParams(state, immutables, feePcts);

        (bool s, bytes memory ret) = address(this).staticcall(abi.encodeCall(this._getMaxPtOut, (state, ammParams)));
        vm.assume(s);

        int256 maxPtOut = abi.decode(ret, (int256));
        int256 realMaxPtOut = binarySearchMaxPtOut(input);

        assertGe(maxPtOut, 0, "maxPtOut should be positive");

        // Swap should revert or effective exchange rate should be really close to 1
        try this._swap(input, true, maxPtOut * TokiSwap.IWAD / TokiSwap.MAX_PT_CALCULATION_PRECISION) {
            // Barely possible to buy principal tokens
            assertApproxEqRel(
                maxPtOut * TokiSwap.IWAD / TokiSwap.MAX_PT_CALCULATION_PRECISION,
                realMaxPtOut,
                0.01e18,
                "maxPtOut should be equal (swap succeeded)"
            );
        } catch (bytes memory reason) {
            // If exchange rate is close to 1, it's okay
            if (bytes4(reason) == Errors.TokiSwap_ImpliedRateZero.selector) {
                // Exchange rate is close to 1, it's what we aim for
                // In some cases, realMaxPtOut vs maxPtOut is over 5% different, so we don't assert
                return;
            } else if (bytes4(reason) == Errors.TokiSwap_ExchangeRateBelowOne.selector) {
                int256 exchangeRate = abi.decode(reason.slice(4), (int256));
                assertLe(exchangeRate, TokiSwap.IWAD, "exchange rate < 1");
                // In some cases, realMaxPtOut vs maxPtOut is over 5% different, so we don't assert
                return;
            } else if (bytes4(reason) == FixedPointMathLib.LnWadUndefined.selector) {
                // ok
            } else if (bytes4(reason) == Errors.TokiSwap_InsufficientPrincipalsLiquidity.selector) {
                // ok
            } else {
                revert("Swap should revert with unexpected reason");
            }

            // Assertions are not reliable for small amounts
            if (realMaxPtOut < 1_000) {
                return;
            }

            assertApproxEqRel(
                maxPtOut * TokiSwap.IWAD / TokiSwap.MAX_PT_CALCULATION_PRECISION,
                realMaxPtOut,
                0.01e18,
                "maxPtOut should be equal (swap failed)"
            );
        }
    }

    /// @dev For some reason, when selling 1 unit of principal token is not possible, the computed maxPtIn is not 0.
    /// forge-config: default.allow_internal_expect_revert = true
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MaxPtIn(FuzzInput memory input) public view boundInputs(input) {
        TokiSwap.PoolState memory state = toPoolStorage(input);
        ITokiHook.ImmutableParams memory immutables = toImmutables(input);
        FeePctsPool feePcts = toFeePcts(input);
        TokiSwap.TokiAmmParams memory ammParams = TokiSwap.computeAmmParams(state, immutables, feePcts);

        (bool s, bytes memory ret) = address(this).staticcall(abi.encodeCall(this._getMaxPtIn, (state, ammParams)));
        vm.assume(s);

        int256 maxPtIn = abi.decode(ret, (int256));
        int256 realMaxPtIn = binarySearchMaxPtIn(input);

        assertLe(maxPtIn, 0, "maxPtIn should be negative");

        // Swap should revert or effective exchange rate should be really close to 1
        try this._swap(input, false, maxPtIn) returns (SwapResult memory /* result */ ) {
            assertLe(maxPtIn.abs(), realMaxPtIn.abs(), "maxPtIn should be less than realMaxPtIn (swap succeeded)");
            // Note It's not accurate enough to assert
            // assertApproxEqRel(maxPtIn, realMaxPtIn, 0.01e18, "maxPtIn should be equal (swap succeeded)");
        } catch (bytes memory reason) {
            if (bytes4(reason) == Errors.TokiSwap_MarketProportionTooHigh.selector) {
                // ok
            } else if (bytes4(reason) == FixedPointMathLib.LnWadUndefined.selector) {
                // ok
            } else {
                revert("Swap should revert with unexpected reason");
            }

            assertApproxEqRel(maxPtIn, realMaxPtIn, 0.01e18, "maxPtIn should be equal (swap failed)");
        }
    }

    // function testFuzz_ReferenceMaxPtIn(FuzzInput memory input) public boundInputs(input) {
    //     TokiSwap.PoolState memory state = toPoolStorage(input);
    //     ITokiHook.ImmutableParams memory immutables = toImmutables(input);
    //     FeePctsPool feePcts = toFeePcts(input);
    //     TokiSwap.TokiAmmParams memory ammParams = TokiSwap.computeAmmParams(state, immutables, feePcts);

    //     (bool s, bytes memory ret) = address(this).staticcall(abi.encodeCall(this._getMaxPtIn, (state, ammParams)));
    //     vm.assume(s);

    //     int256 maxPtIn = abi.decode(ret, (int256));
    //     int256 realMaxPtIn = binarySearchMaxPtIn(input);
    //     assertLe(maxPtIn, 0, "maxPtIn should be negative");

    //     MarketState memory marketState = toMarketState(input);
    //     MarketPreCompute memory comp =
    //         MarketMathCore.getMarketPreCompute(marketState, PYIndex.wrap(PY_INDEX_WAD), block.timestamp);
    //     uint256 referenceMaxPtIn = MarketApproxPtInLibV2.calcMaxPtIn(marketState, comp);

    //     assertApproxEqRel(maxPtIn, -referenceMaxPtIn.toInt256(), 0.01e18, "reference maxPtIn should be equal");
    //     // assertApproxEqRel(maxPtIn, realMaxPtIn, 0.01e18, "real maxPtIn should be equal");
    // }

    /// @notice Make sure reference implementation is correct
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BinarySearchMaxPtOut(FuzzInput memory input) public boundInputs(input) {
        int256 max = binarySearchMaxPtOut(input);
        assertGe(max, 0, "maxPtOut should be positive");
        try this._swap(input, true, max) {
            // Literally impossible to buy more Principal Tokens
            vm.expectRevert();
            this._swap(input, true, max + 2);
        } catch {
            // Slightly possible to buy less Principal Tokens
            if (max - 2 > 0) {
                this._swap(input, true, max - 2);
            }
        }
    }

    /// @notice Make sure reference implementation is correct
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_BinarySearchMaxPtIn(FuzzInput memory input) public boundInputs(input) {
        int256 max = binarySearchMaxPtIn(input);
        assertLe(max, 0, "maxPtIn should be negative");

        try this._swap(input, false, max) {
            // Literally impossible to sell more Principal Tokens
            vm.expectRevert();
            this._swap(input, false, max - 2);
        } catch {
            // Slightly possible to sell less Principal Tokens
            if (max + 2 < 0) {
                this._swap(input, false, max + 2);
            }
        }
    }

    /// @notice Reference implementation to find out actual max PT that can be bought
    function binarySearchMaxPtOut(FuzzInput memory input) public view returns (int256) {
        // Binary search to find max PT that can be bought
        int256 low = 0;
        int256 high = input.totalPt.toInt256();
        int256 lastValidAmount = 0;

        while (low <= high) {
            int256 mid = (low + high) / 2;

            try this._swap(input, true, mid) {
                // This amount worked, try higher
                lastValidAmount = mid;
                low = mid + 1;
            } catch {
                // Too high, try lower
                high = mid - 1;
            }
        }
        return lastValidAmount;
    }

    /// @notice Reference implementation to find out actual max PT that can be bought
    function binarySearchMaxPtIn(FuzzInput memory input) public view returns (int256) {
        // Binary search to find max PT that can be sold
        int256 low = 0;
        int256 high = input.totalPt.toInt256();
        int256 lastValidAmount = 0;

        while (low <= high) {
            int256 mid = (low + high) / 2;

            try this._swap(input, false, -mid) {
                // This amount worked, try higher
                lastValidAmount = -mid;
                low = mid + 1;
            } catch {
                // Too high, try lower
                high = mid - 1;
            }
        }
        return lastValidAmount;
    }

    function _getMaxPtOut(TokiSwap.PoolState memory state, TokiSwap.TokiAmmParams memory ammParams)
        external
        pure
        returns (int256)
    {
        return TokiSwap.computeMaxPtOut(state, ammParams);
    }

    function _getMaxPtIn(TokiSwap.PoolState memory state, TokiSwap.TokiAmmParams memory ammParams)
        external
        pure
        returns (int256)
    {
        return TokiSwap.computeMaxPtIn(state, ammParams);
    }

    function emptyApproximationParams() public pure returns (ApproximationParams memory params) {}
}
