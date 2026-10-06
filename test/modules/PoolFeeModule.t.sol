// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {MockFactory} from "../mocks/MockFactory.sol";
import {MockPrincipalToken} from "../mocks/MockPrincipalToken.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";

import {PoolFeeModule, FeeModule} from "src/modules/PoolFeeModule.sol";
import {AccessManager} from "src/modules/AccessManager.sol";

contract PoolFeeModuleTest is Test {
    using SafeCastLib for *;
    using FeePctsPoolLib for FeePctsPool;

    PoolFeeModule feeModuleImplementation;
    FeeModule feeModule;
    FeePctsPool initialFeePcts;
    uint128 initialAmmFeeParams;
    MockFactory mockFactory;
    address mockAccessManager;

    MockPrincipalToken mockPrincipalToken;

    /// @dev FeeModule makes a call to `msg.sender` on initialization
    uint16 public constant DEFAULT_SPLIT_RATIO_BPS = Constants.DEFAULT_SPLIT_RATIO_BPS;

    function setUp() public {
        // Deploy mock contracts
        mockAccessManager = makeAddr("mockAccessManager");
        mockFactory = new MockFactory(mockAccessManager);
        mockPrincipalToken = new MockPrincipalToken(address(mockFactory));
        // Deploy the PoolFeeModule implementation
        feeModuleImplementation = new PoolFeeModule();

        // Set initial fee parameters
        initialAmmFeeParams =
            uint128(uint256(FixedPointMathLib.lnWad(1.01e18)) * Constants.TOKI_SWAP_FEE_SCALE / Constants.WAD);
        initialFeePcts = FeePctsPoolLib.pack({
            splitFeePct: Constants.DEFAULT_SPLIT_RATIO_BPS,
            ammFeeParams: initialAmmFeeParams,
            reserveFeePct: 200
        });

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
        FeePctsPool feePcts = feeModule.getFeePcts();
        assertEq(FeePctsPoolLib.getSplitPctBps(feePcts), Constants.DEFAULT_SPLIT_RATIO_BPS, "Incorrect split ratio");
        assertEq(FeePctsPoolLib.getAmmFeeParams(feePcts), initialAmmFeeParams, "Incorrect AMM fee params");
        assertEq(FeePctsPoolLib.getReserveFeePctBps(feePcts), 200, "Incorrect reserve fee");
    }

    function test_RevertWhen_AmmFeeParamsExceedsMaximum() public {
        FeePctsPool badFeePcts = FeePctsPoolLib.pack({
            splitFeePct: Constants.DEFAULT_SPLIT_RATIO_BPS,
            ammFeeParams: Constants.MAX_TOKI_SWAP_FEE_PARAMS + 1,
            reserveFeePct: 200
        });

        // Deploy the FeeModule instance using LibClone
        bytes memory customArgs = abi.encode(badFeePcts);
        cloneFeeModule(customArgs);
        vm.expectRevert(Errors.PoolFeeModule_FeeExceedsMaximum.selector);
        feeModule.initialize();
    }

    function test_RevertWhen_ReserveFeeExceedsMaximum() public {
        FeePctsPool badFeePcts = FeePctsPoolLib.pack({
            splitFeePct: Constants.DEFAULT_SPLIT_RATIO_BPS,
            ammFeeParams: Constants.MAX_TOKI_SWAP_FEE_PARAMS - 1,
            reserveFeePct: Constants.MAX_RESERVE_FEE_BPS + 1
        });

        // Deploy the FeeModule instance using LibClone
        bytes memory customArgs = abi.encode(badFeePcts);
        cloneFeeModule(customArgs);
        vm.expectRevert(Errors.PoolFeeModule_ReserveFeeExceedsMaximum.selector);
        feeModule.initialize();
    }

    function test_UpdateFeeSplitRatioBasic() public {
        // Simulate being called from the Factory
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(this),
                address(feeModule),
                PoolFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(true)
        );
        uint16 oldSplitRatio = FeePctsPoolLib.getSplitPctBps(feeModule.getFeePcts());
        uint16 expectedSplitRatio = uint16(6000);
        vm.expectEmit(false, false, false, true, address(feeModule));
        emit PoolFeeModule.FeeSplitRatioUpdated(oldSplitRatio, expectedSplitRatio);
        PoolFeeModule(address(feeModule)).updateFeeSplitRatio(6000);

        FeePctsPool updatedFeePcts = feeModule.getFeePcts();
        assertEq(FeePctsPoolLib.getSplitPctBps(updatedFeePcts), 6000, "Split ratio not updated correctly");
    }

    function test_RevertWhen_UpdateFeeSplitRatioUnauthorized() public {
        vm.prank(address(0xdead));
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(0xdead),
                address(feeModule),
                PoolFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(false)
        );
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        PoolFeeModule(address(feeModule)).updateFeeSplitRatio(6000);
    }

    function test_RevertWhen_UpdateFeeSplitRatioExceedsMaximum() public {
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(
                AccessManager.canCall.selector,
                address(this),
                address(feeModule),
                PoolFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(true)
        );
        vm.expectRevert(Errors.FeeModule_SplitFeeExceedsMaximum.selector);
        PoolFeeModule(address(feeModule)).updateFeeSplitRatio(Constants.BASIS_POINTS + 1);
    }

    function test_RevertWhen_VerifyArgsInvalidLength() public {
        // Deploy a new instance with invalid args length
        bytes memory invalidArgs = abi.encode(""); // Only encode the principalToken address, omitting the FeePctsPool
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.PoolFeeModule_InvalidFeeParam.selector);
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
        FeePctsPool invalidFeePcts = FeePctsPoolLib.pack(invalidSplitPctBps, 1_000_000, 200);
        bytes memory invalidArgs = abi.encode(invalidFeePcts);
        cloneFeeModule(invalidArgs);

        vm.expectRevert(Errors.FeeModule_SplitFeeMismatchDefault.selector);
        feeModule.initialize();
    }

    function test_VerifyArgsWithDifferentFeeCombinations() public {
        FeePctsPool validFeePcts1 = FeePctsPoolLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 500, 1000);
        bytes memory validArgs1 = abi.encode(validFeePcts1);
        cloneFeeModule(validArgs1);
        feeModule.initialize(); // Should not revert

        FeePctsPool validFeePcts2 = FeePctsPoolLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 0, 0);
        bytes memory validArgs2 = abi.encode(validFeePcts2);
        cloneFeeModule(validArgs2);
        feeModule.initialize(); // Should not revert

        FeePctsPool validFeePcts3 =
            FeePctsPoolLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 10000, Constants.MAX_RESERVE_FEE_BPS);
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
                PoolFeeModule.updateFeeSplitRatio.selector
            ),
            abi.encode(true)
        );
        PoolFeeModule(address(feeModule)).updateFeeSplitRatio(6000);

        uint256 updatedSplitRatio = PoolFeeModule(address(feeModule)).getFeePcts().getSplitPctBps();
        assertEq(updatedSplitRatio, 6000, "Split ratio not updated correctly");
    }
}
