// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/src/Test.sol";

import {MockHooklet} from "../mocks/MockHooklet.sol";

import {PoolKey, Currency, IHooks} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {HookletLib} from "../../src/utils/HookletLib.sol";
import {IHooklet} from "../../src/interfaces/IHooklet.sol";
import {ITokiHook} from "../../src/interfaces/ITokiHook.sol";

contract HookletLibTest is Test {
    using HookletLib for IHooklet;
    using HookletLib for MockHooklet;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint160 clearAllHookletPermissionsMask = ~uint160(0) << (10);

    function _deployHooklet(uint160 flags) internal returns (MockHooklet hooklet) {
        uint256 random = uint256(keccak256(msg.data));
        address implementation = address(new MockHooklet());
        hooklet = MockHooklet(address(uint160(random & clearAllHookletPermissionsMask | flags)));
        vm.etch(address(hooklet), implementation.code);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           Flags                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
    }

    function _testFuzz_Permissions(uint160 addr, uint160 flags, Permissions memory permissions) internal view {
        uint160 preAddr = addr & clearAllHookletPermissionsMask;
        MockHooklet hookAddr = MockHooklet(address(preAddr | flags));

        assertEq(hookAddr.hasPermission(HookletLib.BEFORE_INITIALIZE_FLAG), permissions.beforeInitialize);
        assertEq(hookAddr.hasPermission(HookletLib.AFTER_INITIALIZE_FLAG), permissions.afterInitialize);
        assertEq(hookAddr.hasPermission(HookletLib.BEFORE_ADD_LIQUIDITY_FLAG), permissions.beforeAddLiquidity);
        assertEq(hookAddr.hasPermission(HookletLib.AFTER_ADD_LIQUIDITY_FLAG), permissions.afterAddLiquidity);
        assertEq(hookAddr.hasPermission(HookletLib.BEFORE_REMOVE_LIQUIDITY_FLAG), permissions.beforeRemoveLiquidity);
        assertEq(hookAddr.hasPermission(HookletLib.AFTER_REMOVE_LIQUIDITY_FLAG), permissions.afterRemoveLiquidity);
        assertEq(hookAddr.hasPermission(HookletLib.BEFORE_SWAP_FLAG), permissions.beforeSwap);
        assertEq(hookAddr.hasPermission(HookletLib.AFTER_SWAP_FLAG), permissions.afterSwap);
    }

    function testFuzz_MaskConstants(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.ALL_FLAGS_MASK,
            Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true
            })
        );
    }

    function testFuzz_NoPermissions(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            0,
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false
            })
        );
    }

    function testFuzz_Permissions_1(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.BEFORE_INITIALIZE_FLAG | HookletLib.AFTER_INITIALIZE_FLAG,
            Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: false
            })
        );
    }

    function testFuzz_Permissions_2(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.BEFORE_INITIALIZE_FLAG | HookletLib.BEFORE_ADD_LIQUIDITY_FLAG | HookletLib.AFTER_SWAP_FLAG,
            Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: false,
                afterSwap: true
            })
        );
    }

    function testFuzz_Permissions_3(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.BEFORE_ADD_LIQUIDITY_FLAG | HookletLib.AFTER_REMOVE_LIQUIDITY_FLAG,
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: false
            })
        );
    }

    function testFuzz_Permissions_4(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.BEFORE_ADD_LIQUIDITY_FLAG | HookletLib.AFTER_REMOVE_LIQUIDITY_FLAG | HookletLib.BEFORE_SWAP_FLAG
                | HookletLib.AFTER_SWAP_FLAG,
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true
            })
        );
    }

    function testFuzz_Permissions_5(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.AFTER_REMOVE_LIQUIDITY_FLAG,
            Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: true,
                beforeSwap: false,
                afterSwap: false
            })
        );
    }

    function testFuzz_FullPermissions(uint160 addr) public view {
        _testFuzz_Permissions(
            addr,
            HookletLib.BEFORE_INITIALIZE_FLAG | HookletLib.AFTER_INITIALIZE_FLAG | HookletLib.BEFORE_ADD_LIQUIDITY_FLAG
                | HookletLib.AFTER_ADD_LIQUIDITY_FLAG | HookletLib.BEFORE_REMOVE_LIQUIDITY_FLAG
                | HookletLib.AFTER_REMOVE_LIQUIDITY_FLAG | HookletLib.BEFORE_SWAP_FLAG | HookletLib.AFTER_SWAP_FLAG,
            Permissions({
                beforeInitialize: true,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: true,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: true,
                beforeSwap: true,
                afterSwap: true
            })
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Positive Tests                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_HookletBeforeTransfer(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.BEFORE_TRANSFER_FLAG);
        hooklet.hookletBeforeTransfer(alice, key, alice, bob, 1000);
    }

    function test_HookletAfterTransfer(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.AFTER_TRANSFER_FLAG);
        hooklet.hookletAfterTransfer(alice, key, alice, bob, 1000);
    }

    function test_HookletBeforeInitialize(ITokiHook.TokiPoolDeploymentParams calldata params) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.BEFORE_INITIALIZE_FLAG);
        hooklet.hookletBeforeInitialize(alice, params);
    }

    function test_HookletAfterInitialize(ITokiHook.TokiPoolDeploymentParams calldata params, PoolKey calldata key)
        public
    {
        MockHooklet hooklet = _deployHooklet(HookletLib.AFTER_INITIALIZE_FLAG);
        hooklet.hookletAfterInitialize(alice, key, address(0x300), params);
    }

    function test_HookletBeforeAddLiquidity(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.BEFORE_ADD_LIQUIDITY_FLAG);
        hooklet.hookletBeforeAddLiquidity(alice, key, 1000, 2000);
    }

    function test_HookletAfterAddLiquidity(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.AFTER_ADD_LIQUIDITY_FLAG);
        hooklet.hookletAfterAddLiquidity(alice, key, 3000, 1000, 2000);
    }

    function test_HookletBeforeRemoveLiquidity(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.BEFORE_REMOVE_LIQUIDITY_FLAG);
        hooklet.hookletBeforeRemoveLiquidity(alice, key, 3000);
    }

    function test_HookletAfterRemoveLiquidity(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.AFTER_REMOVE_LIQUIDITY_FLAG);
        hooklet.hookletAfterRemoveLiquidity(alice, key, 3000, 1000, 2000);
    }

    function test_HookletBeforeSwap(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.BEFORE_SWAP_FLAG);
        hooklet.hookletBeforeSwap(alice, key, true, -1000);
    }

    function test_HookletAfterSwap(PoolKey calldata key) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.AFTER_SWAP_FLAG);
        hooklet.hookletAfterSwap(alice, key, -1000, 900, 100);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      Self Call Check                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // Skip for now

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   Invalid Return Data                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// forge-config: default.allow_internal_expect_revert = true
    function test_AfterInitialize_RevertWhen_InvalidReturnData(
        ITokiHook.TokiPoolDeploymentParams calldata params,
        PoolKey calldata key
    ) public {
        MockHooklet hooklet = _deployHooklet(HookletLib.AFTER_INITIALIZE_FLAG);

        vm.mockCall(
            address(hooklet),
            abi.encodeWithSelector(IHooklet.afterInitialize.selector),
            abi.encode(bytes4(uint32(0x1234)))
        );
        vm.expectRevert(HookletLib.HookletLib_InvalidHookletResponse.selector);
        this._test_AfterInitialize_RevertWhen_InvalidReturnData(hooklet, params, key);
    }

    /// @dev Need to be a external function so that vm.expectRevert can catch the revert
    function _test_AfterInitialize_RevertWhen_InvalidReturnData(
        MockHooklet hooklet,
        ITokiHook.TokiPoolDeploymentParams calldata params,
        PoolKey calldata key
    ) external {
        hooklet.hookletAfterInitialize(alice, key, address(0x300), params); // Invalid return data
    }

    function test_BeforeInitialize_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_BeforeTransfer_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_AfterTransfer_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_BeforeAddLiquidity_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_AfterAddLiquidity_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_BeforeRemoveLiquidity_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_AfterRemoveLiquidity_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_BeforeSwap_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }

    function test_AfterSwap_RevertWhen_InvalidReturnData() external {
        vm.skip(true);
    }
}
