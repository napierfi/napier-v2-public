// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {LiquidityRouterTest} from "./Liquidity.t.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";

import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Events.sol";
import "src/Constants.sol" as Constants;

using SafeCastLib for uint256;
using SafeCastLib for int256;

contract SplitInitialLiquidityTest is LiquidityRouterTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.TP_SPLIT_INITIAL_LIQUIDITY)));
    }

    function _test_Split(uint256 amount0, address recipient, uint256 desiredImpliedRate)
        internal
        returns (BalanceSnapshot memory aliceBalanceAfter, BalanceSnapshot memory recipientBalanceAfter)
    {
        BalanceSnapshot memory recipientBalanceBefore = _snapshotBalance(recipient);

        uint256 supplyBefore = principalToken.totalSupply();

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount0, recipient, desiredImpliedRate);

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);
        recipientBalanceAfter = _snapshotBalance(recipient);
        uint256 supplyAfter = principalToken.totalSupply();

        // Assertions
        assertEq(recipientBalanceAfter.ytBalance, recipientBalanceBefore.ytBalance + supplyAfter - supplyBefore, "yt");
        assertEq(principalToken.balanceOf(address(zap)), supplyAfter - supplyBefore, "pt");
    }

    function test_When_PayerIsUser() public {
        uint256 amount0 = 323 * tOne;

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);
        uint256 underlyingBalanceBefore = poolKey.currency0.balanceOf(address(principalToken));

        _approveZap(alice, poolKey.currency0, amount0.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_Split(amount0, bob, 0.185e18);
        uint256 underlyingBalanceAfter = poolKey.currency0.balanceOf(address(principalToken));

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amount0, "underlying");
        assertEq(
            poolKey.currency0.balanceOf(address(zap)),
            amount0 - (underlyingBalanceAfter - underlyingBalanceBefore),
            "remaining"
        );
    }

    function test_When_PayerIsNotUser() public {
        uint256 amount0 = 112 * tOne;

        vm.prank(alice);
        poolKey.currency0.transfer(address(zap), amount0);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);
        uint256 underlyingBalanceBefore = poolKey.currency0.balanceOf(address(principalToken));

        _approveZap(alice, poolKey.currency0, amount0.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_Split(ActionConstants.CONTRACT_BALANCE, bob, 0.185e18);
        uint256 underlyingBalanceAfter = poolKey.currency0.balanceOf(address(principalToken));

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance, "underlying");
        assertEq(
            poolKey.currency0.balanceOf(address(zap)),
            amount0 - (underlyingBalanceAfter - underlyingBalanceBefore),
            "remaining"
        );
    }

    function test_When_KeyIsNotSet() public {
        vm.skip(true);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 309, alice, 0.185e18);

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 2131220, bob, 0.185e18);

        vm.expectRevert(Errors.Expired.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }
}

contract SplitKeepYtTest is LiquidityRouterTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT)));
    }

    function _test_Split(uint256 amount0, address recipient)
        internal
        returns (BalanceSnapshot memory aliceBalanceAfter, BalanceSnapshot memory recipientBalanceAfter)
    {
        BalanceSnapshot memory recipientBalanceBefore = _snapshotBalance(recipient);

        uint256 supplyBefore = principalToken.totalSupply();

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount0, recipient);

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);
        recipientBalanceAfter = _snapshotBalance(recipient);
        uint256 supplyAfter = principalToken.totalSupply();

        // Assertions
        assertEq(recipientBalanceAfter.ytBalance, recipientBalanceBefore.ytBalance + supplyAfter - supplyBefore, "yt");
        assertEq(principalToken.balanceOf(address(zap)), supplyAfter - supplyBefore, "pt");
    }

    function test_When_PayerIsUser() public {
        uint256 amount0 = 323 * tOne;

        _approveZap(alice, poolKey.currency0, amount0.toUint160());

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);
        uint256 underlyingBalanceBefore = poolKey.currency0.balanceOf(address(principalToken));

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_Split(amount0, bob);
        uint256 underlyingBalanceAfter = poolKey.currency0.balanceOf(address(principalToken));

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amount0, "underlying");
        assertEq(
            poolKey.currency0.balanceOf(address(zap)),
            amount0 - (underlyingBalanceAfter - underlyingBalanceBefore),
            "remaining"
        );
    }

    function test_When_PayerIsNotUser() public {
        uint256 amount0 = 112 * tOne;

        vm.prank(alice);
        poolKey.currency0.transfer(address(zap), amount0);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);
        uint256 underlyingBalanceBefore = poolKey.currency0.balanceOf(address(principalToken));

        _approveZap(alice, poolKey.currency0, amount0.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_Split(ActionConstants.CONTRACT_BALANCE, bob);
        uint256 underlyingBalanceAfter = poolKey.currency0.balanceOf(address(principalToken));

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance, "underlying");
        assertEq(
            poolKey.currency0.balanceOf(address(zap)),
            amount0 - (underlyingBalanceAfter - underlyingBalanceBefore),
            "remaining"
        );
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 20903319, alice);

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 21220, bob);

        vm.expectRevert(Errors.Expired.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }
}

contract SplitNoYtTest is LiquidityRouterTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_NO_YT)));
    }

    function _test_Split(uint256 amount0, ApproximationParams memory approx)
        internal
        returns (BalanceSnapshot memory aliceBalanceAfter)
    {
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount0, approx);

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);

        Uint128x2 balancesAfter = tokiHook.getTotalBalances(poolKey.toId());
        uint256 remainingUnderlying = poolKey.currency0.balanceOf(address(zap));
        uint256 principals = poolKey.currency1.balanceOf(address(zap));

        // Assertions
        // remainingUnderlying : principals = balancesAfter.value0() : balancesAfter.value1()
        assertApproxEqRel(
            remainingUnderlying * balancesAfter.value1(), principals * balancesAfter.value0(), 0.0001e18, "ratio"
        );
    }

    function test_When_PayerIsUser() public {
        uint256 amount0 = 323 * tOne;

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        _approveZap(alice, poolKey.currency0, amount0.toUint160());

        // Execute swap
        ApproximationParams memory approx;
        BalanceSnapshot memory aliceBalanceAfter = _test_Split(amount0, approx);

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amount0, "underlying");
    }

    function test_When_PayerIsNotUser() public {
        uint256 amount0 = 112 * tOne;

        vm.prank(alice);
        poolKey.currency0.transfer(address(zap), amount0);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        // Execute swap
        ApproximationParams memory approx;
        BalanceSnapshot memory aliceBalanceAfter = _test_Split(ActionConstants.CONTRACT_BALANCE, approx);

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance, "underlying");
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        ApproximationParams memory approx;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 20903319, approx);

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        ApproximationParams memory approx;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 21220, approx);

        vm.expectRevert(Errors.Expired.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }

    function test_RevertWhen_InvalidApproximationParams() public {
        _approveZap(alice, poolKey.currency0, type(uint160).max);

        ApproximationParams memory approx = ApproximationParams({guessMin: 3193091, guessMax: 10390, eps: 190909090});
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 2122090, approx);

        vm.expectRevert(Errors.ApproximationParams_InvalidGuess.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }

    function test_RevertWhen_InvalidGuessMin() public {
        _approveZap(alice, poolKey.currency0, type(uint160).max);

        ApproximationParams memory approx = ApproximationParams({guessMin: -3190, guessMax: 10390, eps: 190909090});
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 21220, approx);

        vm.expectRevert(Errors.ApproximationParams_InvalidGuess.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }
}
