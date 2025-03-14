// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {Factory} from "src/Factory.sol";
import {ModuleIndex, FEE_MODULE_INDEX} from "src/Types.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {Errors} from "src/Errors.sol";
import {Events} from "src/Events.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

contract FactoryTest is Test {
    Factory factory;
    address mockAccessManager;
    address admin = makeAddr("admin");

    function setUp() public {
        mockAccessManager = address(new AccessManager());
        address factory_impl = address(new Factory());
        address proxy = address(LibClone.deployERC1967(factory_impl, abi.encode(mockAccessManager)));
        factory = Factory(proxy);
        vm.label(admin, "Admin");
    }

    function test_SetPrincipalTokenBlueprint() public {
        address ptBlueprint = makeAddr("ptBlueprint");
        address ytBlueprint = makeAddr("ytBlueprint");

        vm.mockCall(
            mockAccessManager,
            abi.encodeWithSelector(
                AccessManager.canCall.selector, admin, address(factory), Factory.setPrincipalTokenBlueprint.selector
            ),
            abi.encode(true)
        );

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Events.PrincipalTokenImplementationSet(ptBlueprint, ytBlueprint);
        factory.setPrincipalTokenBlueprint(ptBlueprint, ytBlueprint);

        assertEq(factory.s_ytBlueprints(ptBlueprint), ytBlueprint);
    }

    function test_SetPoolDeployer() public {
        address deployer = makeAddr("deployer");

        vm.mockCall(
            mockAccessManager,
            abi.encodeWithSelector(
                AccessManager.canCall.selector, admin, address(factory), Factory.setPoolDeployer.selector
            ),
            abi.encode(true)
        );

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Events.PoolDeployerSet(deployer, true);
        factory.setPoolDeployer(deployer, true);

        assertTrue(factory.s_poolDeployers(deployer));
    }

    function test_SetAccessManagerImplementation() public {
        address implementation = makeAddr("implementation");

        vm.mockCall(
            mockAccessManager,
            abi.encodeWithSelector(
                AccessManager.canCall.selector, admin, address(factory), Factory.setAccessManagerImplementation.selector
            ),
            abi.encode(true)
        );

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Events.AccessManagerImplementationSet(implementation, true);
        factory.setAccessManagerImplementation(implementation, true);

        assertTrue(factory.s_accessManagerImplementations(implementation));
    }

    function test_SetModuleImplementation() public {
        ModuleIndex index = FEE_MODULE_INDEX;
        address implementation = makeAddr("implementation");

        vm.mockCall(
            mockAccessManager,
            abi.encodeWithSelector(
                AccessManager.canCall.selector, admin, address(factory), Factory.setModuleImplementation.selector
            ),
            abi.encode(true)
        );

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Events.ModuleImplementationSet(index, implementation, true);
        factory.setModuleImplementation(index, implementation, true);

        assertTrue(factory.isValidImplementation(index, implementation));
    }

    function test_SetTreasury() public {
        address treasury = makeAddr("treasury");

        vm.mockCall(
            mockAccessManager,
            abi.encodeWithSelector(
                AccessManager.canCall.selector, admin, address(factory), Factory.setTreasury.selector
            ),
            abi.encode(true)
        );

        vm.prank(admin);
        vm.expectEmit(true, true, true, true);
        emit Events.TreasurySet(treasury);
        factory.setTreasury(treasury);

        assertEq(factory.s_treasury(), treasury);
    }

    function test_RevertWhen_Unauthorized() public {
        vm.mockCall(mockAccessManager, abi.encodeWithSelector(AccessManager.canCall.selector), abi.encode(false));

        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        factory.setPrincipalTokenBlueprint(address(0), address(0));

        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        factory.setPoolDeployer(address(0), true);

        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        factory.setAccessManagerImplementation(address(0), true);

        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        factory.setResolverBlueprint(address(0), true);

        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        factory.setModuleImplementation(FEE_MODULE_INDEX, address(0), true);

        vm.expectRevert(abi.encodeWithSignature("AccessManaged_Restricted()"));
        factory.setTreasury(address(0));
    }

    function test_RevertWhen_ZeroAddress() public {
        vm.mockCall(mockAccessManager, abi.encodeWithSelector(AccessManager.canCall.selector), abi.encode(true));

        vm.expectRevert(Errors.Factory_InvalidAddress.selector);
        factory.setPrincipalTokenBlueprint(address(0), address(1));

        vm.expectRevert(Errors.Factory_InvalidAddress.selector);
        factory.setPoolDeployer(address(0), true);

        vm.expectRevert(Errors.Factory_InvalidAddress.selector);
        factory.setAccessManagerImplementation(address(0), true);

        vm.expectRevert(Errors.Factory_InvalidAddress.selector);
        factory.setResolverBlueprint(address(0), true);

        vm.expectRevert(Errors.Factory_InvalidAddress.selector);
        factory.setModuleImplementation(FEE_MODULE_INDEX, address(0), true);

        vm.expectRevert(Errors.Factory_InvalidAddress.selector);
        factory.setTreasury(address(0));
    }
}
