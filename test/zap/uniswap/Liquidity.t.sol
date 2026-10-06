// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Events.sol";
import "src/Constants.sol" as Constants;

using SafeCastLib for uint256;
using SafeCastLib for int256;

/// @title Abstract base contract for YT swap router tests
abstract contract LiquidityRouterTest is UniswapV4ZapBase {
    using CurrencyLibrary for Currency;

    using SafeTransferLib for *;

    // Test amounts
    uint256 internal INITIAL_LIQUIDITY_UNDERLYING;
    uint256 internal INITIAL_LIQUIDITY_PT;

    address donator = makeAddr("donator");

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public virtual override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();
        _label();

        INITIAL_LIQUIDITY_UNDERLYING = 50000 * tOne;
        INITIAL_LIQUIDITY_PT = 80000 * bOne;

        // Pump up the vault share price
        uint256 total = INITIAL_LIQUIDITY_UNDERLYING * bOne / tOne + INITIAL_LIQUIDITY_PT;
        deal(address(base), donator, type(uint128).max);
        _approve(address(base), donator, address(target), type(uint256).max);
        vm.prank(donator);
        target.deposit(total, alice);
        vm.prank(donator);
        base.transfer(address(target), total / 3); // Donate 1/3 of the total

        require(target.convertToAssets(tOne) > bOne, "vault share price");

        _setupInitialLiquidity();
        _setUpAlice();
    }

    function _setupInitialLiquidity() internal {
        // Setup underlying and PT liquidity in the TokiPool pool
        vm.startPrank(curator);
        deal(Currency.unwrap(poolKey.currency0), curator, INITIAL_LIQUIDITY_UNDERLYING);
        deal(Currency.unwrap(poolKey.currency1), curator, INITIAL_LIQUIDITY_PT);

        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(tokiHook), INITIAL_LIQUIDITY_UNDERLYING);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency1), address(tokiHook), INITIAL_LIQUIDITY_PT);

        tokiHook.addLiquidity(poolKey, INITIAL_LIQUIDITY_UNDERLYING, INITIAL_LIQUIDITY_PT, curator, curator);
        vm.stopPrank();
    }

    function _setUpAlice() internal {
        vm.startPrank(alice);

        // Give alice underlying tokens
        deal(Currency.unwrap(poolKey.currency0), alice, INITIAL_LIQUIDITY_UNDERLYING);

        // Issue PT+YT for alice (for YT → underlying tests)
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(principalToken), type(uint256).max);
        principalToken.supply(INITIAL_LIQUIDITY_UNDERLYING / 2, alice);

        vm.stopPrank();
    }

    function _approveZap(address user, Currency currency, uint160 amount) internal {
        vm.prank(user);
        permit2.approve(Currency.unwrap(currency), address(zap), amount, (block.timestamp * 2).toUint48());
    }

    function _approveZap(address user, address token, uint160 amount) internal {
        _approveZap(user, Currency.wrap(token), amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TEST HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct BalanceSnapshot {
        uint256 underlyingBalance;
        uint256 ptBalance;
        uint256 ytBalance;
        uint256 liquidityBalance;
    }

    function _snapshotBalance(address user) internal view returns (BalanceSnapshot memory state) {
        state.underlyingBalance = Currency.unwrap(poolKey.currency0).balanceOf(user);
        state.ptBalance = Currency.unwrap(poolKey.currency1).balanceOf(user);
        state.ytBalance = yt.balanceOf(user);
        state.liquidityBalance = SafeTransferLib.balanceOf(pool, user);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      EDGE CASE TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_RevertWhen_BadPool() public virtual {
        vm.skip(true);
    }

    function test_RevertWhen_Expired() public virtual {
        vm.skip(true);
    }

    function test_RevertWhen_SlippageTooHigh() public virtual {
        vm.skip(true);
    }
}

contract AddLiquidityTest is LiquidityRouterTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.TP_ADD_LIQUIDITY)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   UNDERLYING → YT TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _test_AddLiquidity(uint256 amount0, uint256 amount1, uint256 liquidityMinimum, address recipient)
        internal
        returns (BalanceSnapshot memory aliceBalanceAfter, BalanceSnapshot memory recipientBalanceAfter)
    {
        BalanceSnapshot memory recipientBalanceBefore = _snapshotBalance(recipient);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount0, amount1, liquidityMinimum, recipient);

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);
        recipientBalanceAfter = _snapshotBalance(recipient);

        // Assertions
        uint256 liquidity = recipientBalanceAfter.liquidityBalance - recipientBalanceBefore.liquidityBalance;
        assertGe(liquidity, liquidityMinimum, "slippage");
        assertEq(
            liquidity, recipientBalanceAfter.liquidityBalance - recipientBalanceBefore.liquidityBalance, "liquidity"
        );
    }

    function test_When_PayerIsUser() public {
        uint256 amount0 = 323 * tOne;
        uint256 amount1 = 323 * bOne;

        uint256 liquidityMinimum = 1222;
        address recipient = bob;

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        _approveZap(alice, poolKey.currency0, amount0.toUint160());
        _approveZap(alice, poolKey.currency1, amount1.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_AddLiquidity(amount0, amount1, liquidityMinimum, recipient);

        // Assertions
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amount0, "underlying");
        assertGe(aliceBalanceAfter.ptBalance, aliceBalanceBefore.ptBalance - amount1, "pt");
        assertNoFundLeftInZap();
    }

    function test_When_PayerIsZap_ContractBalances() public {
        uint256 amount0 = 3013 * tOne;
        uint256 amount1 = 2213 * bOne;
        uint256 liquidityMinimum = 89 * bOne;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency0), address(zap), amount0);

        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency1), address(zap), amount1);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_AddLiquidity(
            ActionConstants.CONTRACT_BALANCE, ActionConstants.CONTRACT_BALANCE, liquidityMinimum, bob
        );

        // Assertions
        // There may be some refund on excess liquidity
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance, "underlying");
        assertGe(aliceBalanceAfter.ptBalance, aliceBalanceBefore.ptBalance, "pt");
        assertNoFundLeftInZap();
    }

    function test_When_PayerIsUser_ContractBalance0() public {
        uint256 amount0 = 3 * tOne;
        uint256 amount1Max = 3130 * bOne; // Expected to be refunded
        uint256 liquidityMinimum = 210;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency0), address(zap), amount0);

        _approveZap(alice, poolKey.currency1, amount1Max.toUint160());

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        (BalanceSnapshot memory aliceBalanceAfter,) =
            _test_AddLiquidity(ActionConstants.CONTRACT_BALANCE, amount1Max, liquidityMinimum, bob);

        // Assertions
        assertEq(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance, "underlying");
        assertGe(aliceBalanceAfter.ptBalance, aliceBalanceBefore.ptBalance - amount1Max, "pt");
        assertNoFundLeftInZap();
    }

    function test_When_PayerIsUser_ContractBalance1() public {
        uint256 amount0Max = 3900 * tOne; // Expected to be refunded
        uint256 amount1 = 1 * bOne;
        uint256 liquidityMinimum = 2;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency1), address(zap), amount1);

        _approveZap(alice, poolKey.currency0, amount0Max.toUint160());

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        (BalanceSnapshot memory aliceBalanceAfter,) =
            _test_AddLiquidity(amount0Max, ActionConstants.CONTRACT_BALANCE, liquidityMinimum, bob);

        // Assertions
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amount0Max, "underlying");
        assertEq(aliceBalanceAfter.ptBalance, aliceBalanceBefore.ptBalance, "pt");
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_SlippageTooHigh() public override {
        uint256 amount0 = 31 * tOne;
        uint256 amount1 = 10 * bOne;
        uint256 liquidityMinimum = 1000000000000e18;

        _approveZap(alice, poolKey.currency0, amount0.toUint160());
        _approveZap(alice, poolKey.currency1, amount1.toUint160());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount0, amount1, liquidityMinimum, alice);

        bytes memory commands = _getCommands();
        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientLiquidity.selector);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, poolKey.currency0, type(uint160).max);
        _approveZap(alice, poolKey.currency1, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 20903319, 2120090, 0, alice);

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);

        _approveZap(alice, poolKey.currency0, type(uint160).max);
        _approveZap(alice, poolKey.currency1, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 21220, 20212, 0, bob);

        vm.expectRevert(Errors.Expired.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }
}

contract RemoveLiquidityTest is LiquidityRouterTest {
    function setUp() public override {
        super.setUp();

        uint256 liquidity = SafeTransferLib.balanceOf(pool, curator);
        vm.prank(curator);
        SafeTransferLib.safeTransfer(pool, alice, liquidity);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   YT → UNDERLYING TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _test_RemoveLiquidity(uint256 liquidity, uint256 amount0Minimum, uint256 amount1Minimum, address recipient)
        internal
        returns (BalanceSnapshot memory aliceBalanceAfter, BalanceSnapshot memory recipientBalanceAfter)
    {
        BalanceSnapshot memory recipientBalanceBefore = _snapshotBalance(recipient);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, liquidity, amount0Minimum, amount1Minimum, recipient);

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);
        recipientBalanceAfter = _snapshotBalance(recipient);

        // Assertions
        uint256 underlyingOut = recipientBalanceAfter.underlyingBalance - recipientBalanceBefore.underlyingBalance;
        uint256 ptOut = recipientBalanceAfter.ptBalance - recipientBalanceBefore.ptBalance;
        assertGe(underlyingOut, amount0Minimum, "underlying");
        assertGe(ptOut, amount1Minimum, "pt");
    }

    function test_When_PayerIsUser() public {
        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice) / 32;
        uint256 amountOut0Minimum = 921;
        uint256 amountOut1Minimum = 311;
        address recipient = bob;

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        _approveZap(alice, pool, liquidity.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) =
            _test_RemoveLiquidity(liquidity, amountOut0Minimum, amountOut1Minimum, recipient);

        // Assertions
        assertEq(aliceBalanceAfter.liquidityBalance, aliceBalanceBefore.liquidityBalance - liquidity, "liquidity");
        assertNoFundLeftInZap();
    }

    function test_When_PayerIsUser_ContractBalance() public {
        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice) / 32;
        uint256 amountOut0Minimum = 921;
        uint256 amountOut1Minimum = 921;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(pool, address(zap), liquidity);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        _test_RemoveLiquidity(ActionConstants.CONTRACT_BALANCE, amountOut0Minimum, amountOut1Minimum, bob);

        BalanceSnapshot memory aliceBalanceAfter = _snapshotBalance(alice);

        assertEq(aliceBalanceAfter.liquidityBalance, aliceBalanceBefore.liquidityBalance, "liquidity");
        assertNoFundLeftInZap();
    }

    function test_When_PayerIsZap_ContractBalance() public {
        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice) / 11;
        uint256 amountOut0Minimum = 31311;
        uint256 amountOut1Minimum = 3092313;
        address recipient = bob;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(pool, address(zap), liquidity);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        // Execute swap using CONTRACT_BALANCE
        (BalanceSnapshot memory aliceBalanceAfter,) =
            _test_RemoveLiquidity(ActionConstants.CONTRACT_BALANCE, amountOut0Minimum, amountOut1Minimum, recipient);

        // Assertions
        assertEq(aliceBalanceAfter.liquidityBalance, aliceBalanceBefore.liquidityBalance, "liquidity");
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_SlippageTooHigh() public override {
        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice) / 32;

        _approveZap(alice, pool, liquidity.toUint160());

        bytes memory commands = _getCommands();
        bytes[] memory inputs = new bytes[](1);

        // 1)
        uint256 amountOut0Minimum = 10000000 * tOne; // Unrealistic minimum
        inputs[0] = abi.encode(poolKey, liquidity, amountOut0Minimum, 0, alice);
        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientUnderlyingOutput.selector);
        zap.execute(commands, inputs);

        // 2)
        uint256 amountOut1Minimum = 10000000 * tOne; // Unrealistic minimum
        inputs[0] = abi.encode(poolKey, liquidity, 0, amountOut1Minimum, alice);
        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientPrincipalTokenOutput.selector);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, pool, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 3903, 0, 0, alice);

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        // N/A - No need to test
    }
}
