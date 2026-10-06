// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TokiQuoterTest} from "./TokiQuoter.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract QuoteAddLiquidityTest is TokiQuoterTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SIMULATE & QUOTE PATTERN                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Core test function following simulate & quote pattern
    function _test_Quote(uint256 amount0Desired, uint256 amount1Desired) internal {
        // Run simulation - snapshot, execute, revert
        (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent) =
            _simulateAddLiquidity(amount0Desired, amount1Desired);

        // Query quoter
        TokiQuoter.PreviewAddLiquidityResult memory result =
            quoter.quoteAddLiquidity(poolKey, amount0Desired, amount1Desired);

        // Verify results match
        assertEq(result.liquidity, liquidity, "Liquidity should match simulated");
        assertEq(result.amount0Spent, amount0Spent, "Amount0 spent should match simulated");
        assertEq(result.amount1Spent, amount1Spent, "Amount1 spent should match simulated");
    }

    function _simulateAddLiquidity(uint256 amount0Desired, uint256 amount1Desired)
        internal
        returns (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent)
    {
        uint256 snapshot = vm.snapshot();

        vm.prank(alice);
        (bool success, bytes memory ret) = address(tokiHook).call(
            abi.encodeCall(tokiHook.addLiquidity, (poolKey, amount0Desired, amount1Desired, alice, alice))
        );

        vm.revertTo(snapshot);

        vm.assume(success);
        (liquidity, amount0Spent, amount1Spent) = abi.decode(ret, (uint256, uint256, uint256));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Quote() public {
        _test_Quote({amount0Desired: 1000 * tOne, amount1Desired: 1500 * bOne});
    }

    function testFuzz_Quote_WhenZeroLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 timestamp)
        public
    {
        amount0Desired = bound(amount0Desired, INITIAL_AMOUNT0 / 100, INITIAL_AMOUNT0 * 100);
        amount1Desired = bound(amount1Desired, INITIAL_AMOUNT1 / 100, INITIAL_AMOUNT1 * 100);
        timestamp = bound(timestamp, block.timestamp, expiry - 1);

        vm.warp(timestamp);

        _test_Quote(amount0Desired, amount1Desired);
    }

    function testFuzz_Quote_WhenNonZeroLiquidity(uint256 amount0Desired, uint256 amount1Desired, uint256 timestamp)
        public
    {
        amount0Desired = bound(amount0Desired, INITIAL_AMOUNT0 / 100, INITIAL_AMOUNT0 * 100);
        amount1Desired = bound(amount1Desired, INITIAL_AMOUNT1 / 100, INITIAL_AMOUNT1 * 100);
        timestamp = bound(timestamp, block.timestamp, expiry - 1);

        _addInitialLiquidity(chika, chika);

        vm.warp(timestamp);

        _test_Quote(amount0Desired, amount1Desired);
    }

    function test_Quote_When_VaultSpendLessThanRequested(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 timestamp
    ) public {
        amount0Desired = bound(amount0Desired, INITIAL_AMOUNT0 / 100, INITIAL_AMOUNT0 * 100);
        amount1Desired = bound(amount1Desired, INITIAL_AMOUNT1 / 100, INITIAL_AMOUNT1 * 100);
        timestamp = bound(timestamp, block.timestamp, expiry - 1);

        // Initialize pool with first deposit (no fees)
        _addInitialLiquidity(chika, chika);

        // Set fees
        {
            uint256 entryFeeBasisPoints0 = 320;
            uint256 exitFeeBasisPoints0 = 8000;
            vault0.setEntryFeeBasisPoints(entryFeeBasisPoints0);
            vault0.setExitFeeBasisPoints(exitFeeBasisPoints0);
        }
        {
            uint256 entryFeeBasisPoints1 = 6020;
            uint256 exitFeeBasisPoints1 = 700;
            vault1 = _deployRehypothecationVaults(address(principalToken));
            vault1.setEntryFeeBasisPoints(entryFeeBasisPoints1);
            vault1.setExitFeeBasisPoints(exitFeeBasisPoints1);
            _setRehypothecationVaults(poolKey, address(0), address(vault1));
        }

        vm.warp(timestamp);

        _test_Quote(amount0Desired, amount1Desired);
    }

    function test_RevertWhen_Expired_QuoteAddLiquidity() public {
        vm.warp(expiry + 1);
        vm.expectRevert(Errors.Expired.selector);
        quoter.quoteAddLiquidity(poolKey, 100 * tOne, 100 * bOne);
    }
}
