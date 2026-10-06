// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TokiQuoterTest} from "./TokiQuoter.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract QuoteRemoveLiquidityTest is TokiQuoterTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SIMULATE & QUOTE PATTERN                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Core test function following simulate & quote pattern
    function _test_Quote(uint256 liquidity) internal {
        // Run simulation - snapshot, execute, revert
        (uint256 amount0, uint256 amount1) = _simulateRemoveLiquidity(liquidity);

        // Query quoter (updated to struct return)
        TokiQuoter.QuoteRemoveLiquidityResult memory result = quoter.quoteRemoveLiquidity(poolKey, liquidity);

        // Verify results match
        assertEq(result.amount0Out, amount0, "Amount0 should match simulated");
        assertEq(result.amount1Out, amount1, "Amount1 should match simulated");
        assertEq(abi.encode(result).length, 64, "Quote result should contain exactly two uint256 values");
    }

    function _simulateRemoveLiquidity(uint256 liquidity) internal returns (uint256 amount0, uint256 amount1) {
        uint256 snapshot = vm.snapshot();

        vm.prank(alice);
        (bool success, bytes memory ret) =
            address(tokiHook).call(abi.encodeCall(tokiHook.removeLiquidity, (poolKey, liquidity, alice)));

        vm.revertTo(snapshot);

        vm.assume(success);
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Quote() public {
        uint256 initialLiquidity = _addInitialLiquidity(alice, alice);
        _test_Quote(initialLiquidity / 2);
    }

    function testFuzz_Quote(uint256 liquidity) public {
        uint256 initialLiquidity = _addInitialLiquidity(alice, alice);
        liquidity = bound(liquidity, 0, initialLiquidity);

        _test_Quote(liquidity);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        REVERT TESTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_RevertWhen_BadPool() public {
        PoolKey memory invalidPoolKey = poolKey;
        invalidPoolKey.hooks = IHooks(address(0xdead));

        vm.expectRevert(Errors.BadTokiPool.selector);
        quoter.quoteRemoveLiquidity(invalidPoolKey, 1000);
    }
}
