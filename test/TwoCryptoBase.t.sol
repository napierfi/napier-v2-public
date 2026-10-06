// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Base, ZapBase} from "./Base.t.sol";

import {TwoCryptoNGPrecompiles} from "./TwoCryptoNGPrecompiles.sol";
import {TwoCryptoFactory} from "./TwoCryptoFactory.sol";

import {MockRewardProxyModule} from "./mocks/MockRewardProxy.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";

// Utils
import "src/Types.sol";
import "src/Constants.sol" as Constants;

import {FeePctsLib} from "src/utils/FeePctsLib.sol";

// Modules
import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {TwoCryptoDeployer} from "src/modules/deployers/TwoCryptoDeployer.sol";
import {IPoolDeployer} from "src/interfaces/IPoolDeployer.sol";
import {FeeModule, ConstantFeeModule} from "src/modules/FeeModule.sol";
import {DepositCapVerifierModule} from "src/modules/VerifierModule.sol";
import {RewardProxyModule} from "src/modules/RewardProxyModule.sol";

// Contracts
import {TwoCryptoZap} from "src/zap/twocrypto/TwoCryptoZap.sol";
import {Quoter} from "src/lens/twocrypo/Quoter.sol";

// TwoCrypto Specific Testing Base
abstract contract TwoCryptoBase is Base {
    TwoCrypto twocrypto;
    TwoCryptoDeployer twocryptoDeployer;

    // TwoCrypto specific params
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

    function _deployTwoCryptoDeployer() internal {
        address math = TwoCryptoNGPrecompiles.deployMath();
        address views = TwoCryptoNGPrecompiles.deployViews();
        address amm = TwoCryptoNGPrecompiles.deployBlueprint();

        vm.startPrank(curveAdmin, curveAdmin);
        twoCryptoFactory = TwoCryptoNGPrecompiles.deployFactory();

        vm.label(math, "twocrypto_math");
        vm.label(views, "twocrypto_views");
        vm.label(amm, "twocrypto_blueprint");

        TwoCryptoFactory(twoCryptoFactory).initialise_ownership(curveAdmin, curveAdmin);
        TwoCryptoFactory(twoCryptoFactory).set_pool_implementation(amm, 0);
        TwoCryptoFactory(twoCryptoFactory).set_views_implementation(views);
        TwoCryptoFactory(twoCryptoFactory).set_math_implementation(math);
        vm.stopPrank();

        twocryptoDeployer = new TwoCryptoDeployer(twoCryptoFactory);
    }

    function _deployInstance() internal virtual override {
        bytes memory poolArgs = abi.encode(twocryptoParams);
        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](3);
        moduleParams[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 0, 100, 0, BASIS_POINTS))
        });
        moduleParams[1] = Factory.ModuleParam({
            moduleType: VERIFIER_MODULE_INDEX,
            implementation: verifierModule_logic,
            immutableData: abi.encode(type(uint256).max) // No cap
        });
        moduleParams[2] = Factory.ModuleParam({
            moduleType: REWARD_PROXY_MODULE_INDEX,
            implementation: mockRewardProxy_logic,
            immutableData: abi.encode(rewardTokens, multiRewardDistributor)
        });

        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: address(accessManager_logic),
            resolverBlueprint: address(resolver_blueprint),
            ptBlueprint: address(pt_blueprint),
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
        (address _pt, address _yt, address _twocrypto) =
            factory.deploy({suite: suite, params: moduleParams, expiry: expiry, curator: curator});
        // Store instances
        principalToken = PrincipalToken(_pt);
        yt = YieldToken(_yt);
        twocrypto = TwoCrypto.wrap(_twocrypto);
        pool = _twocrypto;
        resolver = principalToken.i_resolver();
        feeModule = ConstantFeeModule(factory.moduleFor(_pt, FEE_MODULE_INDEX));
        verifier = DepositCapVerifierModule(factory.moduleFor(_pt, VERIFIER_MODULE_INDEX));
        rewardProxy = MockRewardProxyModule(factory.moduleFor(_pt, REWARD_PROXY_MODULE_INDEX));
        accessManager = principalToken.i_accessManager();
    }

    function _registerPoolDeployer() internal virtual override {
        factory.setPoolDeployer(address(twocryptoDeployer), true);
    }

    function _label() internal virtual override {
        super._label();
        vm.label(address(twocryptoDeployer), "twocryptoDeployer");
        vm.label(twocrypto.unwrap(), "twocrypto");
    }
}

// TwoCryptoZap specific testing base
abstract contract TwoCryptoZapBase is TwoCryptoBase, ZapBase {
    TwoCryptoZap zap;
    Quoter quoter;

    function _deployPeriphery() internal virtual override {
        super._deployPeriphery();
        zap = new TwoCryptoZap(factory, connectorRegistry, address(twocryptoDeployer), aggregationRouter);

        Quoter implementation = new Quoter();
        quoter = Quoter(LibClone.deployERC1967(address(implementation)));
        quoter.initialize(factory, connectorRegistry, address(twocryptoDeployer), address(weth), admin);
    }

    function _label() internal virtual override(TwoCryptoBase, ZapBase) {
        TwoCryptoBase._label();
        ZapBase._label();
        vm.label(address(zap), "zap");
    }

    function assertNoFundLeft() internal view {
        assertEq(address(zap).balance, 0, "ETH left in zap");
        assertEq(base.balanceOf(address(zap)), 0, "Base left in zap");
        assertEq(target.balanceOf(address(zap)), 0, "Target left in zap");
        assertEq(principalToken.balanceOf(address(zap)), 0, "PT left in zap");
        assertEq(yt.balanceOf(address(zap)), 0, "YT left in zap");
    }
}
