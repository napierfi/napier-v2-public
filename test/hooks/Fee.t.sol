// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";

import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {TokiHook} from "src/hooks/TokiHook.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

abstract contract FeeTest is LiquidityHookBase {
    function test_CollectFees_ZeroForOne_ExactInput() public virtual {
        _addInitialLiquidity(alice, alice);

        _swap({user: alice, zeroForOne: true, amount: -int256(INITIAL_AMOUNT0 / 113), timeJump: 1 hours});

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_CollectFees_ZeroForOne_ExactOutput() public virtual {
        _addInitialLiquidity(alice, alice);

        _swap({user: alice, zeroForOne: true, amount: int256(INITIAL_AMOUNT1 / 113), timeJump: 1 hours});

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_CollectFees_OneForZero_ExactInput() public {
        _addInitialLiquidity(alice, alice);

        _swap({user: alice, zeroForOne: false, amount: -int256(INITIAL_AMOUNT1 / 113), timeJump: 1 hours});

        uint256 fee = stateOf(poolKey.toId()).fees.value0();
        console.log("fee", fee);
        uint256 reserve0 = stateOf(poolKey.toId()).reserves.value0();
        console.log("reserve0", reserve0);
        uint256 rawBalance0 = stateOf(poolKey.toId()).rawBalances.value0();
        console.log("rawBalance0", rawBalance0);

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function testFuzz_CollectFees(int256 amount) public virtual {
        _addInitialLiquidity(alice, alice);

        amount = bound(amount, -int256(INITIAL_AMOUNT0 / 10), int256(INITIAL_AMOUNT0 / 10));
        bool zeroForOne = amount >= 0;
        try this._swap({user: alice, zeroForOne: zeroForOne, amount: amount, timeJump: 1 hours}) {}
        catch {
            vm.assume(false);
        }

        assertCuratorFeeCollection(poolKey, curator);
        assertProtocolFeeCollection(poolKey);
    }

    function test_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        tokiHook.collectCuratorFee(poolKey, bob);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        tokiHook.collectProtocolFee(poolKey);
    }

    function test_RevertWhen_BadPool() public {
        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = TokiHook.collectProtocolFee.selector;
            _grantRoles(napierAccessManager, admin, admin, address(tokiHook), selectors, Constants.DEV_ROLE);
        }

        {
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = TokiHook.collectCuratorFee.selector;
            _grantRoles(accessManager, curator, curator, address(tokiHook), selectors, Constants.DEV_ROLE);
        }

        PoolKey memory invalidKey = _createInvalidPoolKey();

        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(curator);
        tokiHook.collectCuratorFee(invalidKey, curator);

        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(admin);
        tokiHook.collectProtocolFee(invalidKey);
    }
}

contract FeeNoRehypothecationTest is FeeTest {}

contract FeeWithRehypothecationTest is FeeTest {
    function setUp() public virtual override {
        rehypothecationConfig0 =
            RehypothecationConfig({targetRawTokenRatio: 0, maxRawTokenRatio: 0, minRawTokenRatio: 0});

        _setUp({enableRehypothecation0: true});
        _setupVault0();

        (ERC4626 poolVault0,) = vaultsOf(poolKey.toId());
        assertEq(address(poolVault0), address(vault0));
    }
}
