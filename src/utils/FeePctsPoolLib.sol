// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "../Types.sol";

library FeePctsPoolLib {
    uint256 private constant SPLIT_RATIO_MASK = 0xFFFF; // 16 bits mask
    uint256 private constant AMM_FEE_PARAMS_MASK = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF; // 128 bits mask
    uint256 private constant RESERVE_FEE_MASK = 0xFFFF; // 16 bits mask

    uint256 private constant SPLIT_RATIO_OFFSET = 0;
    uint256 private constant AMM_FEE_PARAMS_OFFSET = 16;
    uint256 private constant RESERVE_FEE_OFFSET = 144;

    function getSplitPctBps(FeePctsPool self) internal pure returns (uint16) {
        return uint16(FeePctsPool.unwrap(self));
    }

    function getAmmFeeParams(FeePctsPool self) internal pure returns (uint128) {
        return uint128(FeePctsPool.unwrap(self) >> AMM_FEE_PARAMS_OFFSET);
    }

    function getReserveFeePctBps(FeePctsPool self) internal pure returns (uint16) {
        return uint16(FeePctsPool.unwrap(self) >> RESERVE_FEE_OFFSET);
    }

    function unpack(FeePctsPool self)
        internal
        pure
        returns (uint16 splitFeePct, uint128 ammFeeParams, uint16 reserveFeePct)
    {
        uint256 raw = FeePctsPool.unwrap(self);

        splitFeePct = uint16(raw);
        ammFeeParams = uint128(raw >> AMM_FEE_PARAMS_OFFSET);
        reserveFeePct = uint16(raw >> RESERVE_FEE_OFFSET);
        return (splitFeePct, ammFeeParams, reserveFeePct);
    }

    function pack(uint16 splitFeePct, uint128 ammFeeParams, uint16 reserveFeePct) internal pure returns (FeePctsPool) {
        return FeePctsPool.wrap(
            (uint256(reserveFeePct) << RESERVE_FEE_OFFSET) | (uint256(ammFeeParams) << AMM_FEE_PARAMS_OFFSET)
                | uint256(splitFeePct)
        );
    }

    function updateSplitFeePct(FeePctsPool self, uint16 splitFeePct) internal pure returns (FeePctsPool) {
        return FeePctsPool.wrap(
            (FeePctsPool.unwrap(self) & ~(SPLIT_RATIO_MASK << SPLIT_RATIO_OFFSET))
                | (uint256(splitFeePct) & SPLIT_RATIO_MASK)
        );
    }
}
