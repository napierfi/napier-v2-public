// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";
import {SaltMiner} from "../../SaltMiner.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {Factory} from "src/Factory.sol";
import {IHooklet} from "src/interfaces/IHooklet.sol";
import {ITokiHook} from "src/hooks/TokiHook.sol";
import {TokiPoolToken} from "src/tokens/TokiPoolToken.sol";

import {CREATE3} from "solady/src/utils/CREATE3.sol";
import {EfficientHashLib} from "solady/src/utils/EfficientHashLib.sol";

import {Commands} from "src/zap/uniswap/Commands.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Events.sol";

contract CreatePoolTest is UniswapV4ZapBase {
    using CurrencyLibrary for Currency;
    using SafeCastLib for uint256;

    // Test amounts
    uint256 internal INITIAL_LIQUIDITY_UNDERLYING;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public virtual override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _label();

        INITIAL_LIQUIDITY_UNDERLYING = 50000 * tOne;
    }

    function _approveZap(address user, Currency currency, uint160 amount) internal {
        vm.prank(user);
        permit2.approve(Currency.unwrap(currency), address(zap), amount, (block.timestamp * 2).toUint48());
    }

    function _approveZap(address user, address token, uint160 amount) internal {
        _approveZap(user, Currency.wrap(token), amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TEST HELPERS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Predict the deployment address for a TokiPool using CREATE3
    /// @param originalSalt The original salt from suite.poolArgs
    /// @param sender The address that will call the zap
    /// @return predicted The predicted deployment address
    function _predictPoolDeploymentAddress(bytes32 originalSalt, address sender)
        internal
        view
        returns (address predicted)
    {
        bytes32 senderBytes = bytes32(uint256(uint160(sender)));
        bytes32 hashedSalt = EfficientHashLib.hash(senderBytes, originalSalt);
        predicted = CREATE3.predictDeterministicAddress(hashedSalt, address(tokiHook));
    }

    struct BalanceSnapshot {
        uint256 underlyingBalance;
        uint256 ptBalance;
        uint256 liquidityBalance;
    }

    function _snapshotBalance(address user) internal view returns (BalanceSnapshot memory state) {
        state.underlyingBalance = poolKey.currency0.balanceOf(user);
        state.ptBalance = poolKey.currency1.balanceOf(user);
        state.liquidityBalance = SafeTransferLib.balanceOf(pool, user);
    }

    function _getCommands() internal pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(Commands.TP_CREATE_POOL)));
    }

    function _buildSuiteAndModules()
        internal
        view
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory modules)
    {
        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = ITokiHook.TokiPoolDeploymentParams({
            hook: address(tokiHook),
            pausableFlags: Flags16.wrap(0),
            salt: 0xaead0cc698843ef9708d44802286d691a5358ad05f2fe6b8b2cf8cb75df2ec8f,
            hookParams: abi.encode(uint16(100), abi.encode(16240223350842364143, 1098960161431879138)), // cardinalityNext=100, (scalarRoot, initialAnchor)
            hooklet: IHooklet(address(0)),
            hookletParams: "",
            vault0: vault0,
            vault1: vault1,
            vault0Params: abi.encode(
                0, // vault0Flags
                rehypothecationConfig0.targetRawTokenRatio,
                rehypothecationConfig0.maxRawTokenRatio,
                rehypothecationConfig0.minRawTokenRatio
            ),
            vault1Params: abi.encode(
                0, // vault1Flags
                rehypothecationConfig1.targetRawTokenRatio,
                rehypothecationConfig1.maxRawTokenRatio,
                rehypothecationConfig1.minRawTokenRatio
            ),
            liquidityTokenImmutableData: "",
            liquidityTokenImplementation: liquidityTokenImplementation
        });

        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: tokiPoolDeployer,
            poolArgs: abi.encode(uniswapV4Params),
            resolverArgs: abi.encode(target)
        });

        modules = new Factory.ModuleParam[](2);
        modules[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(uint16(factory.DEFAULT_SPLIT_RATIO_BPS()), 100, 200, 50, 10000))
        });
        modules[1] = Factory.ModuleParam({
            moduleType: POOL_FEE_MODULE_INDEX,
            implementation: poolFeeModule_logic,
            immutableData: abi.encode(
                FeePctsPoolLib.pack(POOL_FEE_SPLIT_RATIO_BPS, POOL_FEE_AMM_FEE_PARAMS, POOL_FEE_RESERVE_FEE_BPS)
            )
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     CREATE POOL TESTS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _test_CreatePool() internal {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory modules) = _buildSuiteAndModules();

        uint256 expiry = block.timestamp + 365 days;
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint, address(zap));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(suite, modules, expiry, curator, salt);

        // Extract original salt from suite.poolArgs to predict deployment
        ITokiHook.TokiPoolDeploymentParams memory deployParams =
            abi.decode(suite.poolArgs, (ITokiHook.TokiPoolDeploymentParams));

        // Predict the pool deployment address using the salt
        address predictedPoolAddress = _predictPoolDeploymentAddress(deployParams.salt, alice);

        // Record factory deployed event to get the addresses
        vm.recordLogs();

        vm.prank(alice);
        zap.execute(_getCommands(), inputs);

        // Extract deployed addresses from recorded events
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Look for the Deployed event from Factory
        address liquidityToken;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployed(address,address,address,uint256,address)")) {
                address _pt = address(uint160(uint256(logs[i].topics[1])));
                address _yt = address(uint160(uint256(logs[i].topics[2])));
                address _pool = address(uint160(uint256(logs[i].topics[3])));
                liquidityToken = _pool;
                // Update state variables
                assembly {
                    sstore(principalToken.slot, _pt)
                    sstore(yt.slot, _yt)
                    sstore(pool.slot, _pool)
                }
                poolKey = TokiPoolToken(_pool).i_poolKey();
                resolver = principalToken.i_resolver();
                break;
            }
        }

        // Assertions
        assertEq(address(principalToken.i_yt()), address(yt));
        assertEq(Currency.unwrap(poolKey.currency0), address(target));
        assertEq(Currency.unwrap(poolKey.currency1), address(principalToken));
        assertEq(keccak256(abi.encode(tokiHook.poolKeyOf(liquidityToken))), keccak256(abi.encode(poolKey)));

        assertEq(liquidityToken, predictedPoolAddress, "salted salt");
    }

    function test_CreatePool() public {
        _test_CreatePool();
    }
}
