// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base, ZapBase} from "./Base.t.sol";
import {UniswapV4Deployers} from "./UniswapV4Deployers.sol";

import {ERC20, ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

// Mocks
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {MockERC4626Fees} from "./mocks/MockERC4626Fees.sol";
import {MockRewardProxyModule, MockMultiRewardDistributor} from "./mocks/MockRewardProxy.sol";
import {MulticallerEtcher, MulticallerWithSender} from "multicaller/src/MulticallerEtcher.sol";
import {Permit2Precompile} from "./Permit2Precompile.sol";
import {SaltMiner} from "./SaltMiner.sol";

// Utils
import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";
import {IHooks, Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

// Modules
import {RewardProxyModule} from "src/modules/RewardProxyModule.sol";
import {DepositCapVerifierModule} from "src/modules/VerifierModule.sol";
import {FeeModule, ConstantFeeModule} from "src/modules/FeeModule.sol";
import {PoolFeeModule} from "src/modules/PoolFeeModule.sol";
import {TokiPoolDeployer} from "src/modules/deployers/TokiPoolDeployer.sol";

// Contracts
import {IHooklet} from "src/interfaces/IHooklet.sol";
import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {TokiPoolToken} from "src/tokens/TokiPoolToken.sol";
import {TokiPoolDeployer} from "src/modules/deployers/TokiPoolDeployer.sol";
import {TokiHook, ITokiHook} from "src/hooks/TokiHook.sol";
import {LibOracle} from "src/utils/LibOracle.sol";

import {UniswapV4Router} from "src/zap/uniswap/UniswapV4Router.sol";
import {NapierV2Immutables} from "src/zap/modules/NapierV2Immutables.sol";
import {WrapperFactory} from "src/wrapper/WrapperFactory.sol";
import {WrapperConnector} from "src/modules/connectors/WrapperConnector.sol";
import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {TokiSwapBinSearch} from "src/utils/TokiSwapBinSearch.sol";
import {PrincipalTokenQuoter} from "src/lens/PrincipalTokenQuoter.sol";

contract TokiHookHarness is TokiHook {
    constructor(IPoolManager poolManager, Factory factory) TokiHook(poolManager, factory) {}

    function stateOf(PoolId id) public view returns (ITokiHook.PoolStorage memory) {
        return s_hookStorage.s_states[id];
    }

    function vaultsOf(PoolId id) public view returns (ERC4626 vault0, ERC4626 vault1) {
        address immutableParamsPointer = s_hookStorage.s_states[id].immutableParamsPointer;
        require(immutableParamsPointer != address(0), "TokiHook: Pool does not exist");

        bytes memory data = SSTORE2.read(immutableParamsPointer);
        ITokiHook.ImmutableParams memory immutables = abi.decode(data, (ITokiHook.ImmutableParams));
        return (immutables.vault0, immutables.vault1);
    }

    function observationsOf(PoolId id, uint256 index) public view returns (LibOracle.Observation memory observation) {
        return s_hookStorage.s_observations[id][index];
    }
}

// Create a UniswapV4 specific base test contract
abstract contract UniswapV4Base is Base, UniswapV4Deployers {
    using Hooks for IHooks;

    uint16 constant POOL_FEE_SPLIT_RATIO_BPS = Constants.DEFAULT_SPLIT_RATIO_BPS;
    uint128 constant POOL_FEE_AMM_FEE_PARAMS = uint128(7670506304219700 * uint256(Constants.TOKI_SWAP_FEE_SCALE) / 1e18); // ln(1.0077) 0.77%
    uint16 constant POOL_FEE_RESERVE_FEE_BPS = 500; // 5%

    struct RehypothecationConfig {
        uint16 targetRawTokenRatio;
        uint16 maxRawTokenRatio;
        uint16 minRawTokenRatio;
    }

    RehypothecationConfig rehypothecationConfig0 = RehypothecationConfig({
        targetRawTokenRatio: 5_000, // 50%
        maxRawTokenRatio: 6_000, // 60%
        minRawTokenRatio: 4_000 // 40%
    });

    RehypothecationConfig rehypothecationConfig1 = RehypothecationConfig({
        targetRawTokenRatio: 8_000, // 60%
        maxRawTokenRatio: 9_000, // 80%
        minRawTokenRatio: 2_000 // 20%
    });

    MulticallerWithSender multicaller;

    address tokiPoolDeployer = 0x99999ad9F0eec955BC212608C84267ee39712fA2;
    address liquidityTokenImplementation;
    PoolFeeModule poolFeeModule;

    TokiHook tokiHook;

    IHooklet hooklet;

    address vaultFeeRecipient = makeAddr("vaultFeeRecipient");
    MockERC4626Fees vault0;
    MockERC4626Fees vault1;

    PoolKey poolKey;

    uint16 pauseFlags;
    uint16 vault0Flags;
    uint16 vault1Flags;

    function setUp() public virtual override {
        super.setUp();

        multicaller = MulticallerEtcher.multicallerWithSender();

        deployFreshManagerAndRouters();

        liquidityTokenImplementation = address(new TokiPoolToken(poolManager));

        // Deploy TokiPool hooks
        tokiHook = TokiHook(
            payable(
                address(
                    uint160(
                        uint256(keccak256(abi.encode("TokiHook"))) & clearAllHookPermissionsMask
                            | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_INITIALIZE_FLAG
                            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    )
                )
            )
        );
        deployCodeTo("TokiHookHarness", abi.encode(poolManager, factory), address(tokiHook));
    }

    function _deployV4PoolDeployer() internal virtual {
        deployCodeTo(
            "TokiPoolDeployer", abi.encode(factory, tokiHook, liquidityTokenImplementation), address(tokiPoolDeployer)
        );
    }

    function _deployRehypothecationVaults(address asset) internal virtual returns (MockERC4626Fees vault) {
        vault = new MockERC4626Fees(ERC20(asset), true, 0, 0, vaultFeeRecipient);
    }

    function _setRehypothecationVaults(PoolKey memory key, address newVault0, address newVault1) internal virtual {
        vm.startPrank(curator);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiHook.updateConfiguration.selector;
        accessManager.grantRoles(curator, Constants.DEV_ROLE);
        accessManager.grantTargetFunctionRoles(address(tokiHook), selectors, Constants.DEV_ROLE);

        // Update vaults one by one using the batch interface
        if (newVault0 != address(0)) {
            ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
            actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, newVault0);
            tokiHook.updateConfiguration(key, actions, params);
        }
        if (newVault1 != address(0)) {
            ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
            actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
            bytes[] memory params = new bytes[](1);
            params[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_1, newVault1);
            tokiHook.updateConfiguration(key, actions, params);
        }

        vm.stopPrank();
    }

    function _setUpModules() internal virtual override {
        super._setUpModules();

        vm.startPrank(admin);
        factory.setModuleImplementation(POOL_FEE_MODULE_INDEX, address(poolFeeModule_logic), true);
        vm.stopPrank();
    }

    function _deployInstance() internal virtual override {
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = ITokiHook.TokiPoolDeploymentParams({
            hook: address(tokiHook),
            pausableFlags: Flags16.wrap(pauseFlags),
            salt: 0xaead0cc698843ef9708d44802286d691a5358ad05f2fe6b8b2cf8cb75df2ec8f,
            hookParams: abi.encode(uint16(0), abi.encode(16240223350842364143, 1098960161431879138)), // cardinalityNext=0, (scalarRoot, initialAnchor)
            hooklet: IHooklet(address(0)),
            hookletParams: "",
            vault0: vault0,
            vault1: vault1,
            vault0Params: abi.encode(
                vault0Flags,
                rehypothecationConfig0.targetRawTokenRatio,
                rehypothecationConfig0.maxRawTokenRatio,
                rehypothecationConfig0.minRawTokenRatio
            ),
            vault1Params: abi.encode(
                vault1Flags,
                rehypothecationConfig1.targetRawTokenRatio,
                rehypothecationConfig1.maxRawTokenRatio,
                rehypothecationConfig1.minRawTokenRatio
            ),
            liquidityTokenImplementation: liquidityTokenImplementation,
            liquidityTokenImmutableData: ""
        });

        bytes memory poolArgs = abi.encode(uniswapV4Params);
        bytes memory resolverArgs = abi.encode(address(target));
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](4);
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
        moduleParams[3] = Factory.ModuleParam({
            moduleType: POOL_FEE_MODULE_INDEX,
            implementation: poolFeeModule_logic,
            immutableData: abi.encode(
                FeePctsPoolLib.pack(POOL_FEE_SPLIT_RATIO_BPS, POOL_FEE_AMM_FEE_PARAMS, POOL_FEE_RESERVE_FEE_BPS)
            )
        });

        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: address(accessManager_logic),
            resolverBlueprint: address(resolver_blueprint),
            ptBlueprint: address(pt_blueprint),
            poolDeployerImpl: tokiPoolDeployer,
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });

        (address _pt, address _yt, address _pool) = factory.deployDeterministic({
            suite: suite,
            params: moduleParams,
            expiry: expiry,
            curator: curator,
            salt: SaltMiner.findPrincipalTokenSalt(address(factory), address(this), pt_blueprint)
        });

        // Store instances
        principalToken = PrincipalToken(_pt);
        yt = YieldToken(_yt);
        pool = _pool; // Liquidity token for TokiPool
        resolver = principalToken.i_resolver();
        feeModule = ConstantFeeModule(factory.moduleFor(_pt, FEE_MODULE_INDEX));
        verifier = DepositCapVerifierModule(factory.moduleFor(_pt, VERIFIER_MODULE_INDEX));
        rewardProxy = MockRewardProxyModule(factory.moduleFor(_pt, REWARD_PROXY_MODULE_INDEX));
        poolFeeModule = PoolFeeModule(factory.moduleFor(_pt, POOL_FEE_MODULE_INDEX));
        accessManager = principalToken.i_accessManager();

        poolKey = tokiHook.poolKeyOf(pool);
    }

    function _registerPoolDeployer() internal virtual override {
        factory.setPoolDeployer(tokiPoolDeployer, true);
    }

    function _label() internal virtual override {
        super._label();
        vm.label(tokiPoolDeployer, "tokiPoolDeployer");
        vm.label(address(poolManager), "poolManager");
        vm.label(address(tokiHook), "tokiHook");
        vm.label(address(poolFeeModule), "poolFeeModule");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TEST HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function assertCuratorFeeCollection(PoolKey memory key, address feeReceiver) public {
        uint256 balanceBefore = key.currency0.balanceOf(feeReceiver);
        (uint128 curatorFee, uint128 protocolFee) = stateOf(key.toId()).fees.unpack();

        // Act
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiHook.collectCuratorFee.selector;
        vm.startPrank(curator);
        accessManager.grantRoles(curator, Constants.DEV_ROLE);
        accessManager.grantTargetFunctionRoles(address(tokiHook), selectors, Constants.DEV_ROLE);

        uint256 fee = tokiHook.collectCuratorFee(key, feeReceiver);
        vm.stopPrank();

        // Assert
        assertEq(fee, curatorFee);
        assertEq(stateOf(key.toId()).fees.value0(), 0);
        assertEq(stateOf(key.toId()).fees.value1(), protocolFee);
        assertEq(key.currency0.balanceOf(feeReceiver), balanceBefore + curatorFee, "Curator fee");
    }

    function assertProtocolFeeCollection(PoolKey memory key) public {
        uint256 balanceBefore = key.currency0.balanceOf(treasury);
        (uint128 curatorFee, uint128 protocolFee) = stateOf(key.toId()).fees.unpack();

        // Act
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiHook.collectProtocolFee.selector;
        vm.startPrank(admin);
        napierAccessManager.grantRoles(dev, Constants.DEV_ROLE);
        napierAccessManager.grantTargetFunctionRoles(address(tokiHook), selectors, Constants.DEV_ROLE);
        vm.stopPrank();

        vm.prank(dev);
        uint256 fee = tokiHook.collectProtocolFee(key);

        // Assert
        assertEq(fee, protocolFee);
        Uint128x2 feesAfter = stateOf(key.toId()).fees;
        assertEq(feesAfter.value0(), curatorFee);
        assertEq(feesAfter.value1(), 0);
        assertEq(key.currency0.balanceOf(treasury), balanceBefore + protocolFee, "Protocol fee");
    }

    function cheat_setImmutableParamsPointer(
        address immutableParamsPointer,
        ITokiHook.ImmutableParams memory newImmutableParams
    ) internal {
        address pointer = SSTORE2.write(abi.encode(newImmutableParams));
        vm.etch(immutableParamsPointer, pointer.code);
    }

    /// @dev This is a helper function to get the state of a pool for testing purposes
    function stateOf(PoolId id) internal view returns (ITokiHook.PoolStorage memory state) {
        return TokiHookHarness(address(tokiHook)).stateOf(id);
    }

    /// @dev This is a helper function to get the state of a pool for testing purposes
    function vaultsOf(PoolId id) internal view returns (ERC4626, ERC4626) {
        return TokiHookHarness(address(tokiHook)).vaultsOf(id);
    }

    function _swap(address user, bool zeroForOne, int256 amount, uint256 timeJump) public {
        vm.startPrank(user);
        target.approve(address(swapRouter), type(uint256).max);
        principalToken.approve(address(swapRouter), type(uint256).max);

        vm.warp(block.timestamp + timeJump);
        swap({_key: poolKey, zeroForOne: zeroForOne, amountSpecified: amount, hookData: ""});
        vm.stopPrank();
    }
}

// Uniswap V4 Zap testing base
abstract contract UniswapV4ZapBase is UniswapV4Base, ZapBase {
    UniswapV4Router zap;
    IPermit2 permit2;
    WrapperFactory wrapperFactory;
    address wrapperConnectorImplementation;
    TokiQuoter quoter;
    PrincipalTokenQuoter ptQuoter;

    function setUp() public virtual override(UniswapV4Base, Base) {
        super.setUp();
    }

    function _setUpModules() internal virtual override(UniswapV4Base, Base) {
        permit2 = IPermit2(Permit2Precompile.PERMIT2_ADDRESS);
        Permit2Precompile.etch(address(permit2));
        UniswapV4Base._setUpModules();
    }

    function _deployPeriphery() internal virtual override {
        super._deployPeriphery(); // This creates weth and connectorRegistry

        // Deploy connector implementation
        wrapperConnectorImplementation = address(new WrapperConnector());

        // Create wrapper factory with all required parameters
        wrapperFactory = new WrapperFactory(
            address(napierAccessManager), address(weth), address(connectorRegistry), wrapperConnectorImplementation
        );

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = connectorRegistry.setConnector.selector;
        napierAccessManager.grantRoles(address(wrapperFactory), Constants.CONNECTOR_REGISTRY_ROLE);
        napierAccessManager.grantTargetFunctionRoles(
            address(connectorRegistry), selectors, Constants.CONNECTOR_REGISTRY_ROLE
        );
        vm.stopPrank();

        // Deploy TokiSwapBinSearch
        TokiSwapBinSearch tokiSwapBinSearch = new TokiSwapBinSearch(factory);

        // Deploy Uniswap V4 specific zap
        NapierV2Immutables.NapierV2Parameters memory params = NapierV2Immutables.NapierV2Parameters({
            factory: factory,
            vaultConnectorRegistry: connectorRegistry,
            aggregationRouter: aggregationRouter,
            wrapperFactory: wrapperFactory,
            tokiPoolDeployer: TokiPoolDeployer(tokiPoolDeployer),
            tokiSwapBinSearch: tokiSwapBinSearch
        });

        zap = new UniswapV4Router(poolManager, address(permit2), address(weth), params);

        // Deploy PrincipalTokenQuoter (factory, wrappedNativeToken, vaultConnectorRegistry)
        address ptQuoterImplementation = address(new PrincipalTokenQuoter());
        ptQuoter = PrincipalTokenQuoter(
            LibClone.deployERC1967I(ptQuoterImplementation, abi.encode(factory, weth, connectorRegistry))
        );

        // Deploy TokiQuoter with new immutable args: (tokiSwapBinSearch, tokiPoolDeployer, principalTokenQuoter)
        address tokiQuoterImplementation = address(new TokiQuoter());
        bytes memory args = abi.encode(tokiSwapBinSearch, tokiPoolDeployer, ptQuoter);
        quoter = TokiQuoter(LibClone.deployERC1967I(tokiQuoterImplementation, args));
    }

    function _label() internal virtual override(UniswapV4Base, ZapBase) {
        UniswapV4Base._label();
        ZapBase._label();
        vm.label(address(zap), "zap");
        vm.label(address(permit2), "permit2");
        vm.label(address(wrapperFactory), "wrapperFactory");
    }

    function assertNoFundLeftInZap() internal view {
        // Check that no funds are left in the UniswapV4 zap
        assertEq(address(zap).balance, 0, "ETH left in zap");
        assertEq(base.balanceOf(address(zap)), 0, "Base left in zap");
        assertEq(target.balanceOf(address(zap)), 0, "Target left in zap");
        assertEq(principalToken.balanceOf(address(zap)), 0, "PT left in zap");
        assertEq(yt.balanceOf(address(zap)), 0, "YT left in zap");
    }
}
