// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {Test} from "forge-std/src/Test.sol";

import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";

contract FeePctsLibTest is Test {
    struct Values {
        uint16 splitFeePct;
        uint16 issuanceFeePct;
        uint16 performanceFeePct;
        uint16 redemptionFeePct;
        uint16 postSettlementFeePct;
    }

    function testFuzz_PackUnPack(Values memory v) public pure {
        FeePcts pcts = FeePctsLib.pack(
            v.splitFeePct, v.issuanceFeePct, v.performanceFeePct, v.redemptionFeePct, v.postSettlementFeePct
        );
        (
            uint16 splitFeePct,
            uint16 issuanceFeePct,
            uint16 performanceFeePct,
            uint16 redemptionFeePct,
            uint16 postSettlementFeePct
        ) = FeePctsLib.unpack(pcts);
        assertEq(splitFeePct, v.splitFeePct, "splitFeePct");
        assertEq(issuanceFeePct, v.issuanceFeePct, "issuanceFeePct");
        assertEq(performanceFeePct, v.performanceFeePct, "performanceFeePct");
        assertEq(redemptionFeePct, v.redemptionFeePct, "redemptionFeePct");
        assertEq(postSettlementFeePct, v.postSettlementFeePct, "postSettlementFeePct");
    }

    function testFuzz_Getters(Values memory v) external pure {
        FeePcts pcts = FeePctsLib.pack(
            v.splitFeePct, v.issuanceFeePct, v.performanceFeePct, v.redemptionFeePct, v.postSettlementFeePct
        );
        assertEq(FeePctsLib.getSplitPctBps(pcts), v.splitFeePct, "getSplitPctBps");
        assertEq(FeePctsLib.getIssuanceFeePctBps(pcts), v.issuanceFeePct, "getIssuanceFeePctBps");
        assertEq(FeePctsLib.getPerformanceFeePctBps(pcts), v.performanceFeePct, "getPerformanceFeePctBps");
        assertEq(FeePctsLib.getRedemptionFeePctBps(pcts), v.redemptionFeePct, "getRedemptionFeePctBps");
        assertEq(FeePctsLib.getPostSettlementFeePctBps(pcts), v.postSettlementFeePct, "getPostSettlementFeePctBps");
    }

    function test_PackUnpack() public pure {
        Values memory v = Values({
            splitFeePct: 1000,
            issuanceFeePct: 2000,
            performanceFeePct: 30,
            redemptionFeePct: 40,
            postSettlementFeePct: 50
        });
        testFuzz_PackUnPack(v);
    }

    function testFuzz_UpdateSplitFeePct(Values memory v, uint16 newSplitFeePct) public pure {
        FeePcts pcts = FeePctsLib.pack(
            v.splitFeePct, v.issuanceFeePct, v.performanceFeePct, v.redemptionFeePct, v.postSettlementFeePct
        );
        FeePcts updated = FeePctsLib.updateSplitFeePct(pcts, newSplitFeePct);
        assertEq(FeePctsLib.getSplitPctBps(updated), newSplitFeePct, "feeSplitRatio");
        assertEq(FeePctsLib.getIssuanceFeePctBps(updated), v.issuanceFeePct, "issuanceFeePct");
        assertEq(FeePctsLib.getPerformanceFeePctBps(updated), v.performanceFeePct, "performanceFeePct");
        assertEq(FeePctsLib.getRedemptionFeePctBps(updated), v.redemptionFeePct, "redemptionFeePct");
        assertEq(FeePctsLib.getPostSettlementFeePctBps(updated), v.postSettlementFeePct, "postSettlementFeePct");
    }
}
