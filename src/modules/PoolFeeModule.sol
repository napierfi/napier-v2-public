// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../Types.sol";
import "../Errors.sol";
import {MAX_TOKI_SWAP_FEE_PARAMS, MAX_RESERVE_FEE_BPS} from "../Constants.sol";

import {FeePctsPoolLib} from "../utils/FeePctsPoolLib.sol";
import {Factory} from "../Factory.sol";
import {BaseModule} from "./BaseModule.sol";

/// @notice FeeModule is responsible for managing fee settings
abstract contract FeeModule is BaseModule {
    function getFeePcts() external view virtual returns (FeePctsPool);
}

/// @notice PoolFeeModule is an implementation of FeeModule where all fees except split ratio are set once at initialization
contract PoolFeeModule is FeeModule {
    using SafeCastLib for uint256;

    bytes32 public constant override VERSION = "2.0.0";

    uint256 private constant MAX_FEE_BPS = 10_000;
    uint256 private constant MAX_SPLIT_RATIO_BPS = 9_500;

    FeePctsPool private s_feePcts;

    event FeeSplitRatioUpdated(uint16 oldSplitRatioBps, uint16 newSplitRatioBps);

    /// @notice Initialize the fee module with the given fee parameters
    /// @dev The fee parameters are encoded as follows: abi.encode(principalToken, abi.encode(FeePctsPool))
    function initialize() external override initializer {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(address(this)), (address, bytes));

        if (args.length != 0x20) revert Errors.PoolFeeModule_InvalidFeeParam();
        FeePctsPool feePcts = abi.decode(args, (FeePctsPool));

        (uint16 splitFee, uint128 ammFeeParams, uint16 reserveFee) = FeePctsPoolLib.unpack(feePcts);

        if (splitFee != Factory(msg.sender).DEFAULT_SPLIT_RATIO_BPS().toUint16()) {
            revert Errors.FeeModule_SplitFeeMismatchDefault();
        }
        // TokiPool configs - ammFeeParams stores ln(feeRateRoot) e.g. ln(1.01) for 1% fee
        if (ammFeeParams > MAX_TOKI_SWAP_FEE_PARAMS) {
            revert Errors.PoolFeeModule_FeeExceedsMaximum();
        }
        if (reserveFee > MAX_RESERVE_FEE_BPS) {
            revert Errors.PoolFeeModule_ReserveFeeExceedsMaximum();
        }
        s_feePcts = feePcts;
    }

    /// @notice Get the fee parameters
    /// @return The fee parameters
    function getFeePcts() public view override returns (FeePctsPool) {
        return s_feePcts;
    }

    /// @notice Only FeeManager can update the fee split ratio
    /// @param _splitRatio The new fee split ratio
    /// @dev The split ratio is the percentage of the fee that is split between the principalToken and the issuer
    function updateFeeSplitRatio(uint256 _splitRatio) external restrictedBy(i_factory().i_accessManager()) {
        if (_splitRatio > MAX_SPLIT_RATIO_BPS) {
            revert Errors.FeeModule_SplitFeeExceedsMaximum();
        }
        if (_splitRatio == 0) {
            revert Errors.FeeModule_SplitFeeTooLow();
        }
        uint16 oldSplitRatio = FeePctsPoolLib.getSplitPctBps(s_feePcts);
        uint16 newSplitRatio = _splitRatio.toUint16();
        s_feePcts = FeePctsPoolLib.updateSplitFeePct(s_feePcts, newSplitRatio);
        emit FeeSplitRatioUpdated(oldSplitRatio, newSplitRatio);
    }
}
