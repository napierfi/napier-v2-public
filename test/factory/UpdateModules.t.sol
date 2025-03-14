// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {Factory} from "../../src/Factory.sol";
import {PrincipalToken} from "../../src/tokens/PrincipalToken.sol";
import {AccessManager} from "../../src/modules/AccessManager.sol";
import {BaseModule} from "../../src/modules/BaseModule.sol";
import {FeeModule} from "../../src/modules/FeeModule.sol";
import {RewardProxyModule} from "../../src/modules/RewardProxyModule.sol";

import {ModuleAccessor} from "src/utils/ModuleAccessor.sol";
import "../../src/Types.sol";
import {Errors} from "../../src/Errors.sol";
import "src/Constants.sol" as Constants;

contract MockModule is BaseModule {
    function initialize() external override {}

    function VERSION() external pure override returns (bytes32) {
        return bytes32("MockModule");
    }
}

contract UpdateModulesTest is Base {
    function setUp() public override {
        super.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        vm.startPrank(curator);
        principalToken.i_accessManager().grantRoles(dev, Constants.DEV_ROLE);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = Factory.updateModules.selector;
        selectors[1] = Factory.setModuleImplementation.selector;
        principalToken.i_accessManager().grantTargetFunctionRoles(address(factory), selectors, Constants.DEV_ROLE);
        vm.stopPrank();
    }

    function test_RevertWhen_FeeModuleUpdated() public {
        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] =
            Factory.ModuleParam({moduleType: FEE_MODULE_INDEX, implementation: address(0x123), immutableData: ""});

        vm.expectRevert(Errors.Factory_CannotUpdateFeeModule.selector);
        vm.prank(dev);
        factory.updateModules(address(principalToken), params);
    }

    function test_UpdateModules() public {
        // Prepapre
        address mockImplementation = address(new MockModule());
        vm.prank(admin); // Napier admin
        factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, address(mockImplementation), true);

        address rewardProxyModule = factory.moduleFor(address(principalToken), REWARD_PROXY_MODULE_INDEX);

        // Execute
        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: REWARD_PROXY_MODULE_INDEX,
            implementation: mockImplementation,
            immutableData: ""
        });
        vm.prank(dev);
        factory.updateModules(address(principalToken), params);

        assertEq(
            RewardProxyModule(factory.moduleFor(address(principalToken), REWARD_PROXY_MODULE_INDEX)).VERSION(),
            bytes32("MockModule"),
            "Fee module not updated correctly"
        );
        assertNotEq(
            address(rewardProxyModule),
            factory.moduleFor(address(principalToken), FEE_MODULE_INDEX),
            "Fee module not updated correctly"
        );
    }

    function test_RevertWhen_InvalidModule() public {
        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: ModuleIndex.wrap(MAX_MODULES), // Invalid module type
            implementation: address(0x123),
            immutableData: ""
        });

        // Expect the call to revert
        vm.expectRevert(Errors.Factory_InvalidModule.selector);
        vm.prank(dev);
        factory.updateModules(address(principalToken), params);
    }

    function test_RevertWhen_ModuleOutOfBounds() public {
        // Prepare - Number of modules of `principalToken` is less than the latest `MAX_MODULES`
        address[] memory newModules = new address[](2);
        newModules[0] = address(feeModule);
        newModules[1] = address(rewardProxy);
        address newPointer = SSTORE2.write(abi.encode(newModules));
        vm.prank(address(factory));
        principalToken.setModules(newPointer);

        // Update a module out of bounds (index < modules.length)
        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: VERIFIER_MODULE_INDEX,
            implementation: verifierModule_logic,
            immutableData: abi.encode(type(uint256).max, type(uint256).max)
        });

        // Expect the call to revert
        vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
        vm.prank(dev);
        factory.updateModules(address(principalToken), params);
    }

    function test_RevertWhen_NotFactory() public {
        vm.expectRevert(Errors.PrincipalToken_NotFactory.selector);
        principalToken.setModules(address(0xcafe));
    }

    function test_RevertWhen_NotExists() public {
        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);

        vm.expectRevert(Errors.Factory_PrincipalTokenNotFound.selector);
        vm.prank(dev);
        factory.updateModules(address(0xcafe), params);
    }

    function test_RevertWhen_NotAuthorized() public {
        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(admin); // Napier admin
        factory.updateModules(address(principalToken), params);
    }
}
