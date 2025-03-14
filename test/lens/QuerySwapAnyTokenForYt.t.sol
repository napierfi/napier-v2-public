// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";
import {ImpersonatorTest} from "./Impersonator.t.sol";

import {Impersonator} from "src/lens/Impersonator.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {Factory} from "src/Factory.sol";
import {CustomConversionResolver} from "src/modules/resolvers/CustomConversionResolver.sol";

import {LibBlueprint} from "src/utils/LibBlueprint.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import "src/Errors.sol";
import "src/Types.sol";
import "src/Constants.sol";

/// @dev How to generate 1inch swap call data for testing
/// - from: AGGREGATION_ROUTER
/// - origin: alice=0x328809Bc894f92807417D2dAD6b7C998c1aFdac6
/// - receiver: ZAP_ADDRESS
/// - disableEstimate: true
/// Pass `dstAmount` as `tokenMintEstimate`
contract QuerySwapAnyTokenForYtForkTest is ZapForkTest {
    Impersonator dummy = new Impersonator();

    function whitelistAggregationRouter(address router) internal {
        address[] memory routers = new address[](1);
        routers[0] = router;
        deployCodeTo(
            "src/modules/aggregator/AggregationRouter.sol",
            abi.encode(accessManager, routers),
            address(aggregationRouter)
        );
    }

    function setImpersonator(address addr) internal {
        vm.etch(addr, type(Impersonator).runtimeCode);
    }

    function _testFork_Query(
        Token tokenIn,
        uint256 amountIn,
        Token tokenMintShares,
        uint256 tokenMintEstimate,
        RouterPayload memory swapData
    ) internal {
        deal(tokenIn, alice, amountIn);

        vm.startPrank(alice);

        uint256 snapshot = vm.snapshot(); // Snapshot before the call

        Impersonator.QuerySwapAnyTokenForYtParams memory queryParams = Impersonator.QuerySwapAnyTokenForYtParams({
            zap: address(zap),
            quoter: quoter,
            twoCrypto: twocrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            errorMarginBps: 100,
            tokenMintShares: tokenMintShares,
            tokenMintEstimate: tokenMintEstimate,
            router: swapData.router,
            payload: swapData.payload
        });

        (uint256 preview, ApproxValue sharesFlashBorrowWithMargin,,,) =
            Impersonator(payable(alice)).querySwapAnyTokenForYt(queryParams);
        vm.revertTo(snapshot); // Revert to before the call

        TwoCryptoZap.SwapTokenParams memory params = TwoCryptoZap.SwapTokenParams({
            twoCrypto: twocrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            receiver: alice,
            minPrincipal: preview * 99 / 100,
            deadline: block.timestamp
        });

        uint256 ytBalanceBefore = yt.balanceOf(alice);

        if (tokenIn.isNotNative()) {
            tokenIn.erc20().approve(address(zap), type(uint256).max);
        }

        TwoCryptoZap.SwapTokenInput memory tokenInput =
            TwoCryptoZap.SwapTokenInput({tokenMintShares: tokenMintShares, swapData: swapData});
        uint256 ytOut = zap.swapAnyTokenForYt{value: tokenIn.isNative() ? amountIn : 0}(
            params, sharesFlashBorrowWithMargin, tokenInput
        );
        vm.stopPrank();

        // Verify YT was transferred to receiver
        assertApproxEqAbs(ytOut, preview, 1, "YT output mismatch");
        assertEq(yt.balanceOf(alice) - ytBalanceBefore, ytOut, "YT balance mismatch");

        if (tokenMintShares.isNotNative()) {
            assertEq(tokenMintShares.erc20().balanceOf(address(zap)), 0, "tokenIn balance 0");
        }
        assertNoFundLeft();
    }
}

contract QuerySwapAnyTokenForYt9SETHForkTest is QuerySwapAnyTokenForYtForkTest {
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

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
        whitelistAggregationRouter(ONEINCH_ROUTER);

        setImpersonator(alice);

        _label();
    }

    // 100 USDC -> 0.00465 WETH
    bytes constant ONEINCH_SWAP_CALLDATA_USDC_TO_WETH =
        hex"07ed23790000000000000000000000006ea77f83ec8693666866ece250411c974ab962a8000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda0291300000000000000000000000042000000000000000000000000000000000000060000000000000000000000006ea77f83ec8693666866ece250411c974ab962a8000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede70000000000000000000000000000000000000000000000000000000000989680000000000000000000000000000000000000000000000000000ee1382e1e80010000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000cf0000000000000000000000000000000000000000000000000000b100004e00a0744c8c09833589fcd6edb6e08f4c7c32d4f71b54bda0291390cbe4bdd538d6e9b379bff5fe72c3d67a521de5000000000000000000000000000000000000000000000000000000000000753002a0000000000000000000000000000000000000000000000000000ee1382e1e8001ee63c1e580b4cb800910b228ed3d0834cf79d697127bbb00e5833589fcd6edb6e08f4c7c32d4f71b54bda02913111111125421ca6dc452d289314280a0f8842a650000000000000000000000000000000000fa7a9b25";

    function testFork_Preview0() public {
        // USDC -> [1inch] -> WETH -> [connector] -> 9summit ETH core1.1 -> [pool] -> YT
        Token tokenIn = Token.wrap(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913); // USDC on Base
        uint256 amountIn = 1001e6;
        Token tokenMintShares = Token.wrap(address(weth));
        uint256 tokenMintEstimate = 4653645646797939;
        RouterPayload memory swapData =
            RouterPayload({router: ONEINCH_ROUTER, payload: ONEINCH_SWAP_CALLDATA_USDC_TO_WETH});
        _testFork_Query(tokenIn, amountIn, tokenMintShares, tokenMintEstimate, swapData);
    }
}

contract QuerySwapTokenForYtMEVUSDCForkTest is QuerySwapAnyTokenForYtForkTest {
    /// https://app.morpho.org/ethereum/vault/0xd63070114470f685b75B74D60EEc7c1113d33a3D/mev-capital-usual-usdc
    /// @notice uUSDC (18 decimals)
    address constant MORPHO_VAULT_USDC = 0xd63070114470f685b75B74D60EEc7c1113d33a3D;
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22000000);
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

        whitelistAggregationRouter(ONEINCH_ROUTER);

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

    function testFork_Preview0() public {
        Token tokenIn = Token.wrap(address(weth));
        uint256 amountIn = 0.001e18;
        Token tokenMintShares = USDC;
        uint256 tokenMintEstimate = 2118762;
        bytes memory payload =
            hex"07ed23790000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede700000000000000000000000000000000000000000000000000038d7ea4c6800000000000000000000000000000000000000000000000000000000000001b7ce40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000fb0000000000000000000000000000000000000000000000000000dd00004e00a0744c8c09c02aaa39b223fe8d0a0e5c4f27ead9083c756cc290cbe4bdd538d6e9b379bff5fe72c3d67a521de5000000000000000000000000000000000000000000000000000002ba7def30000c20c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2397ff1542f962076d0bfe58ea045ffa2d347aca06ae4071138002dc6c0397ff1542f962076d0bfe58ea045ffa2d347aca0111111125421ca6dc452d289314280a0f8842a6500000000000000000000000000000000000000000000000000000000001b7ce4c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000fa7a9b25";
        RouterPayload memory swapData = RouterPayload({router: ONEINCH_ROUTER, payload: payload});
        _testFork_Query(tokenIn, amountIn, tokenMintShares, tokenMintEstimate, swapData);
    }

    function testFork_Preview1() public {
        Token tokenIn = Token.wrap(NATIVE_ETH);
        uint256 amountIn = 1 ether;
        Token tokenMintShares = USDC;
        uint256 tokenMintEstimate = 2151963203;
        bytes memory payload =
            hex"07ed23790000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede70000000000000000000000000000000000000000000000000de0b6b3a7640000000000000000000000000000000000000000000000000000000000006d06e6520000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000e90000000000000000000000000000000000000000000000cb00006800004e00a0744c8c09000000000000000000000000000000000000000090cbe4bdd538d6e9b379bff5fe72c3d67a521de5000000000000000000000000000000000000000000000000000aa87bee5380004041c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2d0e30db002a0000000000000000000000000000000000000000000000000000000006d06e652ee63c1e580e0554a476a092703abdb3ef35c80e0d76d32939fc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2111111125421ca6dc452d289314280a0f8842a650000000000000000000000000000000000000000000000fa7a9b25";
        RouterPayload memory swapData = RouterPayload({router: ONEINCH_ROUTER, payload: payload});
        _testFork_Query(tokenIn, amountIn, tokenMintShares, tokenMintEstimate, swapData);
    }

    function getParams(uint256 shares) public returns (TwoCryptoZap.CreateAndAddLiquidityParams memory params) {
        int256 initialImpliedAPY = 0.03 * 1e18;

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

contract QuerySwapTokenForYtWstETHForkTest is QuerySwapAnyTokenForYtForkTest {
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant ONEINCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;

    address custom_conversion_resolver_blueprint =
        LibBlueprint.deployBlueprint(type(CustomConversionResolver).creationCode);

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22000000);
    }

    function setUp() public override {
        Base.setUp();
        assembly {
            sstore(weth.slot, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
        }
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployPeriphery();

        whitelistAggregationRouter(ONEINCH_ROUTER);

        setImpersonator(alice);

        uint256 initialLiquidity = 10 ether;
        deal(WSTETH, alice, initialLiquidity);
        _approve(WSTETH, alice, address(zap), initialLiquidity);

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

    /// @dev Add new resolver deployment here
    function _setUpModules() internal override {
        super._setUpModules();
        vm.prank(admin);
        factory.setResolverBlueprint(custom_conversion_resolver_blueprint, true);
    }

    function _deployTokens() internal override {
        address weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
        assembly {
            sstore(target.slot, WSTETH)
            sstore(base.slot, weth)
        }
    }

    function testFork_Preview0() public {
        Token tokenIn = Token.wrap(NATIVE_ETH);
        uint256 amountIn = 0.001e18;
        Token tokenMintShares = Token.wrap(WSTETH);
        uint256 tokenMintEstimate = 835454878708214;
        bytes memory payload =
            hex"07ed23790000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca00000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede700000000000000000000000000000000000000000000000000038d7ea4c68000000000000000000000000000000000000000000000000000000285dd9294a0dd0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000012000000000000000000000000000000000000000000000000000000000000000e90000000000000000000000000000000000000000000000cb00006800004e00a0744c8c09000000000000000000000000000000000000000090cbe4bdd538d6e9b379bff5fe72c3d67a521de5000000000000000000000000000000000000000000000000000000e8d4a510004041c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2d0e30db002a0000000000000000000000000000000000000000000000000000285dd9294a0ddee63c1e580109830a1aaad605bbf02a9dfa7b0b92ec2fb7daac02aaa39b223fe8d0a0e5c4f27ead9083c756cc2111111125421ca6dc452d289314280a0f8842a650000000000000000000000000000000000000000000000fa7a9b25";
        RouterPayload memory swapData = RouterPayload({router: ONEINCH_ROUTER, payload: payload});
        _testFork_Query(tokenIn, amountIn, tokenMintShares, tokenMintEstimate, swapData);
    }

    function getParams(uint256 shares) public returns (TwoCryptoZap.CreateAndAddLiquidityParams memory params) {
        int256 initialImpliedAPY = 0.03 * 1e18;

        bytes memory resolverArgs = abi.encode(target, base, bytes4(keccak256("getWstETHByStETH(uint256)")));
        uint256 id = vm.snapshot();
        uint256 initialPrice = Impersonator(payable(alice)).queryInitialPrice(
            address(zap), expiry, initialImpliedAPY, custom_conversion_resolver_blueprint, resolverArgs
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
            resolverBlueprint: custom_conversion_resolver_blueprint,
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
