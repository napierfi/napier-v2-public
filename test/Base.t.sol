// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {Vm, console2} from "forge-std/src/Test.sol";
import {Helpers} from "./shared/Helpers.sol";
import {TestPlus} from "./shared/TestPlus.sol";

import {TwoCryptoNGPrecompiles} from "./TwoCryptoNGPrecompiles.sol";
import {TwoCryptoFactory} from "./TwoCryptoFactory.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
// Mocks
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockRewardProxyModule, MockMultiRewardDistributor} from "./mocks/MockRewardProxy.sol";

// Utils
import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {LibBlueprint} from "src/utils/LibBlueprint.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

// Modules
import {AccessManager} from "src/modules/AccessManager.sol";
import {RewardProxyModule} from "src/modules/RewardProxyModule.sol";
import {DepositCapVerifierModule} from "src/modules/VerifierModule.sol";
import {FeeModule, ConstantFeeModule} from "src/modules/FeeModule.sol";
import {VaultInfoResolver} from "src/modules/resolvers/VaultInfoResolver.sol";
import {ERC4626InfoResolver} from "src/modules/resolvers/ERC4626InfoResolver.sol";
import {TwoCryptoDeployer} from "src/modules/deployers/TwoCryptoDeployer.sol";

// Contracts
import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {Quoter} from "src/lens/Quoter.sol";
import {DefaultConnectorFactory} from "src/modules/connectors/DefaultConnectorFactory.sol";
import {VaultConnectorRegistry} from "src/modules/connectors/VaultConnectorRegistry.sol";
import {AggregationRouter} from "src/modules/aggregator/AggregationRouter.sol";

abstract contract Base is TestPlus, Helpers {
    using FeePctsLib for FeePcts;

    address constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant ONE_INCH_ROUTER = 0x111111125421cA6dc452d289314280a0f8842A65;
    address constant OPEN_OCEAN_ROUTER = 0x6352a56caadC4F1E25CD6c75970Fa768A3304e64;
    uint256 constant WAD = 1e18;
    uint16 constant BASIS_POINTS = 10_000;

    // Napier Finance
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    // Curve Finance
    address curveAdmin = makeAddr("curveAdmin");
    address twoCryptoFactory;
    // Partners
    address feeManager = makeAddr("feeManager");
    address curator = makeAddr("curator");
    address feeCollector = makeAddr("feeCollector");
    address dev = makeAddr("dev");
    address pauser = makeAddr("pauser");
    // Other
    address goku = makeAddr("goku"); // Toy account for depositing initial liquidity to a pool

    // Users
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Mimal proxy logic contract
    address accessManager_logic = address(new AccessManager());
    address mockRewardProxy_logic = address(new MockRewardProxyModule());
    address constantFeeModule_logic = address(new ConstantFeeModule());
    address verifierModule_logic = address(new DepositCapVerifierModule());
    // Blueprint
    address pt_blueprint = LibBlueprint.deployBlueprint(type(PrincipalToken).creationCode);
    address yt_blueprint = LibBlueprint.deployBlueprint(type(YieldToken).creationCode);
    address resolver_blueprint = LibBlueprint.deployBlueprint(type(ERC4626InfoResolver).creationCode);

    // Instances
    AccessManager napierAccessManager;
    AccessManager accessManager;
    FeeModule feeModule;
    MockRewardProxyModule rewardProxy;
    DepositCapVerifierModule verifier;
    Factory factory;
    VaultInfoResolver resolver;
    ERC4626 target;
    ERC20 base;
    ERC20 randomToken;
    address[] rewardTokens;
    MockMultiRewardDistributor multiRewardDistributor;
    PrincipalToken principalToken;
    YieldToken yt;
    TwoCrypto twocrypto;
    TwoCryptoDeployer twocryptoDeployer;
    // Params
    uint256 expiry;
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

    uint256 tOne;
    uint256 bOne;

    function setUp() public virtual {
        expiry = block.timestamp + 365 days;

        napierAccessManager = new AccessManager();
        napierAccessManager.initializeOwner(admin);
        address factory_impl = address(new Factory());
        bytes memory args = abi.encode(address(napierAccessManager));
        factory = Factory(LibClone.deployERC1967(factory_impl, args));

        vm.startPrank(admin);
        napierAccessManager.grantRoles(admin, Constants.DEV_ROLE);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Factory.setTreasury.selector;
        napierAccessManager.grantTargetFunctionRoles(address(factory), selectors, Constants.DEV_ROLE);
        factory.setTreasury(treasury);
        vm.stopPrank();

        // Deploy the target and base tokens
        _deployTokens();

        rewardTokens.push(address(new MockERC20({_decimals: 18})));
        rewardTokens.push(address(new MockERC20({_decimals: 9})));
        if (rewardTokens[0] >= rewardTokens[1]) (rewardTokens[0], rewardTokens[1]) = (rewardTokens[1], rewardTokens[0]);

        multiRewardDistributor = new MockMultiRewardDistributor();
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            multiRewardDistributor.setRewardsPerSec(rewardTokens[i], 120_000); // 1e10 increase per day
            deal(rewardTokens[i], address(multiRewardDistributor), type(uint128).max);
        }

        tOne = 10 ** target.decimals();
        bOne = 10 ** base.decimals();
    }

    function _deployTokens() internal virtual {
        randomToken = new MockERC20({_decimals: 6});
        base = new MockERC20({_decimals: 6});
        target = new MockERC4626({_asset: base, useVirtualShares: false}); // TODO EIP5095.prop setUpVault doesn't support useVirtualShares=true
    }

    function _label() internal virtual {
        vm.label(address(napierAccessManager), "napierAccessManager");
        vm.label(address(factory), "factory");
        vm.label(address(resolver), "resolver");
        vm.label(address(target), "target");
        vm.label(address(base), "base");
        vm.label(address(twocryptoDeployer), "twocryptoDeployer");
        vm.label(address(yt), "yt");
        vm.label(address(principalToken), "principalToken");
        vm.label(twocrypto.unwrap(), "twocrypto");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            vm.label(rewardTokens[i], string.concat("rewardToken", vm.toString(i)));
        }
        if (address(verifier) != address(0)) vm.label(address(verifier), "verifier");
        if (address(feeModule) != address(0)) vm.label(address(feeModule), "feeModule");
        if (address(rewardProxy) != address(0)) vm.label(address(rewardProxy), "rewardProxy");
    }

    /// @notice Deploy the instance of PrincipalToken, YT and Pool.
    function _deployInstance() internal virtual {
        FeePcts feePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 0, 100, 0, BASIS_POINTS); // 100% split fee, 0 issuance fee, 1% performance fee, 0 redemption fee

        bytes memory poolArgs = abi.encode(twocryptoParams);
        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](3);
        moduleParams[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
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
        resolver = principalToken.i_resolver();
        feeModule = ConstantFeeModule(factory.moduleFor(_pt, FEE_MODULE_INDEX));
        verifier = DepositCapVerifierModule(factory.moduleFor(_pt, VERIFIER_MODULE_INDEX));
        rewardProxy = MockRewardProxyModule(factory.moduleFor(_pt, REWARD_PROXY_MODULE_INDEX));
        accessManager = principalToken.i_accessManager();
    }

    function _setUpModules() internal virtual {
        vm.startPrank(admin);
        napierAccessManager.grantRoles(admin, Constants.DEV_ROLE);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = Factory.setPrincipalTokenBlueprint.selector;
        selectors[1] = Factory.setAccessManagerImplementation.selector;
        selectors[2] = Factory.setModuleImplementation.selector;
        selectors[3] = Factory.setPoolDeployer.selector;
        selectors[4] = Factory.setResolverBlueprint.selector;
        napierAccessManager.grantTargetFunctionRoles(address(factory), selectors, Constants.DEV_ROLE);
        vm.stopPrank();

        // Set up the modules
        vm.startPrank(admin);
        factory.setPrincipalTokenBlueprint(address(pt_blueprint), address(yt_blueprint));
        factory.setAccessManagerImplementation(address(accessManager_logic), true);
        factory.setResolverBlueprint(address(resolver_blueprint), true);
        factory.setModuleImplementation(FEE_MODULE_INDEX, address(constantFeeModule_logic), true);
        factory.setModuleImplementation(VERIFIER_MODULE_INDEX, address(verifierModule_logic), true);
        factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, address(mockRewardProxy_logic), true);
        factory.setPoolDeployer(address(twocryptoDeployer), true);
        vm.stopPrank();
    }

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

    function _grantRoles(address account, address callee, bytes4[] memory selectors, uint256 roles) internal {
        vm.startPrank(curator);
        accessManager.grantRoles(account, roles);
        accessManager.grantTargetFunctionRoles(callee, selectors, roles);
        vm.stopPrank();
    }

    function getLatestLogByTopic0(address emitter, bytes32 topic0) internal returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "No logs recorded. Did you call `vm.recordLogs()`?");
        for (uint256 i = logs.length - 1; i >= 0; i--) {
            if (emitter != logs[i].emitter) continue;
            // topic[0] is the event signature
            if (topic0 == logs[i].topics[0]) return logs[i];
        }
        revert("Event Not Found");
    }

    function getLatestLogByTopic0(bytes32 topic0) internal returns (Vm.Log memory) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(logs.length > 0, "No logs recorded. Did you call `vm.recordLogs()`?");
        for (uint256 i = logs.length - 1; i >= 0; i--) {
            // topic[0] is the event signature
            if (topic0 == logs[i].topics[0]) return logs[i];
        }
        revert("Event Not Found");
    }
}

abstract contract ZapBase is Base {
    MockWETH weth;
    TwoCryptoZap zap;
    VaultConnectorRegistry connectorRegistry;
    DefaultConnectorFactory defaultConnectorFactory;
    AggregationRouter aggregationRouter;
    Quoter quoter;

    function _deployPeriphery() internal virtual {
        defaultConnectorFactory = new DefaultConnectorFactory(address(weth));
        connectorRegistry = new VaultConnectorRegistry(napierAccessManager, address(defaultConnectorFactory));
        address[] memory initialRouters = new address[](2);
        initialRouters[0] = ONE_INCH_ROUTER;
        initialRouters[1] = OPEN_OCEAN_ROUTER;
        aggregationRouter = new AggregationRouter(napierAccessManager, initialRouters);
        zap = new TwoCryptoZap(factory, connectorRegistry, address(twocryptoDeployer), aggregationRouter);

        _deployQuoter();
    }

    function _deployQuoter() internal {
        Quoter implementation = new Quoter();
        quoter = Quoter(LibClone.deployERC1967(address(implementation)));
        quoter.initialize(factory, connectorRegistry, address(twocryptoDeployer), address(weth), admin);
    }

    function _deployWETHVault() internal {
        weth = MockWETH(payable(Constants.WETH_ETHEREUM_MAINNET));
        base = MockERC20(address(weth));
        randomToken = new MockERC20({_decimals: 6});
        vm.etch(Constants.WETH_ETHEREUM_MAINNET, address(new MockWETH()).code);
        target = new MockERC4626({_asset: base, useVirtualShares: true});
    }

    function _label() internal virtual override {
        super._label();
        vm.label(address(weth), "weth");
        vm.label(address(zap), "zap");
        vm.label(address(connectorRegistry), "registry");
        vm.label(address(defaultConnectorFactory), "defaultConnectorFactory");
        vm.label(address(quoter), "quoter");
        vm.label(ONE_INCH_ROUTER, "1inch-v6");
        vm.label(OPEN_OCEAN_ROUTER, "openOcean");
    }

    function assertNoFundLeft() internal view {
        assertEq(address(zap).balance, 0, "ETH left in zap");
        assertEq(base.balanceOf(address(zap)), 0, "Base left in zap");
        assertEq(target.balanceOf(address(zap)), 0, "Target left in zap");
        assertEq(principalToken.balanceOf(address(zap)), 0, "PT left in zap");
        assertEq(yt.balanceOf(address(zap)), 0, "YT left in zap");
    }
}
