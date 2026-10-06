// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {UniswapV4Base} from "../../UniswapV4Base.t.sol";
import {SaltMiner} from "../../SaltMiner.sol";
import {MockERC4626, MockERC4626Fees} from "../../mocks/MockERC4626Fees.sol";

import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ERC20, ERC4626} from "solady/src/tokens/ERC4626.sol";

import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {IHooklet} from "src/interfaces/IHooklet.sol";
import {ITokiHook} from "src/interfaces/ITokiHook.sol";
import {TokiPoolDeployer} from "src/modules/deployers/TokiPoolDeployer.sol";

import {TokenNameLib} from "src/utils/TokenNameLib.sol";
import {FeePctsLib} from "src/modules/FeeModule.sol";
import {FeePctsPoolLib} from "src/modules/PoolFeeModule.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;
import "src/Errors.sol";

contract DeployTest is UniswapV4Base {
    using SafeCastLib for uint256;

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        vault0 = _deployRehypothecationVaults(address(target));

        _label();
    }

    function test_Deploy() public {
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint);
        address predictedAddress = SaltMiner.predictPrincipalTokenAddress(address(factory), alice, salt, pt_blueprint);

        vault1 = new MockERC4626Fees(ERC20(predictedAddress), false, 0, 0, address(0xbeef));

        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();
        uniswapV4Params.vault0 = vault0;
        uniswapV4Params.vault1 = vault1;

        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            ptBlueprint: pt_blueprint,
            resolverBlueprint: resolver_blueprint,
            poolDeployerImpl: address(tokiPoolDeployer),
            poolArgs: abi.encode(uniswapV4Params),
            resolverArgs: abi.encode(address(target))
        });

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](2);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(factory.DEFAULT_SPLIT_RATIO_BPS().toUint16(), 100, 200, 50, 10000))
        });
        params[1] = Factory.ModuleParam({
            moduleType: POOL_FEE_MODULE_INDEX,
            implementation: poolFeeModule_logic,
            immutableData: abi.encode(
                FeePctsPoolLib.pack(POOL_FEE_SPLIT_RATIO_BPS, POOL_FEE_AMM_FEE_PARAMS, POOL_FEE_RESERVE_FEE_BPS)
            )
        });

        uint256 expiry = block.timestamp + 365 days;

        vm.prank(alice);
        (address p, address y, address pool) = factory.deployDeterministic(suite, params, expiry, curator, salt);

        // Assertions
        assertTrue(p != address(0), "PrincipalToken should be deployed");
        assertTrue(y != address(0), "YT should be deployed");
        assertTrue(pool != address(0), "Pool should be deployed");

        // Verify PrincipalToken is registered
        assertEq(factory.s_principalTokens(p), pt_blueprint, "PrincipalToken should be registered");

        // Verify pool is registered
        assertEq(factory.s_pools(pool), address(tokiPoolDeployer), "Pool should be registered");

        // Verify curator is set correctly
        AccessManager accessManager = AccessManager(PrincipalToken(p).i_accessManager());
        assertEq(accessManager.owner(), curator, "Curator should be set as owner");

        // Verify expiry is set correctly
        assertEq(PrincipalToken(p).maturity(), expiry, "Expiry should be set correctly");

        // Verify YT is linked to PrincipalToken
        assertEq(address(YieldToken(y).i_principalToken()), address(p), "YT should be linked to PrincipalToken");
        assertEq(address(PrincipalToken(p).i_yt()), y, "YT address should be set correctly");

        assertEq(PrincipalToken(p).name(), TokenNameLib.principalTokenName(address(target), expiry));
        assertEq(PrincipalToken(p).symbol(), TokenNameLib.principalTokenSymbol(address(target), expiry));
        assertEq(YieldToken(y).name(), TokenNameLib.yieldTokenName(address(target), expiry));
        assertEq(YieldToken(y).symbol(), TokenNameLib.yieldTokenSymbol(address(target), expiry));

        PoolKey memory poolKey = tokiHook.poolKeyOf(pool);

        // Verify pool currency is set correctly
        assertEq(Currency.unwrap(poolKey.currency0), address(target), "Pool key should be set correctly");
        assertEq(Currency.unwrap(poolKey.currency1), address(p), "Pool key should be set correctly");
        (ERC4626 poolVault0, ERC4626 poolVault1) = vaultsOf(poolKey.toId());
        assertEq(address(poolVault0), address(vault0), "Rehypothecation vaults should be set correctly");
        assertEq(address(poolVault1), address(vault1), "Rehypothecation vaults should be set correctly");
        if (address(vault0) != address(0)) {
            assertEq(vault0.asset(), Currency.unwrap(poolKey.currency0), "Vault0 should be set correctly");
        }
        if (address(vault1) != address(0)) {
            assertEq(vault1.asset(), Currency.unwrap(poolKey.currency1), "Vault1 should be set correctly");
        }

        // Verify oracle is initialized
        (uint16 cardinalityNext,) = abi.decode(uniswapV4Params.hookParams, (uint16, bytes));
        assertEq(
            stateOf(poolKey.toId()).observationCardinalityNext,
            cardinalityNext > 1 ? cardinalityNext : 1,
            "cardinalityNext"
        );
        assertEq(stateOf(poolKey.toId()).observationCardinality, 1, "cardinality");
    }

    function test_RevertWhen_InvalidExpiry() public {
        vm.skip(true);
    }

    function test_RevertWhen_NotFactory() public {
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();

        vm.expectRevert(Errors.TokiPoolDeployer_OnlyFactory.selector);
        TokiPoolDeployer(tokiPoolDeployer).deploy(address(target), address(0xbad), abi.encode(uniswapV4Params));
    }

    function test_RevertWhen_HookNotApproved() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();
        uniswapV4Params.hook = address(0xbad);
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.startPrank(alice);
        vm.expectRevert(Errors.TokiPoolDeployer_InvalidHook.selector);
        factory.deployDeterministic(
            suite,
            params,
            block.timestamp + 365 days,
            curator,
            SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint)
        );
        vm.stopPrank();
    }

    function test_RevertWhen_NotPoolDeployer() public {
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();

        vm.expectRevert(Errors.TokiHook_OnlyPoolDeployer.selector);
        tokiHook.deploy(address(target), address(0xbad), uniswapV4Params);
    }

    function test_RevertWhen_BadCurrencyOrder() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        // Mine a salt so that principal token address < target address
        uint256 badSalt = 1; // Start from 1 to avoid collision with the default salt
        address predictedAddress;
        while (true) {
            predictedAddress =
                SaltMiner.predictPrincipalTokenAddress(address(factory), alice, bytes32(badSalt), pt_blueprint);
            if (address(target) > predictedAddress) {
                console2.log("predictedAddress", predictedAddress);
                break;
            }
            unchecked {
                badSalt += 1;
            }
        }
        vm.expectRevert(Errors.TokiPoolDeployer_BadCurrencyOrder.selector);
        vm.prank(alice);
        factory.deployDeterministic(suite, params, block.timestamp + 365 days, curator, bytes32(badSalt));
    }

    function test_RevertWhen_InvalidHooklet() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();
        uniswapV4Params.hooklet = IHooklet(address(0xf000d));
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.startPrank(alice);
        vm.expectRevert(Errors.TokiPoolDeployer_InvalidHooklet.selector);
        factory.deployDeterministic(
            suite,
            params,
            block.timestamp + 365 days,
            curator,
            SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint)
        );
        vm.stopPrank();
    }

    function test_RevertWhen_VaultAssetMismatch() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();

        vm.startPrank(alice);
        uniswapV4Params.vault0 = new MockERC4626(base, true);
        uniswapV4Params.vault1 = MockERC4626(address(0));
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.expectRevert(Errors.Rehypothecation_VaultAssetMismatch.selector);
        factory.deployDeterministic(
            suite,
            params,
            block.timestamp + 365 days,
            curator,
            SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint)
        );
        vm.stopPrank();

        vm.startPrank(alice);
        uniswapV4Params.vault0 = MockERC4626(address(0));
        uniswapV4Params.vault1 = new MockERC4626(target, true);
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.expectRevert(Errors.Rehypothecation_VaultAssetMismatch.selector);
        factory.deployDeterministic(
            suite,
            params,
            block.timestamp + 365 days,
            curator,
            SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint)
        );
        vm.stopPrank();
    }

    function testFuzz_RevertWhen_InvalidRehypothecationParams(
        uint16 targetRawTokenRatio0,
        uint16 maxRawTokenRatio0,
        uint16 minRawTokenRatio0,
        uint16 targetRawTokenRatio1,
        uint16 maxRawTokenRatio1,
        uint16 minRawTokenRatio1
    ) public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();

        // Assume we're testing invalid parameters only
        // For vault0 parameters
        bool isInvalidVault0 = minRawTokenRatio0 > targetRawTokenRatio0 || targetRawTokenRatio0 > maxRawTokenRatio0
            || maxRawTokenRatio0 > Constants.BASIS_POINTS;

        // For vault1 parameters
        bool isInvalidVault1 = minRawTokenRatio1 > targetRawTokenRatio1 || targetRawTokenRatio1 > maxRawTokenRatio1
            || maxRawTokenRatio1 > Constants.BASIS_POINTS;

        // Only test when at least one set of parameters is invalid
        vm.assume(isInvalidVault0 || isInvalidVault1);

        uniswapV4Params.vault0Params =
            abi.encode(vault0Flags, targetRawTokenRatio0, maxRawTokenRatio0, minRawTokenRatio0);
        uniswapV4Params.vault1Params =
            abi.encode(vault1Flags, targetRawTokenRatio1, maxRawTokenRatio1, minRawTokenRatio1);

        suite.poolArgs = abi.encode(uniswapV4Params);

        uint256 expiry = block.timestamp + 365 days;
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint);

        vm.prank(alice);
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        factory.deployDeterministic(suite, params, expiry, curator, salt);
    }

    function test_RevertWhen_InvalidHookParams() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();
        uint256 expiry = block.timestamp + 365 days;
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint);

        vm.startPrank(alice);
        uniswapV4Params.hookParams = abi.encode(uint16(0), abi.encode(0, 0));
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.expectRevert(Errors.TokiHook_InvalidScalarRoot.selector);
        factory.deployDeterministic(suite, params, expiry, curator, salt);

        vm.stopPrank();
    }

    function test_RevertWhen_InitialAnchorBelowMinimum() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();
        uint256 expiry = block.timestamp + 365 days;
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint);

        (uint16 cardinalityNext, bytes memory ammParams) = abi.decode(uniswapV4Params.hookParams, (uint16, bytes));
        (uint256 scalarRoot,) = abi.decode(ammParams, (uint256, int256));

        int256 minimumAnchor = int256(Constants.WAD);
        int256 invalidAnchor = minimumAnchor - 1;
        uniswapV4Params.hookParams = abi.encode(cardinalityNext, abi.encode(scalarRoot, invalidAnchor));
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.startPrank(alice);
        vm.expectRevert(Errors.TokiHook_InitialAnchorTooLow.selector);
        factory.deployDeterministic(suite, params, expiry, curator, salt);

        vm.stopPrank();
    }

    function test_RevertWhen_InvalidLiquidityTokenImplementation() public {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getFactoryParams();
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();
        uint256 expiry = block.timestamp + 365 days;
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint);

        vm.startPrank(alice);
        uniswapV4Params.liquidityTokenImplementation = address(0xbad);
        suite.poolArgs = abi.encode(uniswapV4Params);

        vm.expectRevert(Errors.TokiPoolDeployer_InvalidLiquidityTokenImplementation.selector);
        factory.deployDeterministic(suite, params, expiry, curator, salt);

        vm.stopPrank();
    }

    function test_RevertWhen_MissingPoolFeeModule() public {
        (Factory.Suite memory suite,) = getFactoryParams();

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1); // Remove PoolFeeModule
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(factory.DEFAULT_SPLIT_RATIO_BPS().toUint16(), 100, 200, 50, 10000))
        });

        vm.startPrank(alice);
        vm.expectRevert(Errors.TokiHook_MissingPoolFeeModule.selector);
        factory.deployDeterministic(
            suite,
            params,
            block.timestamp + 365 days,
            curator,
            SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint)
        );
        vm.stopPrank();
    }

    function test_RevertWhen_MissingFeeModule() public {
        vm.skip(true);
    }

    function getFactoryParams()
        internal
        view
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = getTokiPoolDeploymentParams();

        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            ptBlueprint: pt_blueprint,
            resolverBlueprint: resolver_blueprint,
            poolDeployerImpl: address(tokiPoolDeployer),
            poolArgs: abi.encode(uniswapV4Params),
            resolverArgs: abi.encode(address(target))
        });

        params = new Factory.ModuleParam[](2);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(factory.DEFAULT_SPLIT_RATIO_BPS().toUint16(), 100, 200, 50, 10000))
        });
        params[1] = Factory.ModuleParam({
            moduleType: POOL_FEE_MODULE_INDEX,
            implementation: poolFeeModule_logic,
            immutableData: abi.encode(
                FeePctsPoolLib.pack(POOL_FEE_SPLIT_RATIO_BPS, POOL_FEE_AMM_FEE_PARAMS, POOL_FEE_RESERVE_FEE_BPS)
            )
        });
    }

    function getTokiPoolDeploymentParams()
        internal
        view
        returns (ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params)
    {
        uniswapV4Params = ITokiHook.TokiPoolDeploymentParams({
            hook: address(tokiHook),
            pausableFlags: Flags16.wrap(0),
            salt: 0x0,
            hookParams: abi.encode(uint16(10), abi.encode(16240223350842364143, 1098960161431879138)),
            hooklet: IHooklet(address(0)),
            hookletParams: "",
            vault0: vault0,
            vault1: vault1,
            vault0Params: abi.encode(0, 6_000, 8_000, 3_000), // vaultFlag, target, max, min
            vault1Params: abi.encode(0, 10_000, 10_000, 10_000), // vaultFlag, target, max, min
            liquidityTokenImmutableData: abi.encode("test_pool_metadata"),
            liquidityTokenImplementation: liquidityTokenImplementation
        });
    }
}
