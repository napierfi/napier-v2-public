// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as NapierConstants;
import {Commands} from "src/zap/uniswap/Commands.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";

contract CombineTest is UniswapV4ZapBase {
    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        // Setup user with base tokens and convert to target vault shares
        deal(address(base), alice, 1000 * bOne);

        // Alice deposits base tokens to get target vault shares
        vm.startPrank(alice);
        base.approve(address(target), type(uint256).max);
        target.deposit(500 * bOne, alice); // Give Alice 500 vault shares
        vm.stopPrank();

        // Set up permit2 approvals for target tokens (vault shares)
        vm.startPrank(alice);
        target.approve(address(permit2), type(uint256).max);
        permit2.approve(address(target), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // Supply PT/YT tokens to Alice for combine testing
        _supplyPrincipalToAlice();

        // Set up permit2 approvals for PT and YT tokens
        vm.startPrank(alice);
        principalToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(principalToken), address(zap), type(uint160).max, type(uint48).max);
        yt.approve(address(permit2), type(uint256).max);
        permit2.approve(address(yt), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function _supplyPrincipalToAlice() internal {
        uint256 supplyAmount = 100 * tOne;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, supplyAmount, alice);

        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_PrincipalTokenCombine() public {
        uint256 combineAmount = 50 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 ytBalanceBefore = yt.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, combineAmount, bob);

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 ytBalanceAfter = yt.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Alice should have spent her PT and YT tokens
        assertEq(ptBalanceAfter, ptBalanceBefore - combineAmount, "alice PT");
        assertEq(ytBalanceAfter, ytBalanceBefore - combineAmount, "alice YT");

        // Bob should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewCombine(combineAmount), 1, "bob"
        );

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenCombineWhen_ContractBalance() public {
        uint256 transferAmount = 30 * bOne;

        // Transfer PT and YT tokens to the zap contract first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(principalToken), address(zap), transferAmount);
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(yt), address(zap), transferAmount);

        // Check initial balances
        uint256 zapPtBalanceBefore = principalToken.balanceOf(address(zap));
        uint256 zapYtBalanceBefore = yt.balanceOf(address(zap));
        uint256 targetBalanceBefore = target.balanceOf(bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, ActionConstants.CONTRACT_BALANCE, bob);

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Bob should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewCombine(transferAmount), 1, "bob"
        );

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenCombineWhen_ContractBalance_InsufficientYieldToken() public {
        uint256 ptTransferAmount = 50 * bOne;
        uint256 ytTransferAmount = 30 * bOne; // Less YT than PT

        // Transfer more PT than YT to the zap contract
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(principalToken), address(zap), ptTransferAmount);
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(yt), address(zap), ytTransferAmount);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, ActionConstants.CONTRACT_BALANCE, bob);

        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientYieldTokenBalance.selector);
        zap.execute(commands, inputs);
    }

    function test_PrincipalTokenCombineWhen_AddressThis() public {
        uint256 combineAmount = 40 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 ytBalanceBefore = yt.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(address(zap));

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, combineAmount, ActionConstants.ADDRESS_THIS);

        vm.prank(alice);
        zap.execute(commands, inputs);

        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 ytBalanceAfter = yt.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(address(zap));

        // Alice should have spent her PT and YT tokens
        assertEq(ptBalanceAfter, ptBalanceBefore - combineAmount, "alice PT");
        assertEq(ytBalanceAfter, ytBalanceBefore - combineAmount, "alice YT");

        // Zap should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewCombine(combineAmount), 1, "zap"
        );
    }

    function test_PrincipalTokenCombineWhen_MsgSender() public {
        uint256 combineAmount = 35 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 ytBalanceBefore = yt.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(alice);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, combineAmount, ActionConstants.MSG_SENDER);

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 ytBalanceAfter = yt.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(alice);

        // Alice should have spent her PT and YT tokens
        assertEq(ptBalanceAfter, ptBalanceBefore - combineAmount, "alice PT");
        assertEq(ytBalanceAfter, ytBalanceBefore - combineAmount, "alice YT");

        // Alice should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewCombine(combineAmount), 1, "alice"
        );

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_InvalidPrincipalToken() public {
        uint256 combineAmount = 50 * bOne;

        // Create a fake principal token address
        address fakePrincipalToken = address(0x123);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COMBINE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(fakePrincipalToken, combineAmount, bob);

        vm.prank(alice);
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.execute(commands, inputs);
    }
}
