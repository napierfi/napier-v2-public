// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";

contract SupplyTest is UniswapV4ZapBase {
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
    }

    function test_PrincipalTokenSupply() public {
        uint256 supplyAmount = 100 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(bob);
        uint256 ytBalanceBefore = yt.balanceOf(bob);
        uint256 targetBalanceBefore = target.balanceOf(alice);

        // Prepare command for PT_SUPPLY
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(principalToken), // principalToken
            supplyAmount, // shares (vault shares)
            bob // receiver
        );

        // Execute PT_SUPPLY command
        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(bob);
        uint256 ytBalanceAfter = yt.balanceOf(bob);
        uint256 targetBalanceAfter = target.balanceOf(alice);

        // PT and YT should be minted to receiver (bob)
        assertGt(ptBalanceAfter, ptBalanceBefore, "PT should be minted to receiver");
        assertGt(ytBalanceAfter, ytBalanceBefore, "YT should be minted to receiver");

        // PT and YT amounts should be equal
        assertEq(
            ptBalanceAfter - ptBalanceBefore, ytBalanceAfter - ytBalanceBefore, "PT and YT amounts should be equal"
        );

        // Alice should have spent her target tokens
        assertEq(targetBalanceAfter, targetBalanceBefore - supplyAmount, "Alice should have spent target tokens");

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_InsufficientUserBalance() public {
        uint256 transferAmount = 100 * bOne;
        uint256 supplyAmount = 450 * bOne; // Alice will have 400 left after transfer, so this should fail

        // Transfer target tokens to the zap contract first (this reduces alice's balance)
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(target), address(zap), transferAmount);

        // Prepare command for PT_SUPPLY - this will try to transfer from alice (msgSender)
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(principalToken), // principalToken
            supplyAmount, // shares (will try to transfer from alice, not use contract balance)
            bob // receiver
        );

        // Execute PT_SUPPLY command - should revert because alice doesn't have enough balance
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to insufficient balance
        zap.execute(commands, inputs);
    }

    function test_PrincipalTokenSupplyWhen_ContractBalance() public {
        uint256 supplyAmount = 100 * bOne;

        // Transfer target tokens to the zap contract first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(target), address(zap), supplyAmount);

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(bob);
        uint256 ytBalanceBefore = yt.balanceOf(bob);

        // Prepare command for PT_SUPPLY with CONTRACT_BALANCE flag
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(principalToken), // principalToken
            ActionConstants.CONTRACT_BALANCE, // shares (use contract balance)
            bob // receiver
        );

        // Execute PT_SUPPLY command
        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(bob);
        uint256 ytBalanceAfter = yt.balanceOf(bob);
        uint256 zapBalanceAfter = target.balanceOf(address(zap));

        // PT and YT should be minted to receiver (bob)
        assertGt(ptBalanceAfter, ptBalanceBefore, "PT should be minted to receiver");
        assertGt(ytBalanceAfter, ytBalanceBefore, "YT should be minted to receiver");

        // PT and YT amounts should be equal
        assertEq(
            ptBalanceAfter - ptBalanceBefore, ytBalanceAfter - ytBalanceBefore, "PT and YT amounts should be equal"
        );

        // Zap should have used all its target tokens
        assertEq(zapBalanceAfter, 0, "Zap should have used all target tokens");

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenSupplyWhen_AddressThis() public {
        uint256 supplyAmount = 100 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(address(zap));
        uint256 ytBalanceBefore = yt.balanceOf(address(zap));
        uint256 targetBalanceBefore = target.balanceOf(alice);

        // Prepare command for PT_SUPPLY with ADDRESS_THIS as receiver
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(principalToken), // principalToken
            supplyAmount, // shares
            ActionConstants.ADDRESS_THIS // receiver (zap contract)
        );

        // Execute PT_SUPPLY command
        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(address(zap));
        uint256 ytBalanceAfter = yt.balanceOf(address(zap));
        uint256 targetBalanceAfter = target.balanceOf(alice);

        // PT and YT should be minted to zap contract
        assertGt(ptBalanceAfter, ptBalanceBefore, "PT should be minted to zap");
        assertGt(ytBalanceAfter, ytBalanceBefore, "YT should be minted to zap");

        // PT and YT amounts should be equal
        assertEq(
            ptBalanceAfter - ptBalanceBefore, ytBalanceAfter - ytBalanceBefore, "PT and YT amounts should be equal"
        );

        // Alice should have spent her target tokens
        assertEq(targetBalanceAfter, targetBalanceBefore - supplyAmount, "Alice should have spent target tokens");

        // Clean up PT and YT tokens from zap for the assertion
        vm.prank(address(zap));
        principalToken.transfer(address(this), ptBalanceAfter);
        vm.prank(address(zap));
        yt.transfer(address(this), ytBalanceAfter);

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenSupplyWhen_MsgSender() public {
        uint256 supplyAmount = 100 * bOne;

        // Check initial balances
        uint256 ptBalanceBefore = principalToken.balanceOf(alice);
        uint256 ytBalanceBefore = yt.balanceOf(alice);
        uint256 targetBalanceBefore = target.balanceOf(alice);

        // Prepare command for PT_SUPPLY with MSG_SENDER as receiver
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(principalToken), // principalToken
            supplyAmount, // shares
            ActionConstants.MSG_SENDER // receiver (alice)
        );

        // Execute PT_SUPPLY command
        vm.prank(alice);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 ptBalanceAfter = principalToken.balanceOf(alice);
        uint256 ytBalanceAfter = yt.balanceOf(alice);
        uint256 targetBalanceAfter = target.balanceOf(alice);

        // PT and YT should be minted to alice
        assertGt(ptBalanceAfter, ptBalanceBefore, "PT should be minted to alice");
        assertGt(ytBalanceAfter, ytBalanceBefore, "YT should be minted to alice");

        // PT and YT amounts should be equal
        assertEq(
            ptBalanceAfter - ptBalanceBefore, ytBalanceAfter - ytBalanceBefore, "PT and YT amounts should be equal"
        );

        // Alice should have spent her target tokens
        assertEq(targetBalanceAfter, targetBalanceBefore - supplyAmount, "Alice should have spent target tokens");

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_InvalidPrincipalToken() public {
        uint256 supplyAmount = 100 * bOne;

        // Create a fake principal token address
        address fakePrincipalToken = address(0x123);

        // Prepare command for PT_SUPPLY with invalid principal token
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            fakePrincipalToken, // invalid principalToken
            supplyAmount, // shares
            bob // receiver
        );

        // Execute PT_SUPPLY command - should revert
        vm.prank(alice);
        vm.expectRevert(); // ContractValidation should fail
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_InsufficientBalance() public {
        uint256 supplyAmount = 600 * bOne; // More than alice has (500 vault shares)

        // Prepare command for PT_SUPPLY
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_SUPPLY)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            address(principalToken), // principalToken
            supplyAmount, // shares (more than alice has)
            bob // receiver
        );

        // Execute PT_SUPPLY command - should revert
        vm.prank(alice);
        vm.expectRevert(); // Should revert due to insufficient balance
        zap.execute(commands, inputs);
    }
}
