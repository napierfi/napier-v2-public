// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

import {Errors} from "src/Errors.sol";
import {VerificationStatus} from "src/Types.sol";
import {DepositCapVerifierModule} from "src/modules/VerifierModule.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {BASIS_POINTS} from "src/Constants.sol";

/// @dev Dummy contract for vm.mockCall. Calls to mocked addresses may revert if there is no code on the address.
contract Dummy {}

contract VerifierModuleTest is Test {
    bytes4 constant SUPPLY_SELECTOR = bytes4(keccak256("supply(uint256,address)"));
    bytes4 constant SUPPLY_WITH_CALLBACK_SELECTOR = bytes4(keccak256("supply(uint256,address,bytes)"));
    bytes4 constant ISSUE_SELECTOR = bytes4(keccak256("issue(uint256,address)"));
    bytes4 constant ISSUE_WITH_CALLBACK_SELECTOR = bytes4(keccak256("issue(uint256,address,bytes)"));

    DepositCapVerifierModule implementation;
    DepositCapVerifierModule verifier;

    Dummy mockPrincipalToken;
    Dummy mockAccessManager;
    address mockUnderlying;

    uint256 initialSupplyCap = 3212e12;
    uint256 initialIssueCap = 7873e18;

    address strategist = makeAddr("strategist"); // Can call setDepositCap
    address alice = makeAddr("alice");

    function setUp() public {
        // Deploy mock contracts
        mockAccessManager = new Dummy();
        mockPrincipalToken = new Dummy();
        mockUnderlying = address(deployMockERC20("Mock", "MOCK", 8));

        vm.label(address(mockAccessManager), "AccessManager");
        vm.label(address(mockPrincipalToken), "mockPrincipalToken");

        // Deploy the DepositCapVerifierModule implementation
        implementation = new DepositCapVerifierModule();

        // Deploy the DepositCapVerifierModule instance using LibClone
        bytes memory customArgs = abi.encode(initialSupplyCap);
        bytes memory args = abi.encode(mockPrincipalToken, customArgs);
        address clone = LibClone.clone(address(implementation), args);
        verifier = DepositCapVerifierModule(clone);

        vm.mockCall(
            address(mockPrincipalToken), abi.encodeWithSignature("i_accessManager()"), abi.encode(mockAccessManager)
        );
        vm.mockCall(address(mockPrincipalToken), abi.encodeWithSignature("underlying()"), abi.encode(mockUnderlying));
        mockAccessManagerCanCall(strategist, address(verifier), DepositCapVerifierModule.setDepositCap.selector, true);

        verifier.initialize();

        vm.label(address(implementation), "implementation");
        vm.label(address(verifier), "verifier");
    }

    function test_InitialDepositCaps() public view {
        assertEq(verifier.depositCap(), initialSupplyCap, "Cap");
        assertEq(verifier.maxSupply(address(0)), initialSupplyCap, "Initial max supply");
    }

    function test_RevertWhen_Reinitialize() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        verifier.initialize();
    }

    function testFuzz_SetDepositCap(uint256 cap) public {
        vm.prank(strategist);
        verifier.setDepositCap(cap);
        assertEq(verifier.depositCap(), cap, "Cap update");
    }

    function test_NoCap() public {
        vm.prank(strategist);
        verifier.setDepositCap(type(uint256).max);

        assertEq(verifier.maxSupply(address(0)), type(uint256).max, "No cap");
    }

    function testFuzz_MaxSupply(uint256 cap, uint256 deposit) public {
        cap = bound(cap, 0, type(uint80).max);

        vm.prank(strategist);
        verifier.setDepositCap(cap);

        deposit = bound(deposit, 0, cap);
        deal(mockUnderlying, address(mockPrincipalToken), deposit);

        uint256 maxSupply = verifier.maxSupply(address(0));
        if (deposit >= cap) {
            assertEq(maxSupply, 0, "cap reaches");
        } else {
            assertEq(maxSupply, cap - deposit, "MaxSupply ~= cap - deposit");
        }
    }

    function test_RevertWhen_Unauthorized() public {
        mockAccessManagerCanCall(alice, address(verifier), DepositCapVerifierModule.setDepositCap.selector, false);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(alice);
        verifier.setDepositCap(218132821);
    }

    function testFuzz_Verify(bytes4 selector, uint256 shares, uint256 principal) public {
        testFuzz_SetDepositCap(type(uint256).max);

        VerificationStatus status = verifier.verify(selector, alice, shares, principal, alice);

        assertEq(status, VerificationStatus.Success, "Success");
    }

    function testFuzz_VerifyWhen_SupplySucceed(uint256 maxShares, uint256 shares, uint256 principal) public {
        shares = bound(shares, 0, maxShares);
        testFuzz_SetDepositCap(maxShares);
        assertEq(
            verifier.verify(SUPPLY_SELECTOR, alice, shares, principal, alice),
            VerificationStatus.Success,
            "Max supply is not exceeded"
        );
        assertEq(
            verifier.verify(SUPPLY_WITH_CALLBACK_SELECTOR, alice, shares, principal, alice),
            VerificationStatus.Success,
            "Max supply is not exceeded"
        );
    }

    function testFuzz_VerifyWhen_SupplyMoreThanMax(uint256 shares, uint256 principal) public view {
        shares = bound(shares, verifier.maxSupply(alice) + 1, type(uint256).max);
        assertEq(
            verifier.verify(SUPPLY_SELECTOR, alice, shares, principal, alice),
            VerificationStatus.SupplyMoreThanMax,
            "Max supply reached"
        );
        assertEq(
            verifier.verify(SUPPLY_WITH_CALLBACK_SELECTOR, alice, shares, principal, alice),
            VerificationStatus.SupplyMoreThanMax,
            "Max supply reached"
        );
    }

    /// Helper
    function assertEq(VerificationStatus left, VerificationStatus right, string memory err) public pure {
        assertEq(uint256(left), uint256(right), err);
    }

    function mockAccessManagerCanCall(address caller, address target, bytes4 selector, bool access) public {
        vm.mockCall(
            address(mockAccessManager),
            abi.encodeWithSelector(AccessManager.canCall.selector, caller, target, selector),
            abi.encode(access)
        );
    }
}
