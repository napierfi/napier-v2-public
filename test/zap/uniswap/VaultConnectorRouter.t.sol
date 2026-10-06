// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as NapierConstants;
import {Commands} from "src/zap/uniswap/Commands.sol";

contract VaultConnectorRouterTest is UniswapV4ZapBase {
    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        deal(address(base), alice, 1000 * bOne);
        _approve(base, alice, address(target), type(uint256).max);
        vm.prank(alice);
        target.deposit(1000 * bOne / 2, alice);

        vm.startPrank(alice);
        base.approve(address(permit2), type(uint256).max);
        permit2.approve(address(base), address(zap), type(uint160).max, type(uint48).max);
        target.approve(address(permit2), type(uint256).max);
        permit2.approve(address(target), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();
    }

    function test_Deposit() public {
        uint256 amountIn = 19 * bOne;

        uint256 preview = target.previewDeposit(amountIn);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, base, amountIn, bob); // auto-detection: specific amount = user payment

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(target.balanceOf(bob), preview, "bob");
    }

    function test_DepositWhen_ContractBalance() public {
        uint256 amountIn = 19 * bOne;

        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(base), address(zap), amountIn);

        uint256 preview = target.previewDeposit(amountIn);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, base, ActionConstants.CONTRACT_BALANCE, bob); // auto-detection: CONTRACT_BALANCE = router balance

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(target.balanceOf(bob), preview, "bob");
    }

    function test_Redeem() public {
        uint256 depositAmount = 50 * bOne;
        vm.prank(alice);
        uint256 shares = target.deposit(depositAmount, alice);

        uint256 preview = target.previewRedeem(shares);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, base, shares, bob); // auto-detection: specific amount = user payment

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(base.balanceOf(bob), preview, "bob");
    }

    function test_RedeemWhen_ContractBalance() public {
        uint256 depositAmount = 50 * bOne;
        vm.prank(alice);
        uint256 shares = target.deposit(depositAmount, alice);

        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(target), address(zap), shares);

        uint256 preview = target.previewRedeem(shares);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, base, ActionConstants.CONTRACT_BALANCE, bob); // auto-detection: CONTRACT_BALANCE = full router balance

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(base.balanceOf(bob), preview, "bob");
    }

    function testDeposit_RevertWhen_InvalidConnector() public {
        uint256 amountIn = 19 * bOne;

        vm.startPrank(alice);
        randomToken.approve(address(permit2), type(uint256).max);
        permit2.approve(address(randomToken), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, randomToken, randomToken, amountIn, bob);

        vm.prank(alice);
        vm.expectRevert(); // Connector not compatible with pair
        zap.execute(commands, inputs);
    }

    function testRedeem_RevertWhen_InvalidConnector() public {
        uint256 depositAmount = 50 * bOne;
        vm.prank(alice);
        uint256 shares = target.deposit(depositAmount, alice);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, randomToken, randomToken, shares, bob);

        vm.prank(alice);
        vm.expectRevert(); // Connector not compatible with pair
        zap.execute(commands, inputs);
    }
}

contract VaultConnectorRouterETHTest is VaultConnectorRouterTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function test_DepositNativeETH() public {
        uint256 amountIn = 1 ether;

        vm.deal(alice, amountIn);

        uint256 preview = target.previewDeposit(amountIn);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, NapierConstants.NATIVE_ETH, amountIn, bob); // auto-detection: specific amount = user payment

        vm.prank(alice);
        zap.execute{value: amountIn}(commands, inputs);

        assertEq(target.balanceOf(bob), preview, "bob");
    }

    function test_DepositNativeETHWhen_ContractBalance() public {
        uint256 amountIn = 930390143;
        vm.deal(address(zap), amountIn);

        uint256 preview = target.previewDeposit(amountIn);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, NapierConstants.NATIVE_ETH, amountIn, bob);

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(target.balanceOf(bob), preview, "bob");
    }

    function test_DepositNativeETH_RevertWhen_InsufficientETH() public {
        uint256 amountIn = 1 ether;
        uint256 sentAmount = 0.5 ether;

        vm.deal(alice, sentAmount);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, NapierConstants.NATIVE_ETH, amountIn, bob); // auto-detection: specific amount = user payment

        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientETH.selector);
        zap.execute{value: sentAmount}(commands, inputs);
    }

    function _depositToVault(address sender, uint256 amountIn) internal returns (uint256 shares) {
        vm.prank(sender);
        weth.deposit{value: amountIn}();

        _approve(weth, sender, address(target), type(uint256).max);
        vm.prank(sender);
        shares = target.deposit(amountIn, sender);
    }

    /// @notice Test basic redeem operation receiving ETH instead of WETH
    function test_RedeemToETH() public {
        uint256 depositAmount = 1 ether;

        vm.deal(alice, depositAmount);
        uint256 shares = _depositToVault(alice, depositAmount);

        uint256 preview = target.previewRedeem(shares);
        uint256 aliceBalanceBefore = target.balanceOf(alice);
        uint256 bobBalanceBefore = bob.balance;

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, NapierConstants.NATIVE_ETH, shares, bob); // Output ETH to bob

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(bob.balance, bobBalanceBefore + preview, "bob should receive ETH");
        assertEq(target.balanceOf(alice), aliceBalanceBefore - shares, "alice should have no vault shares left");
    }

    function test_RedeemToETHWhen_ReceiverIsZap() public {
        uint256 depositAmount = 2 ether;

        vm.deal(alice, depositAmount);
        uint256 shares = _depositToVault(alice, depositAmount);

        uint256 preview = target.previewRedeem(shares);
        uint256 aliceBalanceBefore = target.balanceOf(alice);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, NapierConstants.NATIVE_ETH, shares, address(zap));

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(address(zap).balance, preview, "zap should receive ETH");
        assertEq(target.balanceOf(alice), aliceBalanceBefore - shares, "alice should have no vault shares left");
    }

    function test_RedeemToETHWhen_ContractBalance() public {
        uint256 depositAmount = 1.5 ether;

        vm.deal(alice, depositAmount);
        uint256 shares = _depositToVault(alice, depositAmount);

        // Transfer shares to router
        vm.prank(alice);
        SafeTransferLib.safeTransfer(address(target), address(zap), shares);

        uint256 preview = target.previewRedeem(shares);
        uint256 bobBalanceBefore = bob.balance;

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(target, base, NapierConstants.NATIVE_ETH, ActionConstants.CONTRACT_BALANCE, bob); // Full router balance

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(bob.balance, bobBalanceBefore + preview, "bob should receive full ETH amount");
        assertEq(target.balanceOf(address(zap)), 0, "router should have no shares left");
    }
}
