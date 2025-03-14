// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import {VerificationStatus, VERIFIER_MODULE_INDEX, FEE_MODULE_INDEX, MAX_MODULES} from "src/Types.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {DepositCapVerifierModule} from "src/modules/VerifierModule.sol";
import {ModuleAccessor} from "src/utils/ModuleAccessor.sol";
import {Errors} from "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

contract DepositCapTest is PrincipalTokenTest {
    using stdStorage for StdStorage;

    uint256 constant INITIAL_MAX_SUPPLY = 21283928219;

    function setUp() public override {
        super.setUp();

        // Deploy the verifier module
        bytes memory customArgs = abi.encode(INITIAL_MAX_SUPPLY);
        bytes memory encodedArgs = abi.encode(principalToken, customArgs);
        verifier = DepositCapVerifierModule(LibClone.clone(verifierModule_logic, encodedArgs));
        verifier.initialize();

        address[] memory modules = ModuleAccessor.read(principalToken.s_modules());
        ModuleAccessor.set(modules, VERIFIER_MODULE_INDEX, address(verifier));
        address newPointer = SSTORE2.write(abi.encode(modules));
        vm.prank(address(principalToken.i_factory())); // Impersonate the factory to allow the update
        principalToken.setModules(newPointer);

        vm.label(address(verifierModule_logic), "verifierImplementation");
        vm.label(address(verifier), "verifier");

        mockAccessManagerCanCall(dev, address(verifier), verifier.setDepositCap.selector, true);
    }

    function test_SetDepositCap() public {
        vm.prank(dev);
        verifier.setDepositCap(2474174819);

        assertEq(principalToken.maxSupply(alice), 2474174819, "Max supply");
    }

    function testFuzz_DepositCap(uint256 deposit) public {
        // Pre-condition - Initial Cap
        assertEq(principalToken.maxSupply(alice), INITIAL_MAX_SUPPLY, "Return initial max supply");
        uint256 maxIssue = _pt_convertToPrincipal(INITIAL_MAX_SUPPLY);
        assertEq(principalToken.maxIssue(alice), maxIssue, "Return initial max issue");

        // Deposit
        deposit = bound(deposit, 0, INITIAL_MAX_SUPPLY);
        deal(address(target), alice, deposit);
        _approve(target, alice, address(principalToken), deposit);
        vm.prank(alice);
        principalToken.supply(deposit, alice);

        // Post-condition - Cap should decrease by the deposit
        assertEq(principalToken.maxSupply(alice), INITIAL_MAX_SUPPLY - deposit, "MaxSupply decreases");
        maxIssue -= _pt_convertToPrincipal(deposit);
        assertEq(principalToken.maxIssue(alice), maxIssue, "MaxIssue decreases");
    }

    function testFuzz_ZeroCap(bool paused, bool expired) public {
        // Prepare - Pause the principalToken
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        if (paused) {
            vm.prank(dev);
            principalToken.pause();
        }
        if (expired) {
            vm.warp(expiry);
        }

        if (paused || expired) {
            assertEq(principalToken.maxSupply(alice), 0, "Return 0 when paused");
            assertEq(principalToken.maxIssue(alice), 0, "Return 0 when paused");
        } else {
            assertEq(principalToken.maxSupply(alice), INITIAL_MAX_SUPPLY, "Return initial max supply");
            uint256 maxIssue = _pt_convertToPrincipal(INITIAL_MAX_SUPPLY);
            assertEq(principalToken.maxIssue(alice), maxIssue, "Return initial max issue");
        }
    }

    function test_NoCap() public {
        // Reset verifier to address(0)
        address[] memory newModules = new address[](MAX_MODULES);
        ModuleAccessor.set(newModules, FEE_MODULE_INDEX, address(feeModule));
        address pointer = SSTORE2.write(abi.encode(newModules));
        vm.prank(address(principalToken.i_factory()));
        principalToken.setModules(pointer);

        assertEq(principalToken.maxSupply(alice), type(uint256).max, "No cap");
        assertEq(principalToken.maxIssue(alice), type(uint256).max, "No cap");
    }

    function test_RevertWhen_SupplyMoreThanMaximum() public {
        uint256 maxSupply = principalToken.maxSupply(alice);

        // supply
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.PrincipalToken_VerificationFailed.selector, VerificationStatus.SupplyMoreThanMax
            )
        );
        principalToken.supply(maxSupply + 1, alice);
        // supply with callback
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.PrincipalToken_VerificationFailed.selector, VerificationStatus.SupplyMoreThanMax
            )
        );
        principalToken.supply(maxSupply + 1, alice, "junk");
    }

    function test_RevertWhen_IssueMoreThanMaximum() public {
        uint256 maxIssue = principalToken.maxIssue(alice);

        // issue
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.PrincipalToken_VerificationFailed.selector, VerificationStatus.SupplyMoreThanMax
            )
        );
        principalToken.issue(maxIssue + 1, alice);
        // issue with callback
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.PrincipalToken_VerificationFailed.selector, VerificationStatus.SupplyMoreThanMax
            )
        );
        principalToken.issue(maxIssue + 1, alice, "junk");
    }

    function test_RevertWhen_Restricted() public {
        vm.mockCall(
            address(verifier),
            abi.encodeWithSelector(verifier.verify.selector),
            abi.encode(VerificationStatus.Restricted)
        );

        vm.expectRevert(
            abi.encodeWithSelector(Errors.PrincipalToken_VerificationFailed.selector, VerificationStatus.Restricted)
        );
        vm.prank(alice);
        principalToken.supply(22, alice);
    }

    function mockAccessManagerCanCall(address caller, address target, bytes4 selector, bool access) public {
        vm.mockCall(
            address(accessManager),
            abi.encodeWithSelector(AccessManager.canCall.selector, caller, target, selector),
            abi.encode(access)
        );
    }
}
