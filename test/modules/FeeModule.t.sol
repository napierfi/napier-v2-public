// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ConstantFeeModule, FeeModule} from "src/modules/FeeModule.sol";
import {FeePcts, FeeParameters} from "src/Types.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import "src/Constants.sol" as Constants;
import {AccessManager} from "src/modules/AccessManager.sol";
import {MockFactory} from "../mocks/MockFactory.sol";
import {MockPrincipalToken} from "../mocks/MockPrincipalToken.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

contract ConstantFeeModuleTest is Test {
    using SafeCastLib for uint256;

    ConstantFeeModule public feeModuleImplementation;
    FeeModule public feeModule;
    FeePcts public initialFeePcts;
    MockFactory public mockFactory;
    address public mockAccessManager;

    MockPrincipalToken public mockPrincipalToken;

    /// @dev FeeModule makes a call to `msg.sender` on initialization
    uint16 public constant DEFAULT_SPLIT_RATIO_BPS = Constants.DEFAULT_SPLIT_RATIO_BPS;

    function setUp() public {
        // Deploy mock contracts
        mockAccessManager = makeAddr("mockAccessManager");
        mockFactory = new MockFactory(mockAccessManager);
        mockPrincipalToken = new MockPrincipalToken(mockFactory);
        // Deploy the ConstantFeeModule implementation
        feeModuleImplementation = new ConstantFeeModule();

        // Set initial fee parameters
        initialFeePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 100, 200, 50, 10000); // default split, 1% issuance, 2% performance, 0.5% redemption

        // Deploy the FeeModule instance using LibClone
        bytes memory customArgs = abi.encode(initialFeePcts);
        cloneFeeModule(customArgs);
        feeModule.initialize();
    }

    function cloneFeeModule(bytes memory customArgs) public {
        bytes memory args = abi.encode(mockPrincipalToken, customArgs);
        address instance = LibClone.clone(address(feeModuleImplementation), args);
        feeModule = FeeModule(instance);
    }

    function test_InitialFeeParameters() public view {
        FeePcts feePcts = feeModule.getFeePcts();
        assertEq(FeePctsLib.getSplitPctBps(feePcts), Constants.DEFAULT_SPLIT_RATIO_BPS, "Incorrect split ratio");
        assertEq(FeePctsLib.getIssuanceFeePctBps(feePcts), 100, "Incorrect issuance fee");
        assertEq(FeePctsLib.getPerformanceFeePctBps(feePcts), 200, "Incorrect performance fee");
        assertEq(FeePctsLib.getRedemptionFeePctBps(feePcts), 50, "Incorrect redemption fee");
    }

    function test_UpdateFeeSplitRatioBasic() public {
        // Simulate being called from the Factory
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(this),
                address(feeModule),
                ConstantFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(true)
        );
        ConstantFeeModule(address(feeModule)).updateFeeSplitRatio(6000);

        FeePcts updatedFeePcts = feeModule.getFeePcts();
        assertEq(FeePctsLib.getSplitPctBps(updatedFeePcts), 6000, "Split ratio not updated correctly");
    }

    function test_RevertWhen_UpdateFeeSplitRatioUnauthorized() public {
        vm.prank(address(0xdead));
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(0xdead),
                address(feeModule),
                ConstantFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(false)
        );
        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        ConstantFeeModule(address(feeModule)).updateFeeSplitRatio(6000);
    }

    function test_RevertWhen_UpdateFeeSplitRatioExceedsMaximum() public {
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(this),
                address(feeModule),
                ConstantFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(true)
        );
        vm.expectRevert(Errors.FeeModule_SplitFeeExceedsMaximum.selector);
        ConstantFeeModule(address(feeModule)).updateFeeSplitRatio(Constants.BASIS_POINTS + 1);
    }

    function test_RevertWhen_VerifyArgsInvalidLength() public {
        // Deploy a new instance with invalid args length
        bytes memory invalidArgs = abi.encode(""); // Only encode the principalToken address, omitting the FeePcts
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_InvalidFeeParam.selector);
        feeModule.initialize();
    }

    function test_VerifyArgsValidLength() public {
        bytes memory validArgs = abi.encode(initialFeePcts);
        cloneFeeModule(validArgs);

        // This should not revert
        feeModule.initialize();
    }

    function test_RevertWhen_VerifyArgsSplitFeeMismatchDefault() public {
        uint16 invalidSplitPctBps = Constants.DEFAULT_SPLIT_RATIO_BPS / 2 + 1;
        FeePcts invalidFeePcts = FeePctsLib.pack(invalidSplitPctBps, 100, 200, 50, 100);
        bytes memory invalidArgs = abi.encode(invalidFeePcts);
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_SplitFeeMismatchDefault.selector);
        feeModule.initialize();
    }

    function test_RevertWhen_VerifyArgsIssuanceFeeExceedsMaximum() public {
        FeePcts invalidFeePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 10001, 200, 50, 100);
        bytes memory invalidArgs = abi.encode(invalidFeePcts);
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_IssuanceFeeExceedsMaximum.selector);
        feeModule.initialize();
    }

    function test_RevertWhen_VerifyArgsPerformanceFeeExceedsMaximum() public {
        FeePcts invalidFeePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 100, 10001, 50, 0);
        bytes memory invalidArgs = abi.encode(invalidFeePcts);
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_PerformanceFeeExceedsMaximum.selector);
        feeModule.initialize();
    }

    function test_RevertWhen_VerifyArgsRedemptionFeeExceedsMaximum() public {
        FeePcts invalidFeePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 100, 200, 10001, 0);
        bytes memory invalidArgs = abi.encode(invalidFeePcts);
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_RedemptionFeeExceedsMaximum.selector);
        feeModule.initialize();
    }

    function test_RevertWhen_VerifyArgsPostSettlementFeeExceedsMaximum() public {
        vm.skip(true);
        FeePcts invalidFeePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 100, 31, 50, 10001);
        bytes memory invalidArgs = abi.encode(invalidFeePcts);
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_PostSettlementFeeExceedsMaximum.selector);
        feeModule.initialize();
    }

    function test_VerifyArgsWithDifferentFeeCombinations() public {
        FeePcts validFeePcts1 = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 500, 1000, 250, 100);
        bytes memory validArgs1 = abi.encode(validFeePcts1);
        cloneFeeModule(validArgs1);
        feeModule.initialize(); // Should not revert

        FeePcts validFeePcts2 = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 0, 0, 0, 0);
        bytes memory validArgs2 = abi.encode(validFeePcts2);
        cloneFeeModule(validArgs2);
        feeModule.initialize(); // Should not revert

        FeePcts validFeePcts3 = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 10000, 10000, 10000, 10000);
        bytes memory validArgs3 = abi.encode(validFeePcts3);
        cloneFeeModule(validArgs3);
        feeModule.initialize(); // Should not revert
    }

    function test_UpdateAndGetSplitRatio() public {
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(this),
                address(feeModule),
                ConstantFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(true)
        );
        ConstantFeeModule(address(feeModule)).updateFeeSplitRatio(6000);

        uint256 updatedSplitRatio = ConstantFeeModule(address(feeModule)).getFeeParams(FeeParameters.FEE_SPLIT_RATIO);
        assertEq(updatedSplitRatio, 6000, "Split ratio not updated correctly");
    }
}
