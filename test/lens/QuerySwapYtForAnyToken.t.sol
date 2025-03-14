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
/// - receiver: alice
/// - disableEstimate: true
/// Check preview of swap and get shares
/// Pass `srcAmount` * slippage as `tokenRedeemEstimate`
contract QuerySwapYtForAnyTokenForkTest is ZapForkTest {
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
        Token tokenOut,
        uint256 principal,
        Token tokenRedeemShares,
        uint256 tokenRedeemEstimate,
        RouterPayload memory swapData
    ) internal {
        deal(address(yt), alice, principal);

        vm.startPrank(alice);

        uint256 snapshot = vm.snapshot(); // Snapshot before the call

        Impersonator.QuerySwapYtForAnyTokenParams memory queryParams = Impersonator.QuerySwapYtForAnyTokenParams({
            zap: address(zap),
            quoter: quoter,
            twoCrypto: twocrypto,
            principal: principal,
            tokenOut: tokenOut,
            errorMarginBps: 100,
            tokenRedeemShares: tokenRedeemShares,
            tokenRedeemEstimate: tokenRedeemEstimate,
            router: swapData.router,
            payload: swapData.payload
        });

        (uint256 preview, uint256 ytSpent, ApproxValue getDxResultWithMargin,,,) =
            Impersonator(payable(alice)).querySwapYtForAnyToken(queryParams);
        vm.revertTo(snapshot); // Revert to before the call

        TwoCryptoZap.SwapYtParams memory params = TwoCryptoZap.SwapYtParams({
            twoCrypto: twocrypto,
            principal: principal,
            tokenOut: tokenOut,
            amountOutMin: preview * 99 / 100,
            receiver: alice,
            deadline: block.timestamp
        });

        yt.approve(address(zap), type(uint256).max);

        uint256 ytBalanceBefore = yt.balanceOf(alice);

        TwoCryptoZap.SwapTokenOutput memory tokenOutput =
            TwoCryptoZap.SwapTokenOutput({tokenRedeemShares: tokenRedeemShares, swapData: swapData});
        uint256 amountOut = zap.swapYtForAnyToken(params, getDxResultWithMargin, tokenOutput);
        vm.stopPrank();

        assertApproxEqAbs(amountOut, preview, 1, "TokenOut mismatch");
        assertApproxEqAbs(ytBalanceBefore - yt.balanceOf(alice), ytSpent, 1, "YT balance mismatch");

        if (tokenRedeemShares.isNotNative()) {
            assertEq(tokenRedeemShares.erc20().balanceOf(address(zap)), 0, "tokenOut balance 0");
        }
        assertNoFundLeft();
    }
}

contract QuerySwapTokenForYtWstETHForkTest is QuerySwapYtForAnyTokenForkTest {
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
        uint256 principal = 0.01e18;
        Token tokenRedeemShares = Token.wrap(WSTETH);
        uint256 tokenRedeemEstimate = uint256(227553642942948) * 995 / 1000; // Estimate taken from txn trace with 0.5% slippage
        Token tokenOut = Token.wrap(NATIVE_ETH);
        bytes memory payload =
            hex"07ed23790000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a1900000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000005141b82f5ffda4c6fe1e372978f1c5427640a190000000000000000000000000328809bc894f92807417d2dad6b7c998c1afdac60000000000000000000000000000000000000000000000000000cdec8dc8e1290000000000000000000000000000000000000000000000000000d10c1df66f2600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000010d0000000000000000000000000000000000000000ef0000d900009d00004e00a0744c8c097f39c581f595b53c5cb19bd0b3f8da6c935e2ca090cbe4bdd538d6e9b379bff5fe72c3d67a521de500000000000000000000000000000000000000000000000000000034b77012a802a00000000000000000000000000000000000000000000000000000d10c1df66f26ee63c1e501109830a1aaad605bbf02a9dfa7b0b92ec2fb7daa7f39c581f595b53c5cb19bd0b3f8da6c935e2ca04101c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200042e1a7d4d0000000000000000000000000000000000000000000000000000000000000000c061111111125421ca6dc452d289314280a0f8842a6500000000000000000000000000000000000000fa7a9b25";
        RouterPayload memory swapData = RouterPayload({router: ONEINCH_ROUTER, payload: payload});
        _testFork_Query(tokenOut, principal, tokenRedeemShares, tokenRedeemEstimate, swapData);
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
