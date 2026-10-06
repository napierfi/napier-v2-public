// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {IV4Router} from "src/zap/modules/v4-periphery/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";
import {TokiSwap} from "src/utils/TokiSwap.sol";

import "src/Types.sol";
import "src/Constants.sol";
import "src/Errors.sol";

contract QuoteSwapPtTest is ZapSwapTest {
    function test_Query_ZeroForOne_Underlying() public {
        _test_Query(
            TokiQuoter.QuoteSwapParams({
                poolKey: poolKey,
                zeroForOne: true,
                token: Token.wrap(address(target)),
                amount: uint128(1000 * tOne),
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
                amount: uint128(1000 * bOne),
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
                amount: uint128(212 * bOne),
                approx: emptyApproxParams()
            })
        );
    }

    function testFuzz_Query_BaseToken(bool zeroForOne, uint128 amount, uint256 timestamp) public {
        timestamp = bound(timestamp, block.timestamp, expiry - 1);

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
        uint256 ptBalance;
    }

    function _snapshotTokenBalance(address user, Token token) internal view returns (TokenBalanceSnapshot memory) {
        return TokenBalanceSnapshot({
            tokenBalance: ERC20(Token.unwrap(token)).balanceOf(user),
            ptBalance: principalToken.balanceOf(user)
        });
    }

    function _test_Query(TokiQuoter.QuoteSwapParams memory queryParams) internal {
        bool isBaseToken = Token.unwrap(queryParams.token) == address(base);

        // Bound and setup tokens, returns V4 router params for simulation
        _setupTokens(queryParams);

        // Run simulation and capture balance changes (returns deltas)
        (TokenBalanceSnapshot memory stateBefore, TokenBalanceSnapshot memory stateAfter) = _simulateSwap(queryParams);

        // Query quoter with original params
        TokiQuoter.QuoteSwapResult memory result = _queryQuoter(queryParams);

        // Verify results
        if (queryParams.zeroForOne) {
            uint256 spent = stateBefore.tokenBalance - stateAfter.tokenBalance;

            // Verify PT output matches simulation
            assertEq(result.amountOut, stateAfter.ptBalance - stateBefore.ptBalance, "amountOut");
            if (isBaseToken) {
                // For base token: quoter returns the original base token amount as amountIn
                assertEq(result.amountIn, queryParams.amount, "amountIn");
            } else {
                // Preview exact-in of currency0 spends slightly less than the specified amount though router spends fully.
                assertApproxEqRel(result.amountIn, spent, TokiSwap.DEFAULT_BINSEARCH_EPSILON, "amountIn");
            }
        } else {
            uint256 received = stateAfter.tokenBalance - stateBefore.tokenBalance;

            assertEq(result.amountIn, stateBefore.ptBalance - stateAfter.ptBalance, "amountIn");
            assertEq(result.amountOut, received, "amountOut");
        }
    }

    /// @dev Sets up tokens for swap simulation
    /// @param queryParams Quoter params - amount will be bounded based on token supply
    function _setupTokens(TokiQuoter.QuoteSwapParams memory queryParams) internal {
        if (queryParams.zeroForOne) {
            address tokenIn = Token.unwrap(queryParams.token);
            bool isBaseToken = Token.unwrap(queryParams.token) == address(base);

            // Buying PT with token (underlying or base)
            if (isBaseToken) {
                Uint128x2 balances = tokiHook.getTotalBalances(poolKey.toId());
                queryParams.amount = uint128(bound(queryParams.amount, 1, balances.value1()));
            } else {
                // For underlying token: bound based on target supply
                uint256 totalSupply = target.totalSupply();
                if (totalSupply > 0) {
                    queryParams.amount = uint128(bound(queryParams.amount, 1, totalSupply));
                } else {
                    queryParams.amount = uint128(bound(queryParams.amount, 1, type(uint128).max));
                }
            }
            _approveZap(alice, address(tokenIn), uint160(queryParams.amount));
            deal(address(tokenIn), alice, queryParams.amount);
        } else {
            // Selling PT for token
            uint256 totalSupply = principalToken.totalSupply();
            if (totalSupply > 0) {
                queryParams.amount = uint128(bound(queryParams.amount, 1, totalSupply));
            } else {
                queryParams.amount = uint128(bound(queryParams.amount, 1, type(uint128).max));
            }
            deal(address(principalToken), alice, queryParams.amount);
            _approveZap(alice, address(principalToken), uint160(queryParams.amount));
            queryParams.amount = queryParams.amount;
        }
    }

    function _simulateSwap(TokiQuoter.QuoteSwapParams memory queryParams)
        internal
        returns (TokenBalanceSnapshot memory stateBefore, TokenBalanceSnapshot memory stateAfter)
    {
        uint256 snapshot = vm.snapshot();

        // Snapshot balances before swap
        stateBefore = _snapshotTokenBalance(alice, queryParams.token);

        (bytes memory commands, bytes[] memory inputs) = _encodeExecuteParams(queryParams);

        vm.prank(alice);
        bytes memory encodedCall = abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs);
        (bool success,) = address(zap).call(encodedCall);

        // Snapshot balances after swap (before revert)
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
        // Determine tokenIn/tokenOut based on zeroForOne
        address currencyIn = queryParams.zeroForOne ? address(target) : address(principalToken);
        address currencyOut = queryParams.zeroForOne ? address(principalToken) : address(target);

        if (Token.unwrap(queryParams.token) == address(base)) {
            // Base token path
            if (queryParams.zeroForOne) {
                // Deposit via vault connector then swap
                commands =
                    abi.encodePacked(bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)), bytes1(uint8(Commands.V4_SWAP)));

                bytes memory v4Actions = abi.encodePacked(
                    bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                    bytes1(uint8(Actions.SETTLE)),
                    bytes1(uint8(Actions.TAKE_ALL))
                );

                bytes[] memory v4Inputs = new bytes[](3);
                v4Inputs[0] = abi.encode(
                    IV4Router.ExactInputSingleParams({
                        poolKey: queryParams.poolKey,
                        zeroForOne: queryParams.zeroForOne,
                        amountIn: ActionConstants.CONTRACT_BALANCE,
                        amountOutMinimum: 0,
                        hookData: abi.encode(queryParams.approx)
                    })
                );
                v4Inputs[1] = abi.encode(currencyIn, ActionConstants.OPEN_DELTA, false); // SETTLE: currency, amount, payerIsUser=false
                v4Inputs[2] = abi.encode(currencyOut, 0); // minAmount=0

                bytes memory v4Params = abi.encode(v4Actions, v4Inputs);

                inputs = new bytes[](2);
                inputs[0] = abi.encode(target, base, base, queryParams.amount, ActionConstants.ADDRESS_THIS);
                inputs[1] = v4Params;
            } else {
                // Swap then redeem via vault connector
                commands =
                    abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)), bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)));

                bytes memory v4Actions = abi.encodePacked(
                    bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                    bytes1(uint8(Actions.SETTLE_ALL)),
                    bytes1(uint8(Actions.TAKE))
                );

                bytes[] memory v4Inputs = new bytes[](3);
                v4Inputs[0] = abi.encode(
                    IV4Router.ExactInputSingleParams({
                        poolKey: queryParams.poolKey,
                        zeroForOne: queryParams.zeroForOne,
                        amountIn: queryParams.amount,
                        amountOutMinimum: 0,
                        hookData: abi.encode(queryParams.approx)
                    })
                );
                v4Inputs[1] = abi.encode(currencyIn, queryParams.amount); // SETTLE_ALL: PT amount
                v4Inputs[2] = abi.encode(currencyOut, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA); // TAKE: underlying to router

                bytes memory v4Params = abi.encode(v4Actions, v4Inputs);

                inputs = new bytes[](2);
                inputs[0] = v4Params;
                inputs[1] = abi.encode(target, base, base, ActionConstants.CONTRACT_BALANCE, ActionConstants.MSG_SENDER);
            }
        } else {
            // Direct path without vault connector
            commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));

            bytes memory v4Actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            );

            bytes[] memory v4Inputs = new bytes[](3);
            v4Inputs[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: queryParams.poolKey,
                    zeroForOne: queryParams.zeroForOne,
                    amountIn: queryParams.amount,
                    amountOutMinimum: 0,
                    hookData: abi.encode(queryParams.approx)
                })
            );
            v4Inputs[1] = abi.encode(currencyIn, type(uint256).max); // maxAmount=type(uint256).max
            v4Inputs[2] = abi.encode(currencyOut, 0); // minAmount=0
            bytes memory v4Params = abi.encode(v4Actions, v4Inputs);

            inputs = new bytes[](1);
            inputs[0] = v4Params;
        }
    }

    function _queryQuoter(TokiQuoter.QuoteSwapParams memory queryParams)
        internal
        returns (TokiQuoter.QuoteSwapResult memory)
    {
        vm.prank(alice);
        (bool success, bytes memory data) = address(quoter).staticcall(abi.encodeWithSelector(0x782f8563, queryParams));
        vm.assume(success);

        return abi.decode(data, (TokiQuoter.QuoteSwapResult));
    }

    function test_RevertWhen_BadPool() public override {
        PoolKey memory badKey = poolKey;
        badKey.currency0 = Currency.wrap(address(0xbadface));

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.quoteSwapPt(
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
        quoter.quoteSwapPt(
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
