// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Brutalizer} from "../Brutalizer.sol";

import {TwoCryptoNGPrecompiles} from "../TwoCryptoNGPrecompiles.sol";
import {TwoCryptoFactory} from "../TwoCryptoFactory.sol";
import {ITwoCrypto} from "../shared/ITwoCrypto.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import "src/Types.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";

using LibTwoCryptoNG for TwoCrypto;

contract LibTwoCryptoNGTest is Test, Brutalizer {
    address alice = makeAddr("alice");
    address curveAdmin;

    address math;
    address views;
    address blueprint;
    TwoCryptoFactory factory;
    TwoCrypto twoCrypto;

    address coin0 = address(new MockERC20(18));
    address coin1 = address(new MockERC20(6));
    address[2] coins = [coin0, coin1];

    TwoCryptoNGParams twocryptoParams = TwoCryptoNGParams({
        A: 40000000, // 0 unit
        gamma: 0.019 * 1e18, // 1e18 unit
        mid_fee: 0.0006 * 1e8, // 1e8 unit
        out_fee: 0.006 * 1e8, // 1e8 unit
        fee_gamma: 0.07 * 1e18, // 1e18 unit
        allowed_extra_profit: 2e-6 * 1e18, // 1e18 unit
        adjustment_step: 0.00049 * 1e18, // 1e18 unit
        ma_time: 3600, // 0 unit
        initial_price: 0.7e18 // price of the coins[1] against the coins[0] (1e18 unit)
    });

    function setUp() public {
        math = TwoCryptoNGPrecompiles.deployMath();
        views = TwoCryptoNGPrecompiles.deployViews();
        blueprint = TwoCryptoNGPrecompiles.deployBlueprint();

        vm.startPrank(curveAdmin, curveAdmin);
        factory = TwoCryptoFactory(TwoCryptoNGPrecompiles.deployFactory());

        vm.label(math, "twocrypto_math");
        vm.label(views, "twocrypto_views");
        vm.label(blueprint, "twocrypto_blueprint");
        vm.label(address(factory), "twocrypto_factory");

        factory.initialise_ownership(curveAdmin, curveAdmin);
        factory.set_pool_implementation(blueprint, 0);
        factory.set_views_implementation(views);
        factory.set_math_implementation(math);
        vm.stopPrank();

        (bool s, bytes memory ret) = address(factory).call(
            abi.encodeWithSelector(
                factory.deploy_pool.selector,
                "twoCrypto-name",
                "twoCrypto-symbol",
                [coin0, coin1],
                0, // implementation_id
                twocryptoParams
            )
        );
        require(s, "create failed");
        twoCrypto = abi.decode(ret, (TwoCrypto));

        vm.label(coin0, "coin0");
        vm.label(coin1, "coin1");
        vm.label(twoCrypto.unwrap(), "twocrypto");
    }

    function cheat_addLiquidity(uint256 amount0, uint256 amount1) public returns (uint256) {
        deal(coin0, address(this), amount0);
        deal(coin1, address(this), amount1);
        MockERC20(coin0).approve(address(twoCrypto.unwrap()), amount0);
        MockERC20(coin1).approve(address(twoCrypto.unwrap()), amount1);
        return ITwoCrypto(twoCrypto.unwrap()).add_liquidity([amount0, amount1], 0, address(this));
    }

    function test_Coins() public view brutalizeMemory {
        assertEq(coin0, twoCrypto.coins(0));
        assertEq(coin1, twoCrypto.coins(1));
    }

    function test_Coins_RevertWhen_IndexOutOfRange() public brutalizeMemory {
        vm.expectRevert();
        twoCrypto.coins(2); // index out of range
    }

    function test_Coins_RevertWhen_EmptyCode() public brutalizeMemory {
        // The staiccall return success but the returndata size check will fail and then should revert with OOG.
        // The revert happens in the current contract context instead of the staticcall target's context.
        // So we need to use `ext_coins` to catch the revert reason so that `vm.expectRevert` can work.
        vm.expectRevert();
        this.ext_coins(TwoCrypto.wrap(address(0xcafe)), 0);
    }

    /// @dev This is a workaround to catch the revert reason when the revert happens in the current contract context.
    function ext_coins(TwoCrypto target, uint256 i) external view returns (address) {
        return target.coins(i);
    }

    function test_TotalSupply() public brutalizeMemory {
        assertEq(twoCrypto.totalSupply(), 0);

        uint256 amount0 = 100 * 10 ** MockERC20(coin0).decimals();
        uint256 amount1 = 102 * 10 ** MockERC20(coin1).decimals();
        uint256 liquidity = cheat_addLiquidity(amount0, amount1);

        assertEq(twoCrypto.totalSupply(), liquidity);
    }

    function test_TotalSupply_RevertWhen_EmptyCode() public brutalizeMemory {
        vm.expectRevert();
        this.ext_totalSupply(TwoCrypto.wrap(address(0xcafe)));
    }

    /// @dev This is a workaround to catch the revert reason when the revert happens in the current contract context.
    function ext_totalSupply(TwoCrypto target) external view brutalizeMemory returns (uint256) {
        return target.totalSupply();
    }

    function test_balances() public brutalizeMemory {
        uint256 amount0 = 100 * 10 ** MockERC20(coin0).decimals();
        uint256 amount1 = 102 * 10 ** MockERC20(coin1).decimals();
        uint256 liquidity = cheat_addLiquidity(amount0, amount1);

        assertEq(twoCrypto.totalSupply(), liquidity);
    }

    function test_Balances() public brutalizeMemory {
        assertEq(twoCrypto.balances(0), 0);
        assertEq(twoCrypto.balances(1), 0);

        uint256 amount0 = 100 * 10 ** MockERC20(coin0).decimals();
        uint256 amount1 = 102 * 10 ** MockERC20(coin1).decimals();
        cheat_addLiquidity(amount0, amount1);

        assertEq(twoCrypto.balances(0), amount0);
        assertEq(twoCrypto.balances(1), amount1);
    }

    function test_Balances_RevertWhen_EmptyCode() public brutalizeMemory {
        vm.expectRevert();
        this.ext_balances(TwoCrypto.wrap(address(0xcafe)), 0);
        vm.expectRevert();
        this.ext_balances(TwoCrypto.wrap(address(0xcafe)), 1);
    }

    /// @dev This is a workaround to catch the revert reason when the revert happens in the current contract context.
    function ext_balances(TwoCrypto target, uint256 i) external view returns (uint256) {
        return target.balances(i);
    }

    function testFuzz_ExchangeReceived(uint256 i, uint256 dx, uint256 minDy, uint256 mockDy, address receiver)
        public
        brutalizeMemory
    {
        i = i % 2; // 0 or 1
        uint256 j = i == 0 ? 1 : 0;

        // Without receiver param
        // Mock return value of exchange_received
        vm.mockCall(twoCrypto.unwrap(), abi.encodeWithSelector(0x29b244bb, i, j, dx, minDy), abi.encode(mockDy));
        uint256 dy = twoCrypto.exchange_received(i, j, dx, minDy);

        assertEq(dy, mockDy, "return value");

        // With receiver param
        vm.mockCall(
            twoCrypto.unwrap(), abi.encodeWithSelector(0x767691e7, i, j, dx, minDy, receiver), abi.encode(mockDy)
        );
        assembly {
            let random := mul(dx, receiver)
            receiver := or(shl(160, random), receiver)
        }
        uint256 dy2 = twoCrypto.exchange_received(i, j, dx, minDy, receiver);

        assertEq(dy2, mockDy, "return value");
    }

    function testFuzz_ExchangeReceived_RevertWhen_ExchangeFailed(
        uint256 i,
        uint256 dx,
        uint256 minDy,
        address receiver,
        bytes memory revertData
    ) public brutalizeMemory {
        i = i % 2;
        uint256 j = i == 0 ? 1 : 0;

        // Mock revert of exchange_received
        vm.mockCallRevert(twoCrypto.unwrap(), abi.encodeWithSelector(0x29b244bb, i, j, dx, minDy), revertData);
        vm.expectRevert(LibTwoCryptoNG.TwoCryptoNG_ExchangeReceivedFailed.selector);
        this.ext_exchange_received(twoCrypto, i, j, dx, minDy);

        vm.mockCallRevert(twoCrypto.unwrap(), abi.encodeWithSelector(0x767691e7, i, j, dx, minDy, receiver), revertData);
        vm.expectRevert(LibTwoCryptoNG.TwoCryptoNG_ExchangeReceivedFailed.selector);
        this.ext_exchange_received_with_receiver(twoCrypto, i, j, dx, minDy, receiver);
    }

    /// @dev This is a workaround to catch the revert reason when the revert happens in the current contract context.
    /// Need to use `ext_exchange_received` to catch the revert reason because the revert happens in the current contract context.
    function ext_exchange_received(TwoCrypto target, uint256 i, uint256 j, uint256 dx, uint256 minDy)
        external
        brutalizeMemory
        returns (uint256)
    {
        return target.exchange_received(i, j, dx, minDy);
    }

    function ext_exchange_received_with_receiver(
        TwoCrypto target,
        uint256 i,
        uint256 j,
        uint256 dx,
        uint256 minDy,
        address receiver
    ) external brutalizeMemory returns (uint256) {
        return target.exchange_received(i, j, dx, minDy, receiver);
    }

    function testFuzz_GetDy(uint256 i, uint256 dx) public brutalizeMemory {
        i = i % 2;
        uint256 j = i == 0 ? 1 : 0;

        uint256 amount0 = 100 * 10 ** MockERC20(coin0).decimals();
        uint256 amount1 = 104 * 10 ** MockERC20(coin1).decimals();
        cheat_addLiquidity(amount0, amount1);

        dx = bound(dx, 0, i == 0 ? amount0 : amount1);

        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeCall(ITwoCrypto.get_dy, (i, j, dx)));
        vm.assume(s);
        uint256 dy = abi.decode(ret, (uint256));
        uint256 result = LibTwoCryptoNG.get_dy(twoCrypto, i, j, dx);
        assertEq(dy, result, "Mismatch");
    }

    function test_GetDy_Revert() external {
        vm.expectRevert(LibTwoCryptoNG.TwoCryptoNG_GetDyFailed.selector);
        this.ext_get_dy(twoCrypto, 0, 1, 100);
    }

    function ext_get_dy(TwoCrypto target, uint256 i, uint256 j, uint256 dx) external view returns (uint256) {
        return LibTwoCryptoNG.get_dy(target, i, j, dx);
    }

    function testFuzz_AddLiquidity(uint256 amount0, uint256 amount1, address receiver) public brutalizeMemory {
        amount0 = bound(amount0, 0, type(uint96).max);
        amount1 = bound(amount1, 0, type(uint96).max);

        deal(coin0, address(this), amount0);
        deal(coin1, address(this), amount1);
        MockERC20(coin0).approve(address(twoCrypto.unwrap()), amount0);
        MockERC20(coin1).approve(address(twoCrypto.unwrap()), amount1);

        uint256 snapshot = vm.snapshot();
        (bool s, bytes memory ret) =
            twoCrypto.unwrap().call(abi.encodeCall(ITwoCrypto.add_liquidity, ([amount0, amount1], 0, receiver)));
        vm.assume(s);
        uint256 liquidity = abi.decode(ret, (uint256));

        vm.revertTo(snapshot);

        assembly {
            let random := mul(add(amount0, amount1), receiver)
            receiver := or(shl(160, random), receiver)
        }
        uint256 result = twoCrypto.add_liquidity(amount0, amount1, 0, receiver);
        assertEq(result, liquidity, "Mismatch");
    }

    function test_AddLiquidity_Revert() external {
        vm.expectRevert(LibTwoCryptoNG.TwoCryptoNG_AddLiquidityFailed.selector);
        this.ext_add_liquidity(twoCrypto, 100, 100, 0, address(this));
    }

    function ext_add_liquidity(
        TwoCrypto target,
        uint256 amount0,
        uint256 amount1,
        uint256 minLiquidity,
        address receiver
    ) external returns (uint256) {
        return target.add_liquidity(amount0, amount1, minLiquidity, receiver);
    }
}
