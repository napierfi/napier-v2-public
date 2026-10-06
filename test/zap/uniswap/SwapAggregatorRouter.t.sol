// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as NapierConstants;
import {Commands} from "src/zap/uniswap/Commands.sol";
import {AggregationRouter, RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";

// Mock router that simulates a swap by transferring tokens
contract MockSwapRouter {
    uint256 public refundAmount = 0;
    uint256 public returnAmount = 0;

    function setReturnAmount(uint256 amount) external {
        returnAmount = amount;
    }

    function setRefundAmount(uint256 amount) external {
        refundAmount = amount;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, address receiver) external payable {
        require(returnAmount > 0, "MockSwapRouter: return amount not set");

        // Handle input token transfer
        if (tokenIn == NapierConstants.NATIVE_ETH) {
            // For native ETH, validate msg.value matches amountIn
            require(msg.value == amountIn, "MockSwapRouter: msg.value mismatch");
        } else {
            // For ERC20 tokens, transfer from sender
            SafeTransferLib.safeTransferFrom(tokenIn, msg.sender, address(this), amountIn);
        }

        // Transfer output tokens to receiver (simulating a swap)
        if (tokenOut == NapierConstants.NATIVE_ETH) {
            uint256 balance = address(this).balance;
            require(balance >= returnAmount, "MockSwapRouter: balance insufficient");
            // For native ETH output, send ETH to receiver
            SafeTransferLib.safeTransferETH(receiver, returnAmount);
        } else {
            // For ERC20 output, transfer tokens
            uint256 balance = SafeTransferLib.balanceOf(tokenOut, address(this));
            require(balance >= returnAmount, "MockSwapRouter: balance insufficient");
            SafeTransferLib.safeTransfer(tokenOut, receiver, returnAmount);
        }

        // Refunds logic - refund unused portion of input, but cap it at amountIn
        require(refundAmount <= amountIn, "MockSwapRouter: refund amount exceeds input amount");
        if (refundAmount > 0) {
            if (tokenIn == NapierConstants.NATIVE_ETH) {
                SafeTransferLib.safeTransferETH(msg.sender, refundAmount);
            } else {
                SafeTransferLib.safeTransfer(tokenIn, msg.sender, refundAmount);
            }
        }
    }
}

contract SwapAggregatorRouterERC20Test is UniswapV4ZapBase {
    // Test tokens
    Token tokenA;
    Token tokenB;
    address mockSwapRouter;
    uint256 expectedOut = 5849158749184398129001834299;

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        mockSwapRouter = address(new MockSwapRouter());

        // Deploy test tokens
        tokenA = Token.wrap(address(new MockERC20({_decimals: 6})));
        tokenB = Token.wrap(address(new MockERC20({_decimals: 12})));

        // Setup permissions and fund accounts
        deal(tokenA.unwrap(), alice, 98992313189281);
        vm.deal(alice, 100 ether);
        deal(tokenB.unwrap(), mockSwapRouter, expectedOut);
        vm.deal(mockSwapRouter, expectedOut);

        MockSwapRouter(mockSwapRouter).setReturnAmount(expectedOut);

        vm.startPrank(alice);
        tokenA.erc20().approve(address(permit2), type(uint256).max);
        permit2.approve(tokenA.unwrap(), address(zap), type(uint160).max, type(uint48).max);
        vm.stopPrank();

        // Add mock router to aggregation router - using napierAccessManager
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = AggregationRouter.addRouter.selector;
        selectors[1] = AggregationRouter.removeRouter.selector;
        vm.startPrank(admin);
        napierAccessManager.grantRoles(dev, NapierConstants.DEV_ROLE);
        napierAccessManager.grantTargetFunctionRoles(address(aggregationRouter), selectors, NapierConstants.DEV_ROLE);
        vm.stopPrank();
        vm.prank(dev);
        aggregationRouter.addRouter(mockSwapRouter);
    }

    function _generatePayload(address tokenIn, address tokenOut, uint256 amountIn, address receiver)
        internal
        returns (RouterPayload memory)
    {
        return RouterPayload({
            router: mockSwapRouter,
            payload: abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn, receiver))
        });
    }

    function test_SwapToERC20_When_PayerIsUser() public {
        uint256 amountIn = 50e6;

        RouterPayload memory payload = _generatePayload(tokenA.unwrap(), tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(tokenA, tokenB, amountIn, bob, payload); // Specific amount = transfer from user

        uint256 balanceBefore = tokenA.erc20().balanceOf(alice);

        vm.prank(alice);
        zap.execute(commands, inputs);

        uint256 balanceAfter = tokenA.erc20().balanceOf(alice);

        assertEq(balanceAfter, balanceBefore - amountIn, "alice");
        assertEq(tokenB.erc20().balanceOf(bob), expectedOut, "bob");
    }

    function test_SwapToNativeETH_When_PayerIsUser() public {
        uint256 amountIn = 50e6;

        RouterPayload memory payload = _generatePayload(tokenA.unwrap(), NapierConstants.NATIVE_ETH, amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(tokenA, NapierConstants.NATIVE_ETH, amountIn, bob, payload);

        uint256 balanceBefore = tokenA.erc20().balanceOf(alice);

        vm.prank(alice);
        zap.execute(commands, inputs);

        uint256 balanceAfter = tokenA.erc20().balanceOf(alice);

        assertEq(balanceAfter, balanceBefore - amountIn, "alice");
        assertEq(bob.balance, expectedOut, "bob");
    }

    function test_SwapToERC20_When_PayerIsContract() public {
        uint256 amountIn = 30e6;

        // Pre-fund the zap contract
        vm.prank(alice);
        SafeTransferLib.safeTransfer(tokenA.unwrap(), address(zap), amountIn);

        RouterPayload memory payload = _generatePayload(tokenA.unwrap(), tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(tokenA, tokenB, ActionConstants.CONTRACT_BALANCE, bob, payload); // CONTRACT_BALANCE = use contract balance

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(tokenA.erc20().balanceOf(address(zap)), 0, "zap");
        assertEq(tokenB.erc20().balanceOf(bob), expectedOut, "bob");
    }

    function test_SwapToNativeETH_When_PayerIsContract() public {
        uint256 amountIn = 3121;

        // Pre-fund the zap contract
        vm.prank(alice);
        SafeTransferLib.safeTransfer(tokenA.unwrap(), address(zap), amountIn);

        RouterPayload memory payload = _generatePayload(tokenA.unwrap(), NapierConstants.NATIVE_ETH, amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(tokenA, NapierConstants.NATIVE_ETH, ActionConstants.CONTRACT_BALANCE, bob, payload);

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(tokenA.erc20().balanceOf(address(zap)), 0, "zap");
        assertEq(bob.balance, expectedOut, "bob");
    }

    function test_SwapToERC20_When_PayerIsUser_WithRefund() public {
        uint256 amountIn = 50e6;
        uint256 refundAmount = 5e6; // 5 tokens out of 50 tokens input
        MockSwapRouter(mockSwapRouter).setRefundAmount(refundAmount);

        RouterPayload memory payload = _generatePayload(tokenA.unwrap(), tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(tokenA, tokenB, amountIn, bob, payload); // Specific amount = transfer from user

        uint256 balanceBefore = tokenA.erc20().balanceOf(alice);

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(tokenA.erc20().balanceOf(alice), balanceBefore - amountIn + refundAmount, "alice");
        assertEq(tokenB.erc20().balanceOf(bob), expectedOut, "bob");
    }

    function test_SwapToNativeETH_When_PayerIsUser_WithRefund() public {
        uint256 amountIn = 50e6;
        uint256 refundAmount = 5e6; // 5 tokens out of 50 tokens input
        MockSwapRouter(mockSwapRouter).setRefundAmount(refundAmount);

        RouterPayload memory payload = _generatePayload(tokenA.unwrap(), NapierConstants.NATIVE_ETH, amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(tokenA, NapierConstants.NATIVE_ETH, amountIn, bob, payload);

        uint256 balanceBefore = tokenA.erc20().balanceOf(alice);

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(tokenA.erc20().balanceOf(alice), balanceBefore - amountIn + refundAmount, "alice");
        assertEq(bob.balance, expectedOut, "bob");
    }

    function test_SwapToNativeETH_When_ReceiverIsZap() public {
        uint256 amountIn = 3121;

        // Pre-fund the zap contract
        vm.prank(alice);
        SafeTransferLib.safeTransfer(tokenA.unwrap(), address(zap), amountIn);

        RouterPayload memory payload =
            _generatePayload(tokenA.unwrap(), NapierConstants.NATIVE_ETH, amountIn, address(zap));

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] =
            abi.encode(tokenA, NapierConstants.NATIVE_ETH, ActionConstants.CONTRACT_BALANCE, address(zap), payload);

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(tokenA.erc20().balanceOf(address(zap)), 0, "zap");
        assertEq(address(zap).balance, expectedOut, "zap");
    }
}

contract SwapAggregatorRouterETHTest is UniswapV4ZapBase {
    Token tokenB;
    address mockSwapRouter;
    uint256 expectedOut = 45 * 1e18;

    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        mockSwapRouter = address(new MockSwapRouter());
        tokenB = Token.wrap(address(target)); // Use the existing target token

        // Fund mock router with output tokens
        deal(tokenB.unwrap(), mockSwapRouter, expectedOut);

        MockSwapRouter(mockSwapRouter).setReturnAmount(expectedOut);

        // Add mock router to aggregation router - using napierAccessManager
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = AggregationRouter.addRouter.selector;
        selectors[1] = AggregationRouter.removeRouter.selector;
        vm.startPrank(admin);
        napierAccessManager.grantRoles(dev, NapierConstants.DEV_ROLE);
        napierAccessManager.grantTargetFunctionRoles(address(aggregationRouter), selectors, NapierConstants.DEV_ROLE);
        vm.stopPrank();
        vm.prank(dev);
        aggregationRouter.addRouter(mockSwapRouter);
    }

    function _generatePayload(address tokenIn, address tokenOut, uint256 amountIn, address receiver)
        internal
        returns (RouterPayload memory)
    {
        return RouterPayload({
            router: mockSwapRouter,
            payload: abi.encodeCall(MockSwapRouter.swap, (tokenIn, tokenOut, amountIn, receiver))
        });
    }

    function test_SwapNativeETH_When_PayerIsUser() public {
        uint256 amountIn = 2 ether;
        vm.deal(alice, amountIn);

        RouterPayload memory payload = _generatePayload(NapierConstants.NATIVE_ETH, tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Token.wrap(NapierConstants.NATIVE_ETH), tokenB, amountIn, bob, payload);

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        zap.execute{value: amountIn}(commands, inputs);

        assertEq(alice.balance, balanceBefore - amountIn, "alice");
        assertEq(tokenB.erc20().balanceOf(bob), expectedOut, "bob");
    }

    function test_SwapNativeETH_When_PayerIsContract() public {
        uint256 amountIn = 0.5 ether;

        vm.deal(address(zap), amountIn);

        RouterPayload memory payload = _generatePayload(NapierConstants.NATIVE_ETH, tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] =
            abi.encode(Token.wrap(NapierConstants.NATIVE_ETH), tokenB, ActionConstants.CONTRACT_BALANCE, bob, payload);

        vm.prank(alice);
        zap.execute(commands, inputs);

        assertEq(address(zap).balance, 0, "zap");
        assertEq(tokenB.erc20().balanceOf(bob), expectedOut, "bob");
    }

    function test_SwapNativeETH_When_PayerIsUser_WithRefund() public {
        uint256 amountIn = 2 ether;
        uint256 refundAmount = 0.5 ether;
        vm.deal(alice, amountIn);
        MockSwapRouter(mockSwapRouter).setRefundAmount(refundAmount);

        RouterPayload memory payload = _generatePayload(NapierConstants.NATIVE_ETH, tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Token.wrap(NapierConstants.NATIVE_ETH), tokenB, amountIn, bob, payload);

        uint256 balanceBefore = alice.balance;

        vm.prank(alice);
        zap.execute{value: amountIn}(commands, inputs);

        assertEq(alice.balance, balanceBefore - amountIn + refundAmount, "alice");
        assertEq(tokenB.erc20().balanceOf(bob), expectedOut, "bob");
    }

    function test_RevertWhen_InsufficientETH() public {
        uint256 amountIn = 1 ether;
        uint256 value = amountIn - 1;

        vm.deal(alice, value);

        RouterPayload memory payload = _generatePayload(NapierConstants.NATIVE_ETH, tokenB.unwrap(), amountIn, bob);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.AGGREGATOR_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(Token.wrap(NapierConstants.NATIVE_ETH), tokenB, amountIn, bob, payload);

        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientETH.selector);
        zap.execute{value: value}(commands, inputs);
    }
}
