// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {UniswapV4Base} from "../../UniswapV4Base.t.sol";
import {TokiPoolDeployer} from "src/modules/deployers/TokiPoolDeployer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {AccessManager, AccessManaged} from "src/modules/AccessManager.sol";

// Required imports per coding standards
import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

/// @title SetterTest
/// @notice Comprehensive test suite for TokiPoolDeployer setter functions
/// @dev Tests both setHook and setHookApproved functions with proper access control validation
contract SetterTest is UniswapV4Base {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STORAGE                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    TokiPoolDeployer deployer;

    // Test addresses for hooks
    address newTokiHook;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         SETUP                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        deployer = TokiPoolDeployer(tokiPoolDeployer);

        // Create test hook addresses
        newTokiHook = makeAddr("newTokiHook");
        vm.etch(newTokiHook, address(tokiHook).code);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HELPER FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Helper function to grant permissions for setHook function
    function _grantSetHookPermissions() internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiPoolDeployer.setHook.selector;

        vm.startPrank(admin);
        factory.i_accessManager().grantRoles(admin, Constants.DEV_ROLE);
        factory.i_accessManager().grantTargetFunctionRoles(address(deployer), selectors, Constants.DEV_ROLE);
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      MAIN TESTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_SetHook() public {
        // Arrange: Set up test state with permissions
        _grantSetHookPermissions();

        // Act: Enable the new FRP hook
        vm.expectEmit(true, false, false, true);
        emit TokiPoolDeployer.HookSet(newTokiHook, true);

        vm.prank(admin);
        deployer.setHook(newTokiHook, true);

        // Assert: Verify expected outcomes
        assertTrue(deployer.hookEnabled(newTokiHook), "Hook should be enabled");
    }

    function test_SetHook_RevertWhen_NotAuthorized() public {
        // Arrange: No permissions granted to alice

        // Act & Assert: Expect revert when unauthorized caller attempts to set hook
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(alice);
        deployer.setHook(address(tokiHook), true);
    }

    function test_SetHook_DisableHook() public {
        // Arrange
        _grantSetHookPermissions();

        // Act: Disable the hook
        vm.expectEmit(true, false, false, true);
        emit TokiPoolDeployer.HookSet(address(tokiHook), false);

        vm.prank(admin);
        deployer.setHook(address(tokiHook), false);

        // Assert: Verify disabled status
        assertFalse(deployer.hookEnabled(address(tokiHook)), "Hook should be disabled");
    }

    function test_SetImplementation() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiPoolDeployer.setLiquidityTokenImplementation.selector;
        _grantRoles(napierAccessManager, admin, admin, address(deployer), selectors, Constants.DEV_ROLE);

        vm.prank(admin);
        deployer.setLiquidityTokenImplementation(address(tokiHook), liquidityTokenImplementation, true);
        assertEq(deployer.liquidityTokenImplementationEnabled(address(tokiHook), liquidityTokenImplementation), true);

        vm.prank(admin);
        deployer.setLiquidityTokenImplementation(address(tokiHook), liquidityTokenImplementation, false);
        assertEq(deployer.liquidityTokenImplementationEnabled(address(tokiHook), liquidityTokenImplementation), false);
    }

    function test_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        deployer.setLiquidityTokenImplementation(address(tokiHook), liquidityTokenImplementation, true);
    }

    function test_RevertWhen_ZeroAddress() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiPoolDeployer.setLiquidityTokenImplementation.selector;
        _grantRoles(napierAccessManager, admin, admin, address(deployer), selectors, Constants.DEV_ROLE);

        vm.expectRevert(Errors.TokiPoolDeployer_InvalidHook.selector);
        vm.prank(admin);
        deployer.setLiquidityTokenImplementation(address(0xafefe), liquidityTokenImplementation, true);

        vm.expectRevert(Errors.TokiPoolDeployer_InvalidLiquidityTokenImplementation.selector);
        vm.prank(admin);
        deployer.setLiquidityTokenImplementation(address(tokiHook), address(0xafefe), true);
    }
}
