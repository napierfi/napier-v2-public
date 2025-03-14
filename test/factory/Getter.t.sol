// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";

import {ModuleAccessor} from "src/utils/ModuleAccessor.sol";
import "../../src/Types.sol";
import {Errors} from "../../src/Errors.sol";
import "src/Constants.sol" as Constants;

contract GetterTest is Base {
    function setUp() public override {
        super.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();
    }

    function test_Initialize() public view {
        assertEq(address(factory.i_accessManager()), address(napierAccessManager));
    }

    function testFuzz_IsValidImplementation(ModuleIndex index, address implementation) public view {
        index = ModuleIndex.wrap(index.unwrap() % 10);
        bool isValid = true;
        if (index == FEE_MODULE_INDEX) {
            implementation = address(constantFeeModule_logic);
        } else if (index == REWARD_PROXY_MODULE_INDEX) {
            implementation = address(mockRewardProxy_logic);
        } else if (index == VERIFIER_MODULE_INDEX) {
            implementation = address(verifierModule_logic);
        } else {
            implementation = address(0);
            isValid = false;
        }
        assertEq(factory.isValidImplementation(index, implementation), isValid, "Implementation not valid");
    }

    function testFuzz_ModuleFor(ModuleIndex index) public {
        index = ModuleIndex.wrap(index.unwrap() % 10);

        if (index == FEE_MODULE_INDEX) {
            assertEq(
                factory.moduleFor(address(principalToken), index),
                address(feeModule),
                "Fee module not returned correctly"
            );
        } else if (index == REWARD_PROXY_MODULE_INDEX) {
            assertEq(
                factory.moduleFor(address(principalToken), index),
                address(rewardProxy),
                "Reward proxy module not returned correctly"
            );
        } else if (index == VERIFIER_MODULE_INDEX) {
            assertEq(
                factory.moduleFor(address(principalToken), index),
                address(verifier),
                "Verifier module not returned correctly"
            );
        } else {
            vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
            factory.moduleFor(address(principalToken), index);
        }
    }

    function test_RevertWhen_OutOfBounds() public {
        vm.expectRevert(ModuleAccessor.ModuleOutOfBounds.selector);
        factory.moduleFor(address(principalToken), ModuleIndex.wrap(MAX_MODULES));
    }

    function test_RevertWhen_NotFound() public {
        address[3] memory modules;
        modules[FEE_MODULE_INDEX.unwrap()] = address(feeModule);
        modules[REWARD_PROXY_MODULE_INDEX.unwrap()] = address(0); // Set reward proxy to 0
        modules[VERIFIER_MODULE_INDEX.unwrap()] = address(verifier);

        vm.mockCall(
            address(principalToken), abi.encodeWithSelector(principalToken.s_modules.selector), abi.encode(modules)
        );
        vm.expectRevert(Errors.Factory_ModuleNotFound.selector);
        factory.moduleFor(address(principalToken), REWARD_PROXY_MODULE_INDEX);
    }
}
