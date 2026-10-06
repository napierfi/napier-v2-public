// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Constants.sol";
import "src/Errors.sol";

contract QuoteSwapYtTest is ZapSwapTest {
    function test_Query_ZeroForOne_Underlying() public {
        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: true,
                token: Token.wrap(address(target)),
                amount: uint128(12 * tOne),
                approx: emptyApproxParams()
            })
        );
    }

    function test_Query_OneForZero_Underlying() public {
        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: false,
                token: Token.wrap(address(target)),
                amount: uint128(1000 * bOne),
                approx: emptyApproxParams()
            })
        );
    }

    function testFuzz_Query_Underlying(bool zeroForOne, uint128 amount, uint256 timestamp) public {
        timestamp = bound(timestamp, block.timestamp, expiry);

        vm.warp(timestamp);

        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                token: Token.wrap(address(target)),
                amount: amount,
                approx: emptyApproxParams()
            })
        );
    }

    function test_Query_ZeroForOne_BaseToken() public {
        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: true,
                token: Token.wrap(address(base)),
                amount: uint128(12 * bOne),
                approx: emptyApproxParams()
            })
        );
    }

    function test_Query_OneForZero_BaseToken() public {
        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: false,
                token: Token.wrap(address(base)),
                amount: uint128(1000 * bOne),
                approx: emptyApproxParams()
            })
        );
    }

    function testFuzz_Query_BaseToken(bool zeroForOne, uint128 amount, uint256 timestamp) public {
        timestamp = bound(timestamp, block.timestamp, expiry);

        vm.warp(timestamp);

        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                token: Token.wrap(address(base)),
                amount: amount,
                approx: emptyApproxParams()
            })
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TEST HELPERS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct TokenBalanceSnapshot {
        uint256 tokenBalance;
        uint256 ytBalance;
    }

    function _snapshotTokenBalance(address user, Token token) internal view returns (TokenBalanceSnapshot memory) {
        return TokenBalanceSnapshot({
            tokenBalance: ERC20(Token.unwrap(token)).balanceOf(user),
            ytBalance: yt.balanceOf(user)
        });
    }

    function _test_Query(TokiQuoter.QuoteSwapParams memory queryParams) internal {
        // Bound and setup tokens for simulation.
        _setupTokens(queryParams);

        // Run simulation.
        (TokenBalanceSnapshot memory stateBefore, TokenBalanceSnapshot memory stateAfter) = _simulateSwap(queryParams);

        // Query quoter with the same params.
        TokiQuoter.QuoteSwapResult memory result = _queryQuoter(queryParams);

        // Verify results.
        if (queryParams.zeroForOne) {
            uint256 spent = stateBefore.tokenBalance - stateAfter.tokenBalance;

            // `amountIn` is the user-specified token amount (max), actual spend may be lower (e.g. YT binsearch).
            assertLe(spent, result.amountIn, "spent<=amountIn");
            assertEq(result.amountOut, stateAfter.ytBalance - stateBefore.ytBalance, "amountOut");
        } else {
            uint256 received = stateAfter.tokenBalance - stateBefore.tokenBalance;

            assertEq(result.amountIn, stateBefore.ytBalance - stateAfter.ytBalance, "amountIn");
            assertEq(result.amountOut, received, "amountOut");
        }
    }

    /// @dev Sets up tokens for swap simulation.
    /// @param queryParams Quoter params - amount will be bounded to avoid degenerate cases.
    function _setupTokens(TokiQuoter.QuoteSwapParams memory queryParams) internal {
        if (queryParams.zeroForOne) {
            queryParams.amount = uint128(bound(queryParams.amount, 1, type(uint128).max));

            // Buying YT with `token` (underlying or base).
            address tokenIn = Token.unwrap(queryParams.token);
            deal(tokenIn, alice, queryParams.amount);
            _approveZap(alice, tokenIn, uint160(queryParams.amount));
        } else {
            queryParams.amount = uint128(bound(queryParams.amount, 1, type(uint128).max));

            // Selling YT for `token`.
            deal(address(yt), alice, queryParams.amount);
            _approveZap(alice, address(yt), uint160(queryParams.amount));
        }
    }

    function _simulateSwap(TokiQuoter.QuoteSwapParams memory queryParams)
        internal
        returns (TokenBalanceSnapshot memory stateBefore, TokenBalanceSnapshot memory stateAfter)
    {
        uint256 snapshot = vm.snapshot();

        stateBefore = _snapshotTokenBalance(alice, queryParams.token);

        (bytes memory commands, bytes[] memory inputs) = _encodeExecuteParams(queryParams);

        vm.prank(alice);
        bytes memory encodedCall = abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs);
        (bool success,) = address(zap).call(encodedCall);

        stateAfter = _snapshotTokenBalance(alice, queryParams.token);

        vm.revertTo(snapshot);

        // Check success after revert for proper error handling
        vm.assume(success);
    }

    function _encodeExecuteParams(TokiQuoter.QuoteSwapParams memory queryParams)
        internal
        view
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bool isBaseToken = Token.unwrap(queryParams.token) == address(base);

        if (queryParams.zeroForOne) {
            if (isBaseToken) {
                // base -> underlying (vault connector) -> YT
                commands = abi.encodePacked(
                    bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)), bytes1(uint8(Commands.YT_SWAP_UNDERLYING_FOR_YT))
                );
                inputs = new bytes[](2);
                inputs[0] = abi.encode(target, base, base, queryParams.amount, ActionConstants.ADDRESS_THIS);
                inputs[1] = abi.encode(
                    queryParams.poolKey,
                    ActionConstants.CONTRACT_BALANCE,
                    0,
                    ActionConstants.MSG_SENDER,
                    ActionConstants.MSG_SENDER,
                    queryParams.approx
                );
            } else {
                // underlying -> YT
                commands = abi.encodePacked(bytes1(uint8(Commands.YT_SWAP_UNDERLYING_FOR_YT)));
                inputs = new bytes[](1);
                inputs[0] = abi.encode(
                    queryParams.poolKey,
                    queryParams.amount,
                    0,
                    ActionConstants.MSG_SENDER,
                    ActionConstants.MSG_SENDER,
                    queryParams.approx
                );
            }
        } else {
            if (isBaseToken) {
                // YT -> underlying -> base (vault connector)
                commands = abi.encodePacked(
                    bytes1(uint8(Commands.YT_SWAP_YT_FOR_UNDERLYING)), bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM))
                );
                inputs = new bytes[](2);
                inputs[0] = abi.encode(queryParams.poolKey, queryParams.amount, 0, ActionConstants.ADDRESS_THIS);
                inputs[1] = abi.encode(target, base, base, ActionConstants.CONTRACT_BALANCE, ActionConstants.MSG_SENDER);
            } else {
                // YT -> underlying
                commands = abi.encodePacked(bytes1(uint8(Commands.YT_SWAP_YT_FOR_UNDERLYING)));
                inputs = new bytes[](1);
                inputs[0] = abi.encode(queryParams.poolKey, queryParams.amount, 0, ActionConstants.MSG_SENDER);
            }
        }
    }

    function _queryQuoter(TokiQuoter.QuoteSwapParams memory queryParams)
        internal
        returns (TokiQuoter.QuoteSwapResult memory)
    {
        vm.prank(alice);
        (bool success, bytes memory data) = address(quoter).staticcall(abi.encodeWithSelector(0x93280641, queryParams));
        vm.assume(success);

        return abi.decode(data, (TokiQuoter.QuoteSwapResult));
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.currency0 = Currency.wrap(address(0xbadface));

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.quoteSwapYt(
            TokiQuoter.QuoteSwapParams({
                poolKey: badKey,
                zeroForOne: true,
                token: Token.wrap(address(base)),
                amount: uint128(1000 * tOne),
                approx: emptyApproxParams()
            })
        );
    }

    function test_RevertWhen_Expired() public override {
        vm.warp(expiry + 1);
        vm.expectRevert(Errors.Expired.selector);
        quoter.quoteSwapYt(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: true,
                token: Token.wrap(address(target)),
                amount: uint128(1000 * tOne),
                approx: emptyApproxParams()
            })
        );
    }

    function test_RevertWhen_NotAuthorizedCallback() public override {
        vm.skip(true);
    }

    function test_RevertWhen_SlippageTooHigh() public override {
        vm.skip(true);
    }
}
