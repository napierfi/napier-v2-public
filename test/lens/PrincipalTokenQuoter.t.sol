// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {PrincipalTokenQuoter} from "src/lens/PrincipalTokenQuoter.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {UniswapV4ZapBase} from "test/UniswapV4Base.t.sol";

// Most of API are tested through twoCrypto/Lens tests. Low priority to test them here.
contract PrincipalTokenQuoterTest is UniswapV4ZapBase {
    function setUp() public virtual override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();
        _label();
    }

    function test_ImmutableArgs() public view {
        assertEq(address(ptQuoter.factory()), address(factory), "factory");
        assertEq(ptQuoter.WETH(), address(weth), "WETH");
        assertEq(address(ptQuoter.vaultConnectorRegistry()), address(connectorRegistry), "registry");
        assertEq(address(ptQuoter.i_accessManager()), address(factory.i_accessManager()), "accessManager");
    }

    function test_Upgrade() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;
        _grantRoles(napierAccessManager, admin, admin, address(ptQuoter), selectors, Constants.DEV_ROLE);

        address newImplementation = address(new PrincipalTokenQuoter());
        vm.prank(admin);
        UUPSUpgradeable(address(ptQuoter)).upgradeToAndCall(newImplementation, "");

        // ERC1967I: 1-byte calldata returns implementation
        (, bytes memory ret) = address(ptQuoter).call("c");
        assertEq(abi.decode(ret, (address)), newImplementation);
    }

    function test_Upgrade_RevertWhen_NotAuthorized() public {
        address newImplementation = address(new PrincipalTokenQuoter());
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        UUPSUpgradeable(address(ptQuoter)).upgradeToAndCall(newImplementation, "");
    }
}
