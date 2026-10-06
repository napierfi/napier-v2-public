// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";
import {SaltMiner} from "../../SaltMiner.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {ITokiHook} from "src/hooks/TokiHook.sol";
import {IHooklet} from "src/interfaces/IHooklet.sol";
import {TokiSwap} from "src/utils/TokiSwap.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract QuoteCreateAndAddLiquidityTest is ZapSwapTest {
    function _getDeploymentParams(uint256 rateMin, uint256 rateMax)
        internal
        view
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        // Compute pool init params (scalarRoot, initialAnchor)
        (uint256 scalarRoot, int256 initialRateAnchor) = TokiSwap.computeOptimalParameters(rateMin, rateMax, expiry);

        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = ITokiHook.TokiPoolDeploymentParams({
            hook: address(tokiHook),
            pausableFlags: Flags16.wrap(0),
            salt: bytes32(uint256(0x123)),
            hookParams: abi.encode(uint16(100), abi.encode(scalarRoot, initialRateAnchor)),
            hooklet: IHooklet(address(0)),
            hookletParams: "",
            vault0: vault0,
            vault1: vault1,
            vault0Params: abi.encode(0, 5000, 6000, 4000),
            vault1Params: abi.encode(0, 8000, 9000, 2000),
            liquidityTokenImmutableData: "",
            liquidityTokenImplementation: liquidityTokenImplementation
        });

        bytes memory poolArgs = abi.encode(uniswapV4Params);
        bytes memory resolverArgs = abi.encode(address(target));

        // Minimal modules: Fee + PoolFee
        params = new Factory.ModuleParam[](2);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183))
        });
        params[1] = Factory.ModuleParam({
            moduleType: POOL_FEE_MODULE_INDEX,
            implementation: poolFeeModule_logic,
            immutableData: abi.encode(
                FeePctsPoolLib.pack(POOL_FEE_SPLIT_RATIO_BPS, POOL_FEE_AMM_FEE_PARAMS, POOL_FEE_RESERVE_FEE_BPS)
            )
        });

        suite = Factory.Suite({
            accessManagerImpl: address(accessManager_logic),
            resolverBlueprint: address(resolver_blueprint),
            ptBlueprint: address(pt_blueprint),
            poolDeployerImpl: address(tokiPoolDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }

    struct MarketCreationFuzzInput {
        address sender;
        uint256 amount0Desired;
        uint256 rateMin;
        uint256 rateMax;
    }

    // Simulate: CREATE_POOL -> SPLIT_INITIAL_LIQUIDITY -> ADD_LIQUIDITY
    function _simulate(MarketCreationFuzzInput memory input)
        internal
        returns (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent)
    {
        amount0Spent; // silence warning
        uint256 snapshot = vm.snapshot();

        (liquidity, amount0Spent, amount1Spent) = _createMarket(input);
        // Clean up mutated state
        vm.revertTo(snapshot);
    }

    function _createMarket(MarketCreationFuzzInput memory input)
        public
        returns (uint256 liquidity, uint256 amount0Spent, uint256 amount1Spent)
    {
        amount0Spent; // silence warning
        // Arrange: ensure sender holds underlying (ERC4626 shares) and approve router
        deal(address(target), input.sender, input.amount0Desired);
        _approveZap(input.sender, address(target), type(uint160).max);

        // Prepare commands
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.TP_CREATE_POOL)),
            bytes1(uint8(Commands.TP_SPLIT_INITIAL_LIQUIDITY)),
            bytes1(uint8(Commands.TP_ADD_LIQUIDITY))
        );

        (Factory.Suite memory suite, Factory.ModuleParam[] memory modules) =
            _getDeploymentParams({rateMin: input.rateMin, rateMax: input.rateMax});

        // Compute a salt yielding PT address ordering compatible with V4 pool (PT > currency0)
        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), input.sender, pt_blueprint, address(zap));

        PoolKey memory ZERO_KEY;
        bytes[] memory inputs = new bytes[](3);
        // 0: TP_CREATE_POOL
        inputs[0] = abi.encode(suite, modules, expiry, curator, salt);
        // 1: TP_SPLIT_INITIAL_LIQUIDITY (pay underlying from sender via Permit2)
        inputs[1] = abi.encode(
            ZERO_KEY, input.amount0Desired, input.sender, getDesiredImpliedRate(input.rateMin, input.rateMax)
        );
        // 2: TP_ADD_LIQUIDITY (use router contract balance for both amounts)
        inputs[2] = abi.encode(
            ZERO_KEY,
            ActionConstants.CONTRACT_BALANCE,
            ActionConstants.CONTRACT_BALANCE,
            0, // minLiquidity
            ActionConstants.MSG_SENDER
        );

        // Act: execute commands and capture deployment artifacts
        vm.startPrank(input.sender);
        vm.recordLogs();
        (bool success,) = address(zap).call(abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs));
        vm.stopPrank();

        // Extract deployed PT and Liquidity token addresses from Factory.Deployed event
        address deployedPt;
        address deployedPool;
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 topic = keccak256("Deployed(address,address,address,uint256,address)");
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) {
                    deployedPt = address(uint160(uint256(logs[i].topics[1])));
                    deployedPool = address(uint160(uint256(logs[i].topics[3])));
                    break;
                }
            }
        }

        vm.assume(success && deployedPt != address(0) && deployedPool != address(0));

        // The new PT supply equals principals minted during SPLIT; equals amount1Spent used to add liquidity
        amount1Spent = PrincipalToken(deployedPt).totalSupply();
        liquidity = SafeTransferLib.balanceOf(deployedPool, input.sender);
    }

    // Core test: simulate then quote and compare liquidity + PT spent
    function _test_Quote(MarketCreationFuzzInput memory input) internal {
        // Simulate
        (uint256 liquidity,, uint256 principals) = _simulate(input);

        // Quote
        (Factory.Suite memory suite, Factory.ModuleParam[] memory modules) =
            _getDeploymentParams({rateMin: input.rateMin, rateMax: input.rateMax});
        uint256 snapshot = vm.snapshot();
        vm.prank(input.sender);
        TokiQuoter.PreviewAddLiquidityResult memory result = quoter.quoteCreateAndAddLiquidity({
            suite: suite,
            modules: modules,
            expiry: expiry,
            amount0Desired: input.amount0Desired,
            desiredImpliedRate: getDesiredImpliedRate(input.rateMin, input.rateMax),
            currency0: address(target)
        });
        vm.revertTo(snapshot);

        // Assert
        assertEq(result.liquidity, liquidity, "Liquidity should match simulated");
        assertEq(result.amount1Spent, principals, "PT spent should match simulated (amount1)");
    }

    function getDesiredImpliedRate(uint256 rateMin, uint256 rateMax) internal pure returns (uint256) {
        return (rateMin + rateMax) / 2;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Quote() public {
        uint256 amount0Desired = 5_000 * tOne;
        MarketCreationFuzzInput memory input = MarketCreationFuzzInput({
            sender: alice,
            amount0Desired: amount0Desired,
            rateMin: 0.085e18,
            rateMax: 0.185e18
        });
        _test_Quote(input);
    }

    function testFuzz_Quote(uint256 deployedAt, MarketCreationFuzzInput memory input) public {
        assumeUnusedAddress(input.sender);
        deployedAt = bound(deployedAt, block.timestamp, expiry - 1);
        input.amount0Desired = bound(input.amount0Desired, tOne / 10, 1_000_000 * tOne);
        input.rateMin = bound(input.rateMin, 0.085e18, 0.185e18);
        input.rateMax = bound(input.rateMax, input.rateMin * 3 / 2, input.rateMin * 2);

        vm.warp(deployedAt);
        _test_Quote(input);
    }

    function test_Quote_NoSaltCollision() public {
        uint256 amount0Desired = 5_000 * tOne;
        MarketCreationFuzzInput memory input = MarketCreationFuzzInput({
            sender: alice,
            amount0Desired: amount0Desired,
            rateMin: 0.085e18,
            rateMax: 0.185e18
        });
        _test_Quote(input);
        _createMarket(input);

        (Factory.Suite memory suite, Factory.ModuleParam[] memory modules) =
            _getDeploymentParams({rateMin: input.rateMin, rateMax: input.rateMax});
        quoter.quoteCreateAndAddLiquidity({
            suite: suite,
            modules: modules,
            expiry: expiry,
            amount0Desired: input.amount0Desired,
            desiredImpliedRate: getDesiredImpliedRate(input.rateMin, input.rateMax),
            currency0: address(target)
        });
    }
}
