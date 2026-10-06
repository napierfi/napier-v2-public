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

contract RedeemTest is UniswapV4ZapBase {
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

        // Supply PT/YT tokens to Alice for redemption testing
        _supplyPrincipalToAlice();

        // Set up permit2 approvals for PT tokens
        vm.startPrank(alice);
        principalToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(principalToken), address(zap), type(uint160).max, type(uint48).max);
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

    function test_PrincipalTokenRedeem() public {
        uint256 redeemAmount = 50 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, redeemAmount, bob);

        vm.warp(expiry);

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Alice should have spent her PT tokens
        assertEq(ptBalanceAfter, ptBalanceBefore - redeemAmount, "alice");

        // Bob should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewRedeem(redeemAmount), 1, "bob"
        );

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenRedeemWhen_ContractBalance() public {
        uint256 transferAmount = 30 * bOne;

        // Transfer PT tokens to the zap contract first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(principalToken), address(zap), transferAmount);

        // Check initial balances
        uint256 zapPtBalanceBefore = principalToken.balanceOf(address(zap));
        uint256 targetBalanceBefore = target.balanceOf(bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, ActionConstants.CONTRACT_BALANCE, bob);

        vm.warp(expiry);

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 zapPtBalanceAfter = principalToken.balanceOf(address(zap));
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Bob should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewRedeem(transferAmount), 1, "bob"
        );

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenRedeemWhen_AddressThis() public {
        uint256 redeemAmount = 40 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(address(zap));

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, redeemAmount, ActionConstants.ADDRESS_THIS);

        vm.warp(expiry);

        vm.prank(alice);
        zap.execute(commands, inputs);

        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(address(zap));

        // Alice should have spent her PT tokens
        assertEq(ptBalanceAfter, ptBalanceBefore - redeemAmount, "alice");

        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewRedeem(redeemAmount), 1, "zap"
        );
    }

    function test_PrincipalTokenRedeemWhen_MsgSender() public {
        uint256 redeemAmount = 35 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(alice);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(principalToken, redeemAmount, ActionConstants.MSG_SENDER);

        vm.warp(expiry);

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(alice);

        // Alice should have spent her PT tokens
        assertEq(ptBalanceAfter, ptBalanceBefore - redeemAmount, "alice");

        // Alice should have received underlying tokens
        assertApproxEqAbs(
            targetBalanceAfter, targetBalanceBefore + principalToken.previewRedeem(redeemAmount), 1, "alice"
        );

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_InvalidPrincipalToken() public {
        uint256 redeemAmount = 50 * bOne;

        vm.warp(expiry);

        // Create a fake principal token address
        address fakePrincipalToken = address(0x123);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(fakePrincipalToken, redeemAmount, bob);

        vm.prank(alice);
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.execute(commands, inputs);
    }
}
