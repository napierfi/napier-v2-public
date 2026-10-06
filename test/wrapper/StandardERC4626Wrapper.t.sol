// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";

import {TestPlus} from "../shared/TestPlus.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {AccessManager} from "src/modules/AccessManager.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;
import {IWrapper} from "src/wrapper/IWrapper.sol";

abstract contract BaseWrapperTest is TestPlus {
    using {asAddressArray} for Token[];
    using DynamicArrayLib for DynamicArrayLib.DynamicArray;

    AccessManager napierAccessManager;
    address public wrapper;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address admin = makeAddr("admin");
    address dev = makeAddr("dev");

    /// @dev wrapper may calls back on initialization
    function i_accessManager() external view returns (AccessManager) {
        return napierAccessManager;
    }

    function setUp() public virtual {
        address implementation = address(new AccessManager());
        napierAccessManager = AccessManager(LibClone.clone(implementation));
        napierAccessManager.initializeOwner(admin);

        vm.startPrank(admin);
        napierAccessManager.grantRoles(dev, Constants.DEV_ROLE);
        vm.stopPrank();

        wrapper = _deployWrapper();
        _label();
    }

    function _label() internal virtual {
        vm.label(address(napierAccessManager), "napierAccessManager");
        vm.label(address(wrapper), "wrapper");
    }

    function _deployWrapper() internal virtual returns (address);

    function boundTokenIn(Token token) public view returns (Token) {
        Token[] memory tokens = IWrapper(wrapper).getTokenInList();
        return tokens[uint256(uint160(token.unwrap())) % tokens.length];
    }

    function boundTokenOut(Token token) public view returns (Token) {
        Token[] memory tokens = IWrapper(wrapper).getTokenOutList();
        return tokens[uint256(keccak256(abi.encode(token.unwrap()))) % tokens.length];
    }

    function testFuzz_TokenIn(Token token) public virtual {
        token = boundTokenIn(token);

        uint256 callerBalance = 10 ether;
        deal(token.unwrap(), alice, callerBalance);

        uint256 tokens = 913893305211;

        if (token.isNotNative()) {
            _approve(token, alice, wrapper, tokens);
        }
        vm.startPrank(alice);
        uint256 preview = IWrapper(wrapper).previewDeposit(token, tokens);
        uint256 shares = IWrapper(wrapper).deposit{value: token.isNative() ? tokens : 0}(token, tokens, bob);
        vm.stopPrank();

        assertApproxEqAbs(preview, shares, 3, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        if (token.isNative()) {
            assertEq(address(alice).balance, callerBalance - tokens, "tokens");
        } else {
            assertApproxEqAbs(token.erc20().balanceOf(alice), callerBalance - tokens, 1, "tokens");
        }
    }

    function testFuzz_TokenOut(Token token) public virtual {
        testFuzz_TokenIn(token); // setup

        token = boundTokenOut(token);

        uint256 shares = ERC20(wrapper).balanceOf(bob);
        require(shares > 0, "setup failed");

        uint256 receiverBalance = token.isNative() ? address(alice).balance : token.erc20().balanceOf(alice);

        vm.startPrank(bob);
        uint256 preview = IWrapper(wrapper).previewRedeem(token, shares);
        uint256 tokens = IWrapper(wrapper).redeem(token, shares, alice);
        vm.stopPrank();

        assertApproxEqAbs(preview, shares, 3, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), 0, "shares");
        if (token.isNative()) {
            assertEq(address(alice).balance, receiverBalance + tokens, "tokens");
        } else {
            assertApproxEqAbs(token.erc20().balanceOf(alice), receiverBalance + tokens, 1, "tokens");
        }
    }

    function testFuzz_Deposit_RevertWhen_TokenNotInList(Token token) public {
        address[] memory tokens = IWrapper(wrapper).getTokenInList().asAddressArray();
        vm.assume(!DynamicArrayLib.wrap(tokens).contains(token.unwrap()));

        vm.prank(alice);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        IWrapper(wrapper).deposit(token, 1 ether, bob);
    }

    function testFuzz_PreviewDeposit_RevertWhen_TokenNotInList(Token token) public {
        address[] memory tokens = IWrapper(wrapper).getTokenInList().asAddressArray();
        vm.assume(!DynamicArrayLib.wrap(tokens).contains(token.unwrap()));

        vm.prank(alice);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        IWrapper(wrapper).previewDeposit(token, 1 ether);
    }

    function testFuzz_Redeem_RevertWhen_TokenNotInList(Token token) public {
        address[] memory tokens = IWrapper(wrapper).getTokenInList().asAddressArray();
        vm.assume(!DynamicArrayLib.wrap(tokens).contains(token.unwrap()));

        vm.prank(alice);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        IWrapper(wrapper).redeem(token, 1 ether, bob);
    }

    function testFuzz_PreviewRedeem_RevertWhen_TokenNotInList(Token token) public {
        address[] memory tokens = IWrapper(wrapper).getTokenInList().asAddressArray();
        vm.assume(!DynamicArrayLib.wrap(tokens).contains(token.unwrap()));

        vm.prank(alice);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        IWrapper(wrapper).previewRedeem(token, 1 ether);
    }
}
