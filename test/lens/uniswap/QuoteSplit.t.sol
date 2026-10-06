// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {TokiHook} from "src/hooks/TokiHook.sol";
import {TokiSwap} from "src/utils/TokiSwap.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

/// @dev SplitNoYt is tested in quote add liquidity test
contract QuoteSplitKeepYtTest is ZapSwapTest {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SIMULATE & QUOTE PATTERN                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Core test function following simulate & quote pattern
    function _test_Quote(uint160 amount0Desired) internal {
        // Run simulation - snapshot, execute, revert
        (uint256 amount0ToTokenize, uint256 amount1Out) = _simulate(amount0Desired);

        // Query quoter
        (uint256 quotedAmount0ToTokenize, uint256 quotedAmount1Out) =
            quoter.quoteSplitUnderlyingTokenLiquidityKeepYt(poolKey, amount0Desired);

        // Verify results match
        assertEq(quotedAmount0ToTokenize, amount0ToTokenize, "Amount0ToTokenize should match simulated");
        assertEq(quotedAmount1Out, amount1Out, "Amount1Out should match simulated");
    }

    function _simulate(uint160 amount0Desired) internal returns (uint256 amount0ToTokenize, uint256 amount1Out) {
        uint256 snapshot = vm.snapshot();

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.TP_SPLIT_UNDERLYING_TOKEN_LIQUIDITY_KEEP_YT)));

        uint256 balanceBefore = target.balanceOf(address(principalToken));
        uint256 supplyBefore = principalToken.totalSupply();

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(poolKey, amount0Desired, alice);

        // Approve zap to spend tokens via permit2
        _approveZap(alice, poolKey.currency0, amount0Desired);

        vm.prank(alice);
        bytes memory encodedCall = abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs);
        (bool success,) = address(zap).call(encodedCall);

        uint256 balanceAfter = target.balanceOf(address(principalToken));
        uint256 supplyAfter = principalToken.totalSupply();

        vm.revertTo(snapshot);

        vm.assume(success);

        amount0ToTokenize = balanceAfter - balanceBefore;
        amount1Out = supplyAfter - supplyBefore;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_QuoteSplitKeepYt() public {
        _test_Quote({amount0Desired: uint160(1000 * tOne)});
    }

    function testFuzz_QuoteSplitKeepYt(uint160 amount0Desired) public {
        amount0Desired = uint160(bound(amount0Desired, 0, 10000 * tOne));

        _test_Quote(amount0Desired);
    }

    function test_RevertWhen_Paused_QuoteSplitKeepYt() public {
        // Pause PT
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: curator, callee: address(principalToken), selectors: selectors, roles: Constants.DEV_ROLE});
        vm.prank(curator);
        principalToken.pause();

        vm.expectRevert(Errors.LibPauseGuard_Paused.selector);
        quoter.quoteSplitUnderlyingTokenLiquidityKeepYt(poolKey, uint160(100 * tOne));
    }

    function test_RevertWhen_Expired_QuoteSplitKeepYt() public {
        vm.warp(expiry + 1);
        vm.expectRevert(Errors.Expired.selector);
        quoter.quoteSplitUnderlyingTokenLiquidityKeepYt(poolKey, uint160(100 * tOne));
    }
}
