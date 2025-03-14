// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";
import {ImpersonatorTest} from "./Impersonator.t.sol";

import {Impersonator} from "src/lens/Impersonator.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {Factory} from "src/Factory.sol";

import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import "src/Errors.sol";
import "src/Types.sol";
import "src/Constants.sol";

contract QuerySwapTokenForYtTest is ImpersonatorTest {
    function _test_Query(Token tokenIn, uint256 amountIn) internal override {
        uint256 errorMarginBps = 100;
        tokenIn = boundToken(tokenIn);
        amountIn = bound(amountIn, 1, type(uint80).max);

        deal(tokenIn, alice, amountIn);

        uint256 snapshot = vm.snapshot();
        vm.prank(alice);
        (bool s1, bytes memory ret1) = alice.call(
            abi.encodeCall(
                Impersonator.querySwapTokenForYt, (address(zap), quoter, twocrypto, tokenIn, amountIn, errorMarginBps)
            )
        );
        if (!s1) {
            // Note we don't expect these slippage errors to happen because impersonator runs preview and simulate swaps based on preview results in a single call.
            assertNotEq(
                bytes4(ret1),
                Errors.Zap_InsufficientYieldTokenOutput.selector,
                "unexpected insufficient yield token output"
            );
        }
        vm.revertTo(snapshot); // Revert to before the call
        vm.assume(s1);

        // Get the preview result
        (uint256 preview, ApproxValue sharesFlashBorrowWithMargin,,,) =
            abi.decode(ret1, (uint256, ApproxValue, uint256, int256, uint256));

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            receiver: address(this),
            minPrincipal: 0,
            deadline: block.timestamp
        });

        _approve(tokenIn, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        (bool s2, bytes memory ret2) =
            address(zap).call(abi.encodeCall(zap.swapTokenForYt, (params, sharesFlashBorrowWithMargin)));

        assertEq(s1, s2, "s1 != s2");
        uint256 actual = abi.decode(ret2, (uint256));
        assertApproxEqAbs(preview, actual, _delta_, "preview != actual");
    }
}

contract QuerySwapTokenForYtForkTest is ZapForkTest {
    Impersonator dummy = new Impersonator();

    function setImpersonator(address addr) internal {
        vm.etch(addr, type(Impersonator).runtimeCode);
    }

    function _test_ExpectRevertWhen_MaximumOutputReached(uint256 amountIn) internal {
        Token tokenIn = Token.wrap(address(target));

        deal(tokenIn, alice, amountIn);

        uint256 errorMarginBps = 10;
        vm.expectRevert(Errors.Quoter_MaximumYtOutputReached.selector);
        vm.prank(alice);
        Impersonator(payable(alice)).querySwapTokenForYt(
            address(zap), quoter, twocrypto, tokenIn, amountIn, errorMarginBps
        );
    }

    function _testFork_Preview(uint256 amountIn) internal {
        Token tokenIn = Token.wrap(address(target));

        deal(tokenIn, alice, amountIn);

        vm.startPrank(alice);

        uint256 snapshot = vm.snapshot(); // Snapshot before the call

        uint256 errorMarginBps = 10;
        (uint256 preview, ApproxValue sharesFlashBorrowWithMargin,,,) = Impersonator(payable(alice)).querySwapTokenForYt(
            address(zap), quoter, twocrypto, tokenIn, amountIn, errorMarginBps
        );
        vm.revertTo(snapshot); // Revert to before the call

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            receiver: alice,
            minPrincipal: preview * 99 / 100,
            deadline: block.timestamp
        });

        uint256 balanceBefore = target.balanceOf(alice);
        uint256 ytBalanceBefore = yt.balanceOf(alice);

        tokenIn.erc20().approve(address(zap), type(uint256).max);
        uint256 ytOut = zap.swapTokenForYt(params, sharesFlashBorrowWithMargin);
        vm.stopPrank();

        // Verify YT was transferred to receiver
        assertApproxEqAbs(ytOut, preview, 1, "YT output mismatch");
        assertEq(yt.balanceOf(alice) - ytBalanceBefore, ytOut, "YT balance mismatch");

        uint256 balanceAfter = target.balanceOf(alice);
        uint256 decrease = balanceBefore - balanceAfter;

        // Note The assertion may fail when refund amount is within the refund tolerance configured by Quoter.
        // The refund tolerance is 1% by default.
        assertApproxEqRel(decrease, params.amountIn, 0.002e18, "amountIn mismatch");
    }
}

contract QuerySwapTokenForYt9SETHForkTest is QuerySwapTokenForYtForkTest {
    constructor() {
        vm.createSelectFork(vm.rpcUrl("base"), 27130000);
    }

    function setUp() public override {
        // It's live on Base: NPR-PT/9SETHcore@8/3/2025
        // https://basescan.org/address/0xaddc1342e89f242cb203ee50a1d751aea0ffe2e9
        assembly {
            // system
            sstore(weth.slot, 0x4200000000000000000000000000000000000006)
            // core
            sstore(napierAccessManager.slot, 0x000000C196dBD8c8b737F95507C2C39271CdcC99)
            sstore(factory.slot, 0x0000001afbCA1E8CF82fe458B33C9954A65b987B)
            // modules
            sstore(twocryptoDeployer.slot, 0xF3e3Aa61dFfA1e069FD27202Cc8845aF05170D2A)
            // instance
            sstore(base.slot, 0x4200000000000000000000000000000000000006) // WETH
            sstore(target.slot, 0x5496b42ad0deCebFab0db944D83260e60D54f667) // 9summit ETH core1.1
            sstore(principalToken.slot, 0x5e253FA1ca1edb4B158Fff5E015D331a273af0E0)
            sstore(yt.slot, 0x54f78109b5Eb45584Be2338580Ed89529165FD34)
            sstore(twocrypto.slot, 0xAddC1342E89f242cb203eE50A1d751aeA0ffe2E9)
        }
        _deployPeriphery();

        setImpersonator(alice);
    }

    function testFork_Preview0() public {
        _testFork_Preview(0.001 ether);
    }

    function testFork_Preview1() public {
        _testFork_Preview(0.01 ether);
    }

    function testFork_Preview2() public {
        _testFork_Preview(0.2 ether);
    }

    function testFork_Preview3() public {
        _testFork_Preview(0.3 ether);
    }

    function testFork_Preview4() public {
        _testFork_Preview(0.4 ether);
    }

    function testFork_Preview5() public {
        _testFork_Preview(0.5 ether);
    }

    function testFork_Preview6() public {
        _testFork_Preview(0.8 ether);
    }

    function testFork_Preview7() public {
        _testFork_Preview(0.9 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_0() public {
        _test_ExpectRevertWhen_MaximumOutputReached(1 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_1() public {
        _test_ExpectRevertWhen_MaximumOutputReached(2 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_2() public {
        _test_ExpectRevertWhen_MaximumOutputReached(3 ether);
    }

    function testForkFuzz_Preview(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.0001 ether, 0.9 ether);
        _testFork_Preview(amountIn);
    }

    function testForkFuzz_RevertWhen_MaximumOutputReached(uint256 amountIn) public {
        amountIn = bound(amountIn, 1 ether, 1000 ether);
        _test_ExpectRevertWhen_MaximumOutputReached(amountIn);
    }
}

contract QuerySwapYtForTokenForkTest is QuerySwapTokenForYtForkTest {
    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21978000);
    }

    function setUp() public override {
        // It's live on Base: NPR-PT/9SETHcore@8/3/2025
        // https://basescan.org/address/0xaddc1342e89f242cb203ee50a1d751aea0ffe2e9
        assembly {
            // system
            sstore(weth.slot, 0x4200000000000000000000000000000000000006)
            // core
            sstore(napierAccessManager.slot, 0x000000C196dBD8c8b737F95507C2C39271CdcC99)
            sstore(factory.slot, 0x0000001afbCA1E8CF82fe458B33C9954A65b987B)
            // modules
            sstore(twocryptoDeployer.slot, 0x129D398a6116a13Cc0D1AE8833B0490C2D53Cf37)
            // instance
            sstore(base.slot, 0x66a1E37c9b0eAddca17d3662D6c05F4DECf3e110) // USR
            sstore(target.slot, 0x1202F5C7b4B9E47a1A484E8B270be34dbbC75055) // wstUSR
            sstore(principalToken.slot, 0xAf2391B932D439138641bE3Ee879b0C853d6e566)
            sstore(yt.slot, 0x54f78109b5Eb45584Be2338580Ed89529165FD34)
            sstore(twocrypto.slot, 0xbF54dEC4014f7dccAF4Fc6DDde08669e188b3B41)
        }
        _deployPeriphery();

        setImpersonator(alice);
    }

    function testFork_Preview0_0() public {
        _testFork_Preview(0.000001 ether);
    }

    function testFork_Preview0() public {
        _testFork_Preview(0.001 ether);
    }

    function testFork_Preview1() public {
        _testFork_Preview(0.01 ether);
    }

    function testFork_Preview2() public {
        _testFork_Preview(0.2 ether);
    }

    function testFork_Preview3() public {
        _testFork_Preview(0.3 ether);
    }

    function testFork_Preview4() public {
        _testFork_Preview(0.4 ether);
    }

    function testFork_Preview5() public {
        _testFork_Preview(0.5 ether);
    }

    function testFork_Preview6() public {
        _testFork_Preview(0.8 ether);
    }

    function testFork_Preview7() public {
        _testFork_Preview(0.9 ether);
    }

    function testFork_Preview8() public {
        _testFork_Preview(100 ether);
    }

    function testFork_Preview9() public {
        _testFork_Preview(1000 ether);
    }

    function testFork_Preview10() public {
        _testFork_Preview(2000 ether);
    }

    function testFork_Preview11() public {
        _testFork_Preview(3000 ether);
    }

    function testFork_Preview12() public {
        _testFork_Preview(3100 ether);
    }

    /// @dev refund tolerance affects bound condition of revert
    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_1() public {
        _test_ExpectRevertWhen_MaximumOutputReached(3200 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_2() public {
        _test_ExpectRevertWhen_MaximumOutputReached(3300 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_3() public {
        _test_ExpectRevertWhen_MaximumOutputReached(3400 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_4() public {
        _test_ExpectRevertWhen_MaximumOutputReached(3500 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_5() public {
        _test_ExpectRevertWhen_MaximumOutputReached(4000 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_6() public {
        _test_ExpectRevertWhen_MaximumOutputReached(4500 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_7() public {
        _test_ExpectRevertWhen_MaximumOutputReached(5000 ether);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_8() public {
        _test_ExpectRevertWhen_MaximumOutputReached(6000 ether);
    }

    function testForkFuzz_Preview(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001 ether, 3100 ether);
        _testFork_Preview(amountIn);
    }
}

contract QuerySwapTokenForYtMEVUSDCForkTest is QuerySwapTokenForYtForkTest {
    /// https://app.morpho.org/ethereum/vault/0xd63070114470f685b75B74D60EEc7c1113d33a3D/mev-capital-usual-usdc
    /// @notice uUSDC (18 decimals)
    address constant MORPHO_VAULT_USDC = 0xd63070114470f685b75B74D60EEc7c1113d33a3D;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21978000);
    }

    function setUp() public override {
        Token usdc = USDC;
        assembly {
            // system
            sstore(weth.slot, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
            // core
            sstore(napierAccessManager.slot, 0x000000C196dBD8c8b737F95507C2C39271CdcC99)
            sstore(factory.slot, 0x0000001afbCA1E8CF82fe458B33C9954A65b987B)
            // modules
            sstore(accessManager_logic.slot, 0x06f7555441dEd67F4F42f5FEdBeEd4a2eb6A3aFA)
            sstore(twocryptoDeployer.slot, 0x129D398a6116a13Cc0D1AE8833B0490C2D53Cf37)
            sstore(constantFeeModule_logic.slot, 0xb01D378CAeB7CD5F84221A250F2DE0bE302c0c4a)
            sstore(resolver_blueprint.slot, 0x913a977eCb5780de7a6e1c074D9Be427C7B7CcE0)
            sstore(pt_blueprint.slot, 0x50f1D68CF2C61bFCBc2E8EB2c8f1fB1EC03688f9)
            sstore(yt_blueprint.slot, 0xF3e3Aa61dFfA1e069FD27202Cc8845aF05170D2A)
            // tokens
            sstore(base.slot, usdc) // USDC
            sstore(target.slot, MORPHO_VAULT_USDC) // MEVUSDC
        }
        uint256 timeToMaturity = 6 * 30 days;

        expiry = block.timestamp + timeToMaturity;
        tOne = 10 ** target.decimals();
        bOne = 10 ** base.decimals();

        uint256 initialLiquidity = 1_000_000 * tOne; // over 1M USDC worth of MEVUSDC
        _deployPeriphery();

        setImpersonator(alice);

        deal(MORPHO_VAULT_USDC, alice, initialLiquidity);
        _approve(MORPHO_VAULT_USDC, alice, address(zap), initialLiquidity);

        TwoCryptoZap.CreateAndAddLiquidityParams memory params = getParams({shares: initialLiquidity});
        vm.prank(alice);
        (address pt, address _yt, address twoCrypto, uint256 liquidity, uint256 principal) =
            zap.createAndAddLiquidity(params);

        console2.log("liquidity", liquidity);
        console2.log("principal", principal);

        // instances
        assembly {
            sstore(principalToken.slot, pt)
            sstore(yt.slot, _yt)
            sstore(twocrypto.slot, twoCrypto)
        }
    }

    /// @dev Too small inputs makes get_dy revert
    // function testFork_Preview0() public {
    //     _testFork_Preview(0.0000001e18); // uUSDC
    // }

    function testFork_Preview0() public {
        _testFork_Preview(0.0001e18);
    }

    function testFork_Preview1() public {
        _testFork_Preview(0.001e18);
    }

    function testFork_Preview2() public {
        _testFork_Preview(0.1e18);
    }

    function testFork_Preview3() public {
        _testFork_Preview(1e18);
    }

    function testFork_Preview4() public {
        _testFork_Preview(10e18);
    }

    function testFork_Preview5() public {
        _testFork_Preview(1000e18);
    }

    function testFork_Preview6() public {
        _testFork_Preview(100_000e18);
    }

    function testFork_Preview7() public {
        _testFork_Preview(1_000_000e18); // 1M uUSDC
    }

    function testForkFuzz_Preview(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.001e18, 1_000_000e18); // 0.001 $ to 1M $
        _testFork_Preview(amountIn);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_0() public {
        _test_ExpectRevertWhen_MaximumOutputReached(100_000_000e18);
    }

    /// @dev Expect revert
    function test_RevertWhen_MaximumOutputReached_1() public {
        _test_ExpectRevertWhen_MaximumOutputReached(1_000_000_000e18);
    }

    function getParams(uint256 shares) public returns (TwoCryptoZap.CreateAndAddLiquidityParams memory params) {
        int256 initialImpliedAPY = 0.3 * 1e18;

        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        uint256 id = vm.snapshot();
        uint256 initialPrice = Impersonator(payable(alice)).queryInitialPrice(
            address(zap), expiry, initialImpliedAPY, resolver_blueprint, resolverArgs
        );
        console2.log("initialPrice", initialPrice);
        vm.revertTo(id);
        // Low-mid params
        bytes memory poolArgs = abi.encode(
            TwoCryptoNGParams({
                A: 31000000, // 0 unit
                gamma: 0.02 * 1e18, // 1e18 unit
                mid_fee: 0.0006 * 1e8, // 1e8 unit
                out_fee: 0.006 * 1e8, // 1e8 unit
                fee_gamma: 0.041 * 1e18, // 1e18 unit
                allowed_extra_profit: 2e-6 * 1e18, // 1e18 unit
                adjustment_step: 0.00049 * 1e18, // 1e18 unit
                ma_time: 3600, // 0 unit
                initial_price: initialPrice
            })
        );
        FeePcts feePcts = FeePctsLib.pack(DEFAULT_SPLIT_RATIO_BPS, 100, 300, 100, BASIS_POINTS);
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](1);
        moduleParams[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });

        params = TwoCryptoZap.CreateAndAddLiquidityParams({
            suite: suite,
            modules: moduleParams,
            expiry: expiry,
            curator: curator,
            shares: shares,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });
    }
}

contract QuerySwapTokenForYtYUSDCForkTest is QuerySwapTokenForYtForkTest {
    /// @notice Yearn Vault v3 USDC (6 decimals)
    address constant YUSDC = 0xBe53A109B494E5c9f97b9Cd39Fe969BE68BF6204;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21978000);
    }

    function setUp() public override {
        Token usdc = USDC;
        assembly {
            // system
            sstore(weth.slot, 0x4200000000000000000000000000000000000006)
            // core
            sstore(napierAccessManager.slot, 0x000000C196dBD8c8b737F95507C2C39271CdcC99)
            sstore(factory.slot, 0x0000001afbCA1E8CF82fe458B33C9954A65b987B)
            // modules
            sstore(accessManager_logic.slot, 0x06f7555441dEd67F4F42f5FEdBeEd4a2eb6A3aFA)
            sstore(twocryptoDeployer.slot, 0x129D398a6116a13Cc0D1AE8833B0490C2D53Cf37)
            sstore(constantFeeModule_logic.slot, 0xb01D378CAeB7CD5F84221A250F2DE0bE302c0c4a)
            sstore(resolver_blueprint.slot, 0x913a977eCb5780de7a6e1c074D9Be427C7B7CcE0)
            sstore(pt_blueprint.slot, 0x50f1D68CF2C61bFCBc2E8EB2c8f1fB1EC03688f9)
            sstore(yt_blueprint.slot, 0xF3e3Aa61dFfA1e069FD27202Cc8845aF05170D2A)
            // tokens
            sstore(base.slot, usdc)
            sstore(target.slot, YUSDC)
        }
        uint256 timeToMaturity = 3 * 30 days; // 3 months

        expiry = block.timestamp + timeToMaturity;
        tOne = 10 ** target.decimals();
        bOne = 10 ** base.decimals();

        uint256 initialLiquidity = 10_000e6; // $10,000
        _deployPeriphery();

        setImpersonator(alice);

        deal(YUSDC, alice, initialLiquidity);
        _approve(YUSDC, alice, address(zap), initialLiquidity);

        TwoCryptoZap.CreateAndAddLiquidityParams memory params = getParams({shares: initialLiquidity});
        vm.prank(alice);
        (address pt, address _yt, address twoCrypto, uint256 liquidity, uint256 principal) =
            zap.createAndAddLiquidity(params);

        console2.log("liquidity", liquidity);
        console2.log("principal", principal);

        // instances
        assembly {
            sstore(principalToken.slot, pt)
            sstore(yt.slot, _yt)
            sstore(twocrypto.slot, twoCrypto)
        }
    }

    function testFork_Preview1() public {
        _testFork_Preview(0.01e6);
    }

    function testFork_Preview2() public {
        _testFork_Preview(0.1e6);
    }

    function testFork_Preview3() public {
        _testFork_Preview(1e6);
    }

    function testFork_Preview4() public {
        _testFork_Preview(100e6);
    }

    function testFork_Preview5() public {
        _testFork_Preview(10_000e6);
    }

    function testFork_Preview6() public {
        _testFork_Preview(30_000e6);
    }

    function testForkFuzz_Preview(uint256 amountIn) public {
        amountIn = bound(amountIn, 0.01e6, 30_000e6);
        _testFork_Preview(amountIn);
    }

    function test_RevertWhen_MaximumOutputReached_0() public {
        _test_ExpectRevertWhen_MaximumOutputReached(100_000 * 1e6);
    }

    function getParams(uint256 shares) public returns (TwoCryptoZap.CreateAndAddLiquidityParams memory params) {
        int256 initialImpliedAPY = 0.05 * 1e18; // 5%

        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        uint256 id = vm.snapshot();
        uint256 initialPrice = Impersonator(payable(alice)).queryInitialPrice(
            address(zap), expiry, initialImpliedAPY, resolver_blueprint, resolverArgs
        );
        console2.log("initialPrice", initialPrice);
        vm.revertTo(id);
        // Low-mid params
        bytes memory poolArgs = abi.encode(
            TwoCryptoNGParams({
                A: 31000000, // 0 unit
                gamma: 0.02 * 1e18, // 1e18 unit
                mid_fee: 0.0006 * 1e8, // 1e8 unit
                out_fee: 0.006 * 1e8, // 1e8 unit
                fee_gamma: 0.041 * 1e18, // 1e18 unit
                allowed_extra_profit: 2e-6 * 1e18, // 1e18 unit
                adjustment_step: 0.00049 * 1e18, // 1e18 unit
                ma_time: 3600, // 0 unit
                initial_price: initialPrice
            })
        );
        FeePcts feePcts = FeePctsLib.pack(DEFAULT_SPLIT_RATIO_BPS, 100, 100, 100, BASIS_POINTS);
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](1);
        moduleParams[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });

        params = TwoCryptoZap.CreateAndAddLiquidityParams({
            suite: suite,
            modules: moduleParams,
            expiry: expiry,
            curator: curator,
            shares: shares,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });
    }
}

// contract QuerySwapTokenForYtMEVCBBTCForkTest is QuerySwapTokenForYtForkTest {
//     using LibTwoCryptoNG for TwoCrypto;

//     /// https://app.morpho.org/ethereum/vault/0x98cF0B67Da0F16E1F8f1a1D23ad8Dc64c0c70E0b/mev-capital-cbbtc
//     /// @notice mcbBTC (18 decimals)
//     address constant MEV_CBBTC = 0x98cF0B67Da0F16E1F8f1a1D23ad8Dc64c0c70E0b;
//     address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

//     constructor() {
//         vm.createSelectFork(vm.rpcUrl("mainnet"), 21978000);
//     }

//     function setUp() public override {
//         assembly {
//             // system
//             sstore(weth.slot, 0x4200000000000000000000000000000000000006)
//             // core
//             sstore(napierAccessManager.slot, 0x000000C196dBD8c8b737F95507C2C39271CdcC99)
//             sstore(factory.slot, 0x0000001afbCA1E8CF82fe458B33C9954A65b987B)
//             // modules
//             sstore(accessManager_logic.slot, 0x06f7555441dEd67F4F42f5FEdBeEd4a2eb6A3aFA)
//             sstore(twocryptoDeployer.slot, 0x129D398a6116a13Cc0D1AE8833B0490C2D53Cf37)
//             sstore(constantFeeModule_logic.slot, 0xb01D378CAeB7CD5F84221A250F2DE0bE302c0c4a)
//             sstore(resolver_blueprint.slot, 0x913a977eCb5780de7a6e1c074D9Be427C7B7CcE0)
//             sstore(pt_blueprint.slot, 0x50f1D68CF2C61bFCBc2E8EB2c8f1fB1EC03688f9)
//             sstore(yt_blueprint.slot, 0xF3e3Aa61dFfA1e069FD27202Cc8845aF05170D2A)
//             // tokens
//             sstore(base.slot, CBBTC)
//             sstore(target.slot, MEV_CBBTC)
//         }
//         uint256 timeToMaturity = 6 * 30 days;

//         expiry = block.timestamp + timeToMaturity;
//         tOne = 10 ** target.decimals(); // 18 decimals for mcbBTC
//         bOne = 10 ** base.decimals();

//         uint256 initialLiquidity = 0.1e18; // $10,000
//         // uint256 initialLiquidity = 10e18; // $1M
//         _deployPeriphery();

//         setImpersonator(alice);

//         deal(MEV_CBBTC, alice, initialLiquidity);
//         _approve(MEV_CBBTC, alice, address(zap), initialLiquidity);

//         TwoCryptoZap.CreateAndAddLiquidityParams memory params = getParams({shares: initialLiquidity});
//         vm.prank(alice);
//         (address pt, address _yt, address twoCrypto, uint256 liquidity, uint256 principal) =
//             zap.createAndAddLiquidity(params);

//         console2.log("liquidity", liquidity);
//         console2.log("principal", principal);

//         // instances
//         assembly {
//             sstore(principalToken.slot, pt)
//             sstore(yt.slot, _yt)
//             sstore(twocrypto.slot, twoCrypto)
//         }
//     }

//     function testFork_Preview0() public {
//         _testFork_Preview(0.0000001e18); // $0.0091
//     }

//     function testFork_Preview1() public {
//         _testFork_Preview(0.00001e18); // $1
//     }

//     function testFork_Preview2() public {
//         _testFork_Preview(0.0001e18); // $10
//     }

//     function testFork_Preview3() public {
//         _testFork_Preview(0.001e18); // $100
//     }

//     function testFork_Preview4() public {
//         _testFork_Preview(0.01e18); // $1000
//     }

//     function testFork_Preview5() public {
//         _testFork_Preview(1e18);
//     }

//     function testFork_Preview6() public {
//         _test_ExpectRevertWhen_MaximumOutputReached(10e18);
//     }

//     function testFork_ExchangePT() public {
//         deal(address(principalToken), alice, type(uint128).max);
//         deal(address(target), alice, type(uint128).max);
//         _approve(principalToken, alice, twocrypto.unwrap(), type(uint256).max);
//         _approve(target, alice, twocrypto.unwrap(), type(uint256).max);

//         uint256 balance0 = twocrypto.balances(TARGET_INDEX);
//         uint256 balance1 = twocrypto.balances(PT_INDEX);

//         bool s;
//         uint256 price = twocrypto.price_oracle();
//         console2.log("price", price);
//         // s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 5, 0);
//         s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 10, 0);
//         // s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 100, 0);
//         // s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 1000, 0);
//         // s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 10000, 0);
//         // s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 100000, 0);
//         // s = s || _exchange(alice, PT_INDEX, TARGET_INDEX, balance1 / 1000000, 0);

//         // s = s || _exchange(alice, TARGET_INDEX, PT_INDEX, balance0 / 100, 0);
//         // s = s || _exchange(alice, TARGET_INDEX, PT_INDEX, balance0 / 1000, 0);
//         // s = s || _exchange(alice, TARGET_INDEX, PT_INDEX, balance0 / 10000, 0);
//         // s = s || _exchange(alice, TARGET_INDEX, PT_INDEX, balance0 / 100000, 0);
//         // s = s || _exchange(alice, TARGET_INDEX, PT_INDEX, balance0 / 1000000, 0);
//         require(s, "Keep failing exchange");
//     }

//     function _exchange(address sender, uint256 i, uint256 j, uint256 dx, uint256 minDy) internal returns (bool) {
//         vm.prank(sender);
//         (bool s, bytes memory ret) = twocrypto.unwrap().call(
//             abi.encodeWithSignature("exchange(uint256,uint256,uint256,uint256)", PT_INDEX, TARGET_INDEX, dx, 0)
//         );
//         return s;
//     }

//     // function testForkFuzz_Preview(uint256 amountIn) public {
//     //     amountIn = bound(amountIn, 0.001e18, 1_000_000e18); // 0.001 $ to 1M $
//     //     _testFork_Preview(amountIn);
//     // }

//     /// @dev Expect revert
//     function testFork_Previe8() public {
//         _test_ExpectRevertWhen_MaximumOutputReached(10e18);
//     }

//     /// @dev Expect revert
//     function testFork_Previe9() public {
//         _test_ExpectRevertWhen_MaximumOutputReached(100e18);
//     }

//     function getParams(uint256 shares) public returns (TwoCryptoZap.CreateAndAddLiquidityParams memory params) {
//         int256 initialImpliedAPY = 0.01 * 1e18;

//         bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
//         uint256 id = vm.snapshot();
//         uint256 initialPrice = Impersonator(payable(alice)).queryInitialPrice(
//             address(zap), expiry, initialImpliedAPY, resolver_blueprint, resolverArgs
//         );
//         console2.log("initialPrice", initialPrice);
//         vm.revertTo(id);
//         // Low-mid params
//         bytes memory poolArgs = abi.encode(
//             TwoCryptoNGParams({
//                 A: 31000000, // 0 unit
//                 gamma: 0.02 * 1e18, // 1e18 unit
//                 mid_fee: 0.0006 * 1e8, // 1e8 unit
//                 out_fee: 0.006 * 1e8, // 1e8 unit
//                 fee_gamma: 0.041 * 1e18, // 1e18 unit
//                 allowed_extra_profit: 2e-6 * 1e18, // 1e18 unit
//                 adjustment_step: 0.00049 * 1e18, // 1e18 unit
//                 ma_time: 3600, // 0 unit
//                 initial_price: initialPrice
//             })
//         );
//         FeePcts feePcts = FeePctsLib.pack(DEFAULT_SPLIT_RATIO_BPS, 100, 300, 100, BASIS_POINTS);
//         Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](1);
//         moduleParams[0] = Factory.ModuleParam({
//             moduleType: FEE_MODULE_INDEX,
//             implementation: constantFeeModule_logic,
//             immutableData: abi.encode(feePcts)
//         });
//         Factory.Suite memory suite = Factory.Suite({
//             accessManagerImpl: accessManager_logic,
//             resolverBlueprint: resolver_blueprint,
//             ptBlueprint: pt_blueprint,
//             poolDeployerImpl: address(twocryptoDeployer),
//             poolArgs: poolArgs,
//             resolverArgs: resolverArgs
//         });

//         params = TwoCryptoZap.CreateAndAddLiquidityParams({
//             suite: suite,
//             modules: moduleParams,
//             expiry: expiry,
//             curator: curator,
//             shares: shares,
//             minLiquidity: 0,
//             minYt: 0,
//             deadline: block.timestamp
//         });
//     }
// }
