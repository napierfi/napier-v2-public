// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {SiloRewardProxy} from "src/modules/reward-proxies/SiloRewardProxy.sol";
import {Factory} from "src/Factory.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "src/zap/twocrypto/TwoCryptoZap.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

using {TokenType.intoToken} for address;

contract SiloUSDCForkTest is TwoCryptoIntegrationTest {
    using LibTwoCryptoNG for TwoCrypto;

    address constant WS = 0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38;
    address constant SILO_WS_VAULT = 0x9D2192e40F8D215C628Ea9FcF067683720d82032;
    address constant SILO_INCENTIVES_CONTROLLER = 0xB5073fC0dff2142FDdbb548e749B5acf259d4807; // Silo incentives controller on Sonic
    address constant SILO_TOKEN = 0xb098AFC30FCE67f1926e735Db6fDadFE433E61db; // SILO token

    address siloRewardProxy_logic;
    string[] programNames;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("sonic"), 33198833);
    }

    function setUp() public override {
        siloRewardProxy_logic = address(new SiloRewardProxy());

        super.setUp();
        deal(SILO_WS_VAULT, alice, 1_000_000_000_000 * tOne);

        vm.label(SILO_INCENTIVES_CONTROLLER, "silo_incentives_controller_sonic");
        vm.label(SILO_TOKEN, "silo_token");
        vm.label(WS, "ws");
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, SILO_WS_VAULT)
            sstore(base.slot, WS)
        }
    }

    function _setUpModules() internal override {
        super._setUpModules();
        vm.startPrank(admin);
        factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, siloRewardProxy_logic, true);
        vm.stopPrank();
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        FeePcts feePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 0, 0, 0, 0);

        TwoCryptoNGParams memory twoCryptoArgs = TwoCryptoNGParams({
            A: 40000000, // 0 unit
            gamma: 0.019 * 1e18, // 1e18 unit
            mid_fee: 0.0006 * 1e8, // 1e8 unit
            out_fee: 0.006 * 1e8, // 1e8 unit
            fee_gamma: 0.07 * 1e18, // 1e18 unit
            allowed_extra_profit: 2e-6 * 1e18, // 1e18 unit
            adjustment_step: 0.00049 * 1e18, // 1e18 unit
            ma_time: 3600, // 0 unit
            initial_price: 965759e18
        });

        bytes memory poolArgs = abi.encode(twoCryptoArgs);
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = SILO_TOKEN;

        params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        // params[1] = Factory.ModuleParam({
        //     moduleType: REWARD_PROXY_MODULE_INDEX,
        //     implementation: siloRewardProxy_logic,
        //     immutableData: abi.encode(rewardTokens, SILO_INCENTIVES_CONTROLLER, programNames)
        // });

        bytes memory resolverArgs = abi.encode(address(target)); // Change based on the resolver blueprint
        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: erc4626_resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }

    function testFork_PrincipalTokenRedeem() public virtual {
        uint256 unit = 1e6 * tOne; // worth 1 WS

        uint256 shares = 1_000 * unit;
        _approve(target, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        uint256 principal = zap.supply(principalToken, Token.wrap(address(target)), shares, alice, 0);

        uint256 conversionRateBefore = target.convertToAssets(unit);
        console.log("conversionRateBefore", conversionRateBefore);
        console.log("deposit", shares);
        console.log("principal", principal);

        assertEq(principalToken.balanceOf(alice), principal, "principal token balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");

        vm.warp(expiry);

        uint256 conversionRateAfter = target.convertToAssets(unit);
        console.log("conversionRateAfter", conversionRateAfter);

        _approve(principalToken, alice, address(zap), principal);
        vm.prank(alice);
        uint256 redeemed = zap.redeem(principalToken, Token.wrap(address(target)), principal, alice, 0);
        console.log("redeemed", redeemed);
        console.log("WS redeemed", target.convertToAssets(redeemed));

        vm.prank(alice);
        (uint256 collected,) = principalToken.collect(alice, alice);
        console.log("collected", collected);
        console.log("WS collected", target.convertToAssets(collected));

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        uint256 fees = curatorFee + protocolFee;
        console.log("fees", fees);
        console.log("WS fees", target.convertToAssets(fees));
    }

    function testFork_CreateAndAddLiquidity() public override {
        uint256 initialLiquidity = 1_000_000 * tOne;
        _approve(target, alice, address(zap), initialLiquidity);

        (Factory.Suite memory suite, Factory.ModuleParam[] memory m) = getDeploymentParams();
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = TwoCryptoZap.CreateAndAddLiquidityParams({
            suite: suite,
            modules: m,
            expiry: expiry,
            curator: curator,
            shares: initialLiquidity,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        vm.prank(alice);
        ( /* address pt */ , /* address yt */, address twoCrypto, uint256 liquidity, uint256 principal) =
            zap.createAndAddLiquidity(params);

        twocrypto = TwoCrypto.wrap(twoCrypto);
        principalToken = PrincipalToken(twocrypto.coins(Constants.PT_INDEX));
        yt = principalToken.i_yt();
        resolver = principalToken.i_resolver();
        accessManager = principalToken.i_accessManager();

        assertEq(twocrypto.balanceOf(alice), liquidity, "liquidity balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");
    }
}
