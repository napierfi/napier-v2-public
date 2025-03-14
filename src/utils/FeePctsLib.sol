// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {FeePcts} from "../Types.sol";

library FeePctsLib {
    uint256 private constant FEE_MASK = 0xFFFF; // 16 bits mask
    uint256 private constant SPLIT_RATIO_OFFSET = 0;

    function getSplitPctBps(FeePcts self) internal pure returns (uint16) {
        return uint16(FeePcts.unwrap(self));
    }

    function getIssuanceFeePctBps(FeePcts self) internal pure returns (uint16) {
        return uint16(FeePcts.unwrap(self) >> 16);
    }

    function getPerformanceFeePctBps(FeePcts self) internal pure returns (uint16) {
        return uint16(FeePcts.unwrap(self) >> 32);
    }

    function getRedemptionFeePctBps(FeePcts self) internal pure returns (uint16) {
        return uint16(FeePcts.unwrap(self) >> 48);
    }

    function getPostSettlementFeePctBps(FeePcts self) internal pure returns (uint16) {
        return uint16(FeePcts.unwrap(self) >> 64);
    }

    function unpack(FeePcts self)
        internal
        pure
        returns (
            uint16 splitFeePct,
            uint16 issuanceFeePct,
            uint16 performanceFeePct,
            uint16 redemptionFeePct,
            uint16 postSettlementFeePct
        )
    {
        uint256 raw = FeePcts.unwrap(self);

        splitFeePct = uint16(raw);
        issuanceFeePct = uint16(raw >> 16);
        performanceFeePct = uint16(raw >> 32);
        redemptionFeePct = uint16(raw >> 48);
        postSettlementFeePct = uint16(raw >> 64);

        return (splitFeePct, issuanceFeePct, performanceFeePct, redemptionFeePct, postSettlementFeePct);
    }

    function pack(
        uint16 splitFeePct,
        uint16 issuanceFeePct,
        uint16 performanceFeePct,
        uint16 redemptionFeePct,
        uint16 postSettlementFeePct
    ) internal pure returns (FeePcts) {
        return FeePcts.wrap(
            (uint256(postSettlementFeePct) << 64 | uint256(redemptionFeePct) << 48) | (uint256(performanceFeePct) << 32)
                | (uint256(issuanceFeePct) << 16) | uint256(splitFeePct)
        );
    }

    function updateSplitFeePct(FeePcts self, uint16 splitFeePct) internal pure returns (FeePcts) {
        return
            FeePcts.wrap((FeePcts.unwrap(self) & ~(FEE_MASK << SPLIT_RATIO_OFFSET)) | (uint256(splitFeePct) & FEE_MASK));
    }
}
