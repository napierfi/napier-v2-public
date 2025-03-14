// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {StdUtils} from "forge-std/src/Test.sol";

import "src/Types.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import {MockFeeModule} from "../mocks/MockFeeModule.sol";

abstract contract Helpers is StdUtils {
    function boundBps(uint256 value) internal pure returns (uint256) {
        return bound(value, 0, 10_000);
    }

    function setMockFeePcts(address feeModule, FeePcts v) internal {
        MockFeeModule(feeModule).setFeePcts(v);
    }

    function boundFeePcts(FeePcts v) internal pure returns (FeePcts) {
        (uint16 splitRatio, uint16 b, uint16 c, uint16 d, uint16 e) = FeePctsLib.unpack(v);
        splitRatio = uint16(boundBps(splitRatio));
        b = uint16(bound(b, 0, 2_000));
        c = uint16(bound(c, 0, 2_000));
        d = uint16(bound(d, 0, 2_000));
        e = uint16(bound(e, 0, 2_000));
        return FeePctsLib.pack(splitRatio, b, c, d, e);
    }

    function getSplitPctBps(FeePcts pcts) public pure returns (uint256) {
        return FeePctsLib.getSplitPctBps(pcts);
    }

    function getIssuanceFeePctBps(FeePcts pcts) public pure returns (uint256) {
        return FeePctsLib.getIssuanceFeePctBps(pcts);
    }

    function getPerformanceFeePctBps(FeePcts pcts) public pure returns (uint256) {
        return FeePctsLib.getPerformanceFeePctBps(pcts);
    }

    function getRedemptionFeePctBps(FeePcts pcts) public pure returns (uint256) {
        return FeePctsLib.getRedemptionFeePctBps(pcts);
    }

    function getPostSettlementFeePctBps(FeePcts pcts) public pure returns (uint256) {
        return FeePctsLib.getPostSettlementFeePctBps(pcts);
    }
}
