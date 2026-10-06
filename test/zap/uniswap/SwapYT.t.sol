// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {LibApproximation} from "src/utils/LibApproximation.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Events.sol";

using SafeCastLib for uint256;
using SafeCastLib for int256;

/// @title Abstract base contract for YT swap router tests
abstract contract ZapSwapTest is UniswapV4ZapBase {
    using CurrencyLibrary for Currency;

    using SafeTransferLib for *;

    address internal naruto = makeAddr("naruto");

    uint256 internal constant DEFAULT_EPS = LibApproximation.DEFAULT_BINSEARCH_EPSILON;

    // Test amounts
    uint256 internal INITIAL_LIQUIDITY_UNDERLYING;
    uint256 internal INITIAL_LIQUIDITY_PT;

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

        // Setup initial assets in the vault
        uint256 assetsBalance = 100000 * bOne;
        deal(address(base), curator, assetsBalance);
        _approve(base, curator, address(target), type(uint256).max);
        vm.prank(curator);
        target.deposit(assetsBalance / 2, curator);

        vm.prank(curator);
        base.transfer(address(target), assetsBalance / 2); // Pump vault share price

        INITIAL_LIQUIDITY_UNDERLYING = 50000 * tOne;
        INITIAL_LIQUIDITY_PT = 80000 * bOne;

        _setupInitialLiquidity();
        _setUpAlice();

        require(target.convertToAssets(tOne) > bOne, "vault share price too low");
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
    }

    function _snapshotBalance(address user) internal view returns (BalanceSnapshot memory state) {
        state.underlyingBalance = Currency.unwrap(poolKey.currency0).balanceOf(user);
        state.ptBalance = Currency.unwrap(poolKey.currency1).balanceOf(user);
        state.ytBalance = yt.balanceOf(user);
    }

    function emptyApproxParams() internal pure returns (ApproximationParams memory approx) {}

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

    function test_RevertWhen_NotAuthorizedCallback() public virtual {
        vm.skip(true);
    }
}

contract SwapUnderlyingForYtTest is ZapSwapTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.YT_SWAP_UNDERLYING_FOR_YT)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   UNDERLYING → YT TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _test_Swap(uint256 amount, uint256 amountOutMinimum, address recipient, address refundReceiver)
        internal
        returns (
            BalanceSnapshot memory aliceBalanceAfter,
            BalanceSnapshot memory bobBalanceAfter,
            BalanceSnapshot memory refundReceiverBalanceAfter
        )
    {
        BalanceSnapshot memory bobBalanceBefore = _snapshotBalance(recipient);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount, amountOutMinimum, recipient, refundReceiver, emptyApproxParams());

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);
        bobBalanceAfter = _snapshotBalance(recipient);
        refundReceiverBalanceAfter = _snapshotBalance(refundReceiver);

        // Assertions
        uint256 ytOut = bobBalanceAfter.ytBalance - bobBalanceBefore.ytBalance;
        assertGe(ytOut, amountOutMinimum, "yt");
        assertEq(ytOut, bobBalanceAfter.ytBalance - bobBalanceBefore.ytBalance, "slippage");
    }

    function test_SwapWhen_PayerIsUser_ExactAmount() public {
        uint256 amountIn = 323 * tOne;
        uint256 amountOutMinimum = 9 * bOne; // Expect at least 9 YT
        address recipient = bob;
        address refundReceiver = naruto;
        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);
        BalanceSnapshot memory refundReceiverBalanceBefore = _snapshotBalance(refundReceiver);

        _approveZap(alice, poolKey.currency0, amountIn.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,, BalanceSnapshot memory refundReceiverBalanceAfter) =
            _test_Swap(amountIn, amountOutMinimum, recipient, refundReceiver);

        // Assertions
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amountIn, "underlying");
        assertEq(
            refundReceiverBalanceAfter.underlyingBalance, refundReceiverBalanceBefore.underlyingBalance, "no refund"
        );
        assertNoFundLeftInZap();
    }

    function test_SwapWhen_PayerIsZap_ContractBalance() public {
        uint256 amountIn = 313 * tOne;
        uint256 amountOutMinimum = 89 * bOne;
        uint256 amount = ActionConstants.CONTRACT_BALANCE;
        address recipient = bob;
        address refundReceiver = naruto;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency0), address(zap), amountIn);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,, BalanceSnapshot memory refundReceiverBalanceAfter) =
            _test_Swap(amount, amountOutMinimum, recipient, refundReceiver);

        // Assertions
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amountIn, "underlying");
        assertGt(refundReceiverBalanceAfter.underlyingBalance, 0, "refund");
        assertNoFundLeftInZap();
    }

    function test_SwapWhen_RefundToMsgSender() public {
        uint256 amountIn = 313 * tOne;
        uint256 amountOutMinimum = 89 * bOne;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency0), address(zap), amountIn);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        uint256 amount = ActionConstants.CONTRACT_BALANCE;
        address refundReceiver = alice;
        (BalanceSnapshot memory aliceBalanceAfter,,) = _test_Swap(amount, amountOutMinimum, bob, refundReceiver);

        // Assertions
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amountIn, "underlying");
        assertNoFundLeftInZap();
    }

    function test_SwapWhen_RefundToRouter() public {
        uint256 amountIn = 313 * tOne;
        uint256 amountOutMinimum = 89 * bOne;

        // Transfer tokens to zap first
        vm.prank(alice);
        SafeTransferLib.safeTransfer(Currency.unwrap(poolKey.currency0), address(zap), amountIn);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        uint256 amount = ActionConstants.CONTRACT_BALANCE;
        address refundReceiver = address(zap);
        (BalanceSnapshot memory aliceBalanceAfter,,) = _test_Swap(amount, amountOutMinimum, bob, refundReceiver);

        // Assertions
        assertGe(aliceBalanceAfter.underlyingBalance, aliceBalanceBefore.underlyingBalance - amountIn, "underlying");
        assertGt(poolKey.currency0.balanceOf(address(zap)), 0, "excess");
    }

    function test_RevertWhen_SlippageTooHigh() public override {
        uint256 amountIn = 313 * tOne;
        uint256 amountOutMinimum = 10000000 * bOne; // Unrealistic minimum

        _approveZap(alice, poolKey.currency0, amountIn.toUint160());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amountIn, amountOutMinimum, alice, naruto, emptyApproxParams());

        bytes memory commands = _getCommands();
        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientYieldTokenOutput.selector);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, poolKey.currency0, type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 319 * tOne, 0, alice, naruto, emptyApproxParams());

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);

        _approveZap(alice, poolKey.currency0, 2000);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 210, 0, bob, naruto, emptyApproxParams());

        vm.expectRevert(Errors.Expired.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }

    function test_RevertWhen_NotAuthorizedCallback() public override {
        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onSupply(210, 310, "malformed");
    }

    function test_RevertWhen_DebtExceedsUnderlyingReceived() public {
        vm.skip(true);
    }

    function test_InvalidApproxParams() public {
        uint256 amountIn = 2121212;

        _approveZap(alice, poolKey.currency0, amountIn.toUint160());

        ApproximationParams memory invalidApprox = ApproximationParams({
            guessMin: int256(200 * 10 ** 18), // Max < Min
            guessMax: int256(10 * 10 ** 18),
            eps: 0.001e18
        });

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amountIn, 0, alice, naruto, invalidApprox);

        vm.expectRevert(); // Should revert on invalid approximation parameters
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }

    function test_RevertWhen_UnlockReverts() public {
        bytes memory returndata = "random error message";
        vm.mockCallRevert(address(poolManager), abi.encodeWithSelector(poolManager.unlock.selector), returndata);

        uint256 amount = 21192;
        _approveZap(alice, poolKey.currency0, amount.toUint160());

        bytes memory commands = _getCommands();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount, 0, bob, naruto, emptyApproxParams());

        vm.expectRevert(returndata);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }
}

contract SwapYtForUnderlyingTest is ZapSwapTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TESTS HELPERS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.YT_SWAP_YT_FOR_UNDERLYING)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   YT → UNDERLYING TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _test_Swap(uint256 amount, uint256 amountOutMinimum, address recipient)
        internal
        returns (BalanceSnapshot memory aliceBalanceAfter, BalanceSnapshot memory bobBalanceAfter)
    {
        BalanceSnapshot memory bobBalanceBefore = _snapshotBalance(recipient);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount, amountOutMinimum, recipient);

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        aliceBalanceAfter = _snapshotBalance(alice);
        bobBalanceAfter = _snapshotBalance(recipient);

        // Assertions
        uint256 underlyingOut = bobBalanceAfter.underlyingBalance - bobBalanceBefore.underlyingBalance;
        assertGe(underlyingOut, amountOutMinimum, "underlying");
    }

    function test_SwapWhen_PayerIsUser_ExactAmount() public {
        uint256 amountIn = 29 * bOne;
        uint256 amountOutMinimum = 921;
        address recipient = bob;
        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        _approveZap(alice, address(yt), amountIn.toUint160());

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_Swap(amountIn, amountOutMinimum, recipient);

        // Assertions
        assertGe(aliceBalanceAfter.ytBalance, aliceBalanceBefore.ytBalance - amountIn, "yt");
        assertNoFundLeftInZap();
    }

    function test_SwapWhen_PayerIsZap_ContractBalance() public {
        uint256 amountIn = 3 * bOne;
        uint256 amountOutMinimum = 39230;
        uint256 amount = ActionConstants.CONTRACT_BALANCE;
        address recipient = bob;

        // Transfer tokens to zap first
        vm.prank(alice);
        yt.transfer(address(zap), amountIn);

        BalanceSnapshot memory aliceBalanceBefore = _snapshotBalance(alice);

        // Execute swap
        (BalanceSnapshot memory aliceBalanceAfter,) = _test_Swap(amount, amountOutMinimum, recipient);

        // Assertions
        assertGe(aliceBalanceAfter.ytBalance, aliceBalanceBefore.ytBalance - amountIn, "yt");
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_SlippageTooHigh() public override {
        uint256 amountIn = 3 * bOne;
        uint256 amountOutMinimum = 10000000 * tOne; // Unrealistic minimum

        _approveZap(alice, address(yt), amountIn.toUint160());

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amountIn, amountOutMinimum, alice);

        bytes memory commands = _getCommands();
        vm.prank(alice);
        vm.expectRevert(Errors.Zap_InsufficientUnderlyingOutput.selector);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.fee = 99;

        _approveZap(alice, address(yt), type(uint160).max);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(badKey, 319 * tOne, 0, alice);

        bytes memory commands = _getCommands();
        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(alice);
        zap.execute(commands, inputs);
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);

        _approveZap(alice, address(yt), 2000);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, 210, 0, bob);

        vm.expectRevert(Errors.Expired.selector);
        vm.prank(alice);
        zap.execute(_getCommands(), inputs);
    }

    function test_RevertWhen_DebtExceedsUnderlyingReceived() public {
        uint256 underlyingDebt = 41_000;
        uint256 credit = 10; // Too small to cover the debt
        bytes memory callbackData = abi.encode(poolKey, underlyingDebt);

        // Simulate a callback from PrincipalToken.issue()
        vm.expectRevert(Errors.Zap_DebtExceedsUnderlyingReceived.selector);
        vm.prank(address(0));
        zap.onUnite(credit, credit, callbackData);
    }

    function test_RevertWhen_NotAuthorizedCallback() public override {
        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onSupply(210, 310, "malformed");
    }

    function test_RevertWhen_UnlockReverts() public {
        bytes memory returndata = "random error message";

        vm.mockCallRevert(address(poolManager), abi.encodeWithSelector(poolManager.unlock.selector), returndata);

        uint256 amount = 963203;
        _approveZap(alice, address(yt), amount.toUint160());

        bytes memory commands = _getCommands();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount, 0, alice);

        vm.prank(alice);
        vm.expectRevert(returndata);
        zap.execute(commands, inputs);
    }
}
