// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {FeeParameters, FeePcts} from "../Types.sol";
import {FeePctsLib} from "../utils/FeePctsLib.sol";
import {Errors} from "../Errors.sol";
import {Factory} from "../Factory.sol";
import {BaseModule} from "./BaseModule.sol";

/// @notice FeeModule is responsible for managing fee settings
abstract contract FeeModule is BaseModule {
    function getFeePcts() external view virtual returns (FeePcts);
}

/// @notice ConstantFeeModule is an implementation of FeeModule where all fees except split ratio are set once at initialization
contract ConstantFeeModule is FeeModule {
    using SafeCastLib for uint256;

    bytes32 public constant override VERSION = "2.0.0";

    uint256 private constant MAX_FEE_BPS = 10_000;
    uint256 private constant MAX_SPLIT_RATIO_BPS = 9_500;

    FeePcts private s_feePcts;

    /// @notice Initialize the fee module with the given fee parameters
    /// @dev The fee parameters are encoded as follows: abi.encode(principalToken, abi.encode(FeePcts))
    function initialize() external override initializer {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(address(this)), (address, bytes));

        if (args.length != 0x20) revert Errors.FeeModule_InvalidFeeParam();
        FeePcts feePcts = abi.decode(args, (FeePcts));

        (uint16 splitFee, uint16 issuanceFee, uint16 performanceFee, uint16 redemptionFee, uint16 postSettlementFee) =
            FeePctsLib.unpack(feePcts);

        if (splitFee != Factory(msg.sender).DEFAULT_SPLIT_RATIO_BPS().toUint16()) {
            revert Errors.FeeModule_SplitFeeMismatchDefault();
        }
        if (issuanceFee > MAX_FEE_BPS) {
            revert Errors.FeeModule_IssuanceFeeExceedsMaximum();
        }
        if (performanceFee > MAX_FEE_BPS) {
            revert Errors.FeeModule_PerformanceFeeExceedsMaximum();
        }
        if (redemptionFee > MAX_FEE_BPS) {
            revert Errors.FeeModule_RedemptionFeeExceedsMaximum();
        }
        if (postSettlementFee > MAX_FEE_BPS) {
            revert Errors.FeeModule_PostSettlementFeeExceedsMaximum();
        }
        s_feePcts = feePcts;
    }

    /// @notice Get the fee parameters
    /// @return The fee parameters
    function getFeePcts() public view override returns (FeePcts) {
        return s_feePcts;
    }

    /// @notice Get the fee parameters
    /// @param param The fee parameters to get
    /// @return The fee parameters
    function getFeeParams(FeeParameters param) external view returns (uint256) {
        if (param == FeeParameters.FEE_SPLIT_RATIO) {
            return FeePctsLib.getSplitPctBps(s_feePcts);
        } else if (param == FeeParameters.ISSUANCE_FEE) {
            return FeePctsLib.getIssuanceFeePctBps(s_feePcts);
        } else if (param == FeeParameters.PERFORMANCE_FEE) {
            return FeePctsLib.getPerformanceFeePctBps(s_feePcts);
        } else if (param == FeeParameters.REDEMPTION_FEE) {
            return FeePctsLib.getRedemptionFeePctBps(s_feePcts);
        } else if (param == FeeParameters.POST_SETTLEMENT_FEE) {
            return FeePctsLib.getPostSettlementFeePctBps(s_feePcts);
        }
        revert Errors.FeeModule_InvalidFeeParam();
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
        s_feePcts = FeePctsLib.updateSplitFeePct(s_feePcts, _splitRatio.toUint16());
    }
}
