// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Test} from "forge-std/src/Test.sol";

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {FeePctsPoolLib, FeePctsPool} from "src/utils/FeePctsPoolLib.sol";

contract FeePctsPoolLibTest is Test {
    struct Values {
        uint16 splitFeePct;
        uint16 reserveFeePct;
        uint128 ammFeeParams;
    }

    int256 public constant TOKI_SWAP_FEE_SCALE = 1e8;

    function test_MinimumAmmFeeParams() public pure {
        int256 ammFeeParams = FixedPointMathLib.lnWad(1.0e18) * TOKI_SWAP_FEE_SCALE / 1e18; // ln(1) == 0
        assertGe(ammFeeParams, 0, "Minimum amm fee params");
    }

    function test_MaximumAmmFeeParams() public pure {
        int256 ammFeeParams = FixedPointMathLib.lnWad(1.1e18) * TOKI_SWAP_FEE_SCALE / 1e18; // 10% lnFeeRateRoot
        assertLt(ammFeeParams, TOKI_SWAP_FEE_SCALE, "Maximum amm fee params");
    }

    function testFuzz_PackUnPack(Values memory v) public pure {
        FeePctsPool pcts = FeePctsPoolLib.pack(v.splitFeePct, v.ammFeeParams, v.reserveFeePct);
        (uint16 splitFeePct, uint128 ammFeeParams, uint16 reserveFeePct) = FeePctsPoolLib.unpack(pcts);
        assertEq(splitFeePct, v.splitFeePct, "splitFeePct");
        assertEq(reserveFeePct, v.reserveFeePct, "reserveFeePct");
        assertEq(ammFeeParams, v.ammFeeParams, "ammFeeParams");
    }

    function testFuzz_Getters(Values memory v) external pure {
        FeePctsPool pcts = FeePctsPoolLib.pack(v.splitFeePct, v.ammFeeParams, v.reserveFeePct);
        assertEq(FeePctsPoolLib.getSplitPctBps(pcts), v.splitFeePct, "getSplitPctBps");
        assertEq(FeePctsPoolLib.getAmmFeeParams(pcts), v.ammFeeParams, "getAmmFeeParams");
        assertEq(FeePctsPoolLib.getReserveFeePctBps(pcts), v.reserveFeePct, "getReserveFeePctBps");
    }

    function test_PackUnpack() public pure {
        Values memory v = Values({splitFeePct: 1000, reserveFeePct: 2000, ammFeeParams: 30});
        testFuzz_PackUnPack(v);
    }

    function testFuzz_UpdateSplitFeePct(Values memory v, uint16 newSplitFeePct) public pure {
        FeePctsPool pcts = FeePctsPoolLib.pack(v.splitFeePct, v.ammFeeParams, v.reserveFeePct);
        FeePctsPool updated = FeePctsPoolLib.updateSplitFeePct(pcts, newSplitFeePct);
        assertEq(FeePctsPoolLib.getSplitPctBps(updated), newSplitFeePct, "feeSplitRatio");
        assertEq(FeePctsPoolLib.getReserveFeePctBps(updated), v.reserveFeePct, "reserveFeePct");
        assertEq(FeePctsPoolLib.getAmmFeeParams(updated), v.ammFeeParams, "ammFeeParams");
    }

    function test_AmmFeeParamsEncode() public pure {
        uint128 encoded = uint128(uint256(FixedPointMathLib.lnWad(1.01e18)) * uint256(TOKI_SWAP_FEE_SCALE) / 1e18);
        FeePctsPool pool = FeePctsPoolLib.pack(1000, encoded, 2000);
        assertEq(FeePctsPoolLib.getAmmFeeParams(pool), encoded, "ammFeeParams encode roundtrip");
    }
}
