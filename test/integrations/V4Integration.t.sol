// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {SaltMiner} from "../SaltMiner.sol";

import {Base, UniswapV4Base, UniswapV4ZapBase} from "../UniswapV4Base.t.sol";
import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {TokiPoolToken} from "src/tokens/TokiPoolToken.sol";
import {ITokiHook} from "src/hooks/TokiHook.sol";
import {IHooklet} from "src/interfaces/IHooklet.sol";
import {UniswapV4Router} from "src/zap/uniswap/UniswapV4Router.sol";

import {ConstantPriceResolver} from "src/modules/resolvers/ConstantPriceResolver.sol";
import {CustomConversionResolver} from "src/modules/resolvers/CustomConversionResolver.sol";
import {ERC4626InfoResolver} from "src/modules/resolvers/ERC4626InfoResolver.sol";
import {ExternalPriceResolver} from "src/modules/resolvers/ExternalPriceResolver.sol";
import {SharePriceResolver} from "src/modules/resolvers/SharePriceResolver.sol";
import {ChainlinkResolver} from "src/modules/resolvers/ChainlinkResolver.sol";

import {LibBlueprint} from "src/utils/LibBlueprint.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {FeePctsPoolLib} from "src/utils/FeePctsPoolLib.sol";
import {TokiSwap} from "src/utils/TokiSwap.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";
import {IV4Router} from "src/zap/modules/v4-periphery/IV4Router.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IAllowanceTransfer} from "@uniswap/universal-router/contracts/modules/Permit2Payments.sol";

import {Errors} from "src/Errors.sol";
import "src/Constants.sol" as Constants;
import "src/Types.sol";

using {TokenType.intoToken} for address;
using SafeCastLib for uint256;

abstract contract V4IntegrationTest is UniswapV4ZapBase {
    bytes32 constant _PERMIT_DETAILS_TYPEHASH =
        keccak256("PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)");

    bytes32 constant _PERMIT_SINGLE_TYPEHASH = keccak256(
        "PermitSingle(PermitDetails details,address spender,uint256 sigDeadline)PermitDetails(address token,uint160 amount,uint48 expiration,uint48 nonce)"
    );

    // forgefmt: disable-start
    address constant_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(ConstantPriceResolver).creationCode);
    address erc4626_resolver_blueprint = LibBlueprint.deployBlueprint(type(ERC4626InfoResolver).creationCode);
    address custom_conversion_resolver_blueprint = LibBlueprint.deployBlueprint(type(CustomConversionResolver).creationCode);
    address share_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(SharePriceResolver).creationCode);
    address external_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(ExternalPriceResolver).creationCode);
    address chainlink_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(ChainlinkResolver).creationCode);
    // forgefmt: disable-end

    IHooklet constant ZERO_HOOKLET = IHooklet(address(0));

    bytes32 DOMAIN_SEPARATOR;

    uint256 privteKey = 0x1234567890abcdef;

    function _deployTokens() internal virtual override {}

    function getDeploymentParams()
        public
        view
        virtual
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params);

    function getParamsForERC4626Resolver()
        public
        view
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        FeePcts feePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183);

        (uint256 scalarRoot, int256 initialRateAnchor) = TokiSwap.computeOptimalParameters(0.085e18, 0.185e18, expiry);

        ITokiHook.TokiPoolDeploymentParams memory uniswapV4Params = ITokiHook.TokiPoolDeploymentParams({
            hook: address(tokiHook),
            pausableFlags: Flags16.wrap(0),
            salt: bytes32(uint256(0x123)),
            hookParams: abi.encode(uint16(100), abi.encode(scalarRoot, initialRateAnchor)),
            hooklet: ZERO_HOOKLET,
            hookletParams: "",
            vault0: vault0,
            vault1: vault1,
            vault0Params: abi.encode(0, 5000, 6000, 4000),
            vault1Params: abi.encode(Constants.PAUSABLE_LP_DEPOSITS, 8000, 9000, 2000),
            liquidityTokenImmutableData: "",
            liquidityTokenImplementation: liquidityTokenImplementation
        });

        bytes memory poolArgs = abi.encode(uniswapV4Params);
        params = new Factory.ModuleParam[](2);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        params[1] = Factory.ModuleParam({
            moduleType: POOL_FEE_MODULE_INDEX,
            implementation: poolFeeModule_logic,
            immutableData: abi.encode(
                FeePctsPoolLib.pack(POOL_FEE_SPLIT_RATIO_BPS, POOL_FEE_AMM_FEE_PARAMS, POOL_FEE_RESERVE_FEE_BPS)
            )
        });
        bytes memory resolverArgs = abi.encode(address(target));
        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: erc4626_resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(tokiPoolDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }

    /// @dev Token that zap flows route through the vault connector, or zero when they trade the underlying directly.
    function _connectorToken() internal view virtual returns (address) {
        (Factory.Suite memory suite,) = getDeploymentParams();
        return suite.resolverBlueprint == erc4626_resolver_blueprint ? address(base) : address(0);
    }

    /// @dev Sets `to`'s balance of `token`. Override for tokens whose balances `deal` cannot write.
    function _dealToken(address token, address to, uint256 amount) internal virtual {
        deal(token, to, amount);
    }

    function setUp() public virtual override {
        assembly {
            sstore(weth.slot, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
        }
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        _label();

        DOMAIN_SEPARATOR = permit2.DOMAIN_SEPARATOR();
    }

    /// @dev Add new resolver deployment here
    function _setUpModules() internal virtual override {
        super._setUpModules();
        vm.startPrank(admin);
        factory.setResolverBlueprint(erc4626_resolver_blueprint, true);
        factory.setResolverBlueprint(share_price_resolver_blueprint, true);
        factory.setResolverBlueprint(external_price_resolver_blueprint, true);
        factory.setResolverBlueprint(custom_conversion_resolver_blueprint, true);
        factory.setResolverBlueprint(constant_price_resolver_blueprint, true);
        factory.setResolverBlueprint(chainlink_price_resolver_blueprint, true);
        vm.stopPrank();
    }

    function _deployInstance() internal virtual override(Base, UniswapV4Base) {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getDeploymentParams();

        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint);
        address predictedAddress = SaltMiner.predictPrincipalTokenAddress(address(factory), alice, salt, pt_blueprint);

        console2.log("predictedAddress", predictedAddress);

        vm.startPrank(alice);
        (address _pt,, address _pool) =
            factory.deployDeterministic({suite: suite, params: params, expiry: expiry, curator: curator, salt: salt});
        vm.stopPrank();

        // Store instances
        principalToken = PrincipalToken(_pt);
        yt = principalToken.i_yt();
        pool = _pool;
        poolKey = TokiPoolToken(_pool).i_poolKey();
        resolver = principalToken.i_resolver();
        accessManager = principalToken.i_accessManager();

        assertEq(predictedAddress, address(principalToken), "predictedAddress mismatch");
    }

    function testFork_Lifecycle() public virtual {
        uint256 initialDeposit = 5000 * tOne;

        _testFork_DepositInitialLiquidity(initialDeposit);

        // Remove liquidity
        vm.warp(expiry);

        uint256 balanceBefore = target.balanceOf(bob);

        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice);
        _testFork_RemoveLiquidity(liquidity);

        // Assert total assets invariant
        uint256 redeemed = target.balanceOf(bob) - balanceBefore;

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();

        vm.prank(alice);
        (uint256 collected,) = principalToken.collect(alice, alice);

        assertApproxEqRel(redeemed + collected + curatorFee + protocolFee, initialDeposit, 0.001e18, "collected");
    }

    function testFork_WithdrawPreMaturity() public virtual {
        uint256 initialDeposit = 500 * tOne;

        _testFork_DepositInitialLiquidity(initialDeposit);

        address connectorToken = _connectorToken();
        bool viaConnector = connectorToken != address(0);
        address tokenOut = viaConnector ? connectorToken : address(target);
        address user = vm.addr(privteKey);

        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice) / 100;
        assertGt(liquidity, 0, "liquidity should be available");

        // Hand LP tokens to the signer so the Permit2 flow mirrors production usage
        vm.prank(alice);
        SafeTransferLib.safeTransfer(pool, user, liquidity);

        vm.warp(block.timestamp + (expiry - block.timestamp) / 2);

        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(pool, uint160(liquidity), uint48(block.timestamp + 1 hours), 0);
        bytes memory sig = getPermitSignature(permit, privteKey, DOMAIN_SEPARATOR);

        bytes memory v4Actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)), bytes1(uint8(Actions.SETTLE)), bytes1(uint8(Actions.TAKE))
        );
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: poolKey,
                zeroForOne: false,
                amountIn: ActionConstants.CONTRACT_BALANCE,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        v4Params[1] = abi.encode(poolKey.currency1, ActionConstants.OPEN_DELTA, false);
        v4Params[2] = abi.encode(poolKey.currency0, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA);

        bytes memory commands;
        bytes[] memory inputs;

        if (viaConnector) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)),
                bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
                bytes1(uint8(Commands.V4_SWAP)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)),
                bytes1(uint8(Commands.SWEEP))
            );
            inputs = new bytes[](5);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(poolKey, liquidity, 0, 0, ActionConstants.ADDRESS_THIS);
            inputs[2] = abi.encode(v4Actions, v4Params);
            inputs[3] =
                abi.encode(target, base, tokenOut, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
            inputs[4] = abi.encode(tokenOut, ActionConstants.MSG_SENDER, 0);
        } else {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)),
                bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
                bytes1(uint8(Commands.V4_SWAP)),
                bytes1(uint8(Commands.SWEEP))
            );
            inputs = new bytes[](4);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(poolKey, liquidity, 0, 0, ActionConstants.ADDRESS_THIS);
            inputs[2] = abi.encode(v4Actions, v4Params);
            inputs[3] = abi.encode(tokenOut, ActionConstants.MSG_SENDER, 0);
        }

        uint256 userBalanceBefore = SafeTransferLib.balanceOf(tokenOut, user);
        uint256 liquidityBefore = SafeTransferLib.balanceOf(pool, user);

        vm.startPrank(user);
        SafeTransferLib.safeApprove(pool, address(permit2), type(uint256).max);
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        uint256 userBalanceAfter = SafeTransferLib.balanceOf(tokenOut, user);
        uint256 liquidityAfter = SafeTransferLib.balanceOf(pool, user);

        assertGt(userBalanceAfter, userBalanceBefore, "user should gain tokenOut");
        assertEq(liquidityAfter, liquidityBefore - liquidity, "LP position should be fully withdrawn");

        assertNoFundLeftInZap();
    }

    function testFork_BuyPrincipalToken() public virtual {
        // Set up initial liquidity
        uint256 initialDeposit = 5000 * tOne;
        _testFork_DepositInitialLiquidity(initialDeposit);

        // If the market routes through a vault connector, we trade the connector token
        // Otherwise, we trade the underlying token directly
        address connectorToken = _connectorToken();
        bool viaConnector = connectorToken != address(0);
        address tokenIn = viaConnector ? connectorToken : address(target);
        uint256 amountIn = 10 ** ERC20(tokenIn).decimals();
        address kakashi = vm.addr(privteKey); // Set up kakashi for permit signatures
        _dealToken(tokenIn, kakashi, amountIn);

        // Sign permit2 signature
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(tokenIn, uint160(amountIn), uint48(block.timestamp + 1 hours), 0);
        bytes memory sig = getPermitSignature(permit, privteKey, DOMAIN_SEPARATOR);

        // Once time approve for permit2
        vm.startPrank(kakashi);
        SafeTransferLib.safeApprove(tokenIn, address(permit2), type(uint256).max);
        permit2.approve(tokenIn, address(zap), uint160(amountIn), uint48(block.timestamp + 1 days));

        bytes memory commands;
        bytes[] memory inputs;
        if (viaConnector) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)),
                bytes1(uint8(Commands.V4_SWAP))
            );
            bytes memory v4Actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)), // Swap leftover underlying tokens due to approximation
                bytes1(uint8(Actions.SETTLE)),
                bytes1(uint8(Actions.TAKE_ALL)) // Pull back PT output
            );
            bytes[] memory v4Params = new bytes[](3);
            v4Params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: true, // underlying -> principalToken
                    amountIn: ActionConstants.CONTRACT_BALANCE,
                    amountOutMinimum: 0,
                    hookData: ""
                })
            ); // SWAP_EXACT_IN_SINGLE params
            v4Params[1] = abi.encode(target, ActionConstants.CONTRACT_BALANCE, false); // SETTLE params
            v4Params[2] = abi.encode(principalToken, 0); // TAKE_ALL params

            inputs = new bytes[](3);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(target, base, tokenIn, amountIn, ActionConstants.ADDRESS_THIS);
            inputs[2] = abi.encode(v4Actions, v4Params);
        } else {
            commands = abi.encodePacked(bytes1(uint8(Commands.PERMIT2_PERMIT)), bytes1(uint8(Commands.V4_SWAP)));
            bytes memory v4Actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE)),
                bytes1(uint8(Actions.TAKE_ALL))
            );
            bytes[] memory v4Params = new bytes[](3);
            v4Params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: true,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    hookData: ""
                })
            );
            v4Params[1] = abi.encode(target, amountIn, true);
            v4Params[2] = abi.encode(principalToken, 0);

            inputs = new bytes[](2);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(v4Actions, v4Params);
        }

        uint256 tokenInBalanceBefore = SafeTransferLib.balanceOf(tokenIn, kakashi);
        uint256 ptBalanceBefore = principalToken.balanceOf(kakashi);
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        uint256 tokenInBalanceAfter = SafeTransferLib.balanceOf(tokenIn, kakashi);
        uint256 ptBalanceAfter = principalToken.balanceOf(kakashi);
        assertEq(tokenInBalanceAfter, tokenInBalanceBefore - amountIn, "tokenIn balance");
        assertGt(ptBalanceAfter, ptBalanceBefore, "principalToken balance");

        assertNoFundLeftInZap();
    }

    function testFork_SellPrincipalToken() public virtual {
        // Set up initial liquidity
        uint256 initialDeposit = 5000 * tOne;
        _testFork_DepositInitialLiquidity(initialDeposit);

        // If the market routes through a vault connector, we trade the connector token
        // Otherwise, we trade the underlying token directly
        address connectorToken = _connectorToken();
        bool viaConnector = connectorToken != address(0);
        address tokenOut = viaConnector ? connectorToken : address(target);
        uint256 principalsIn = bOne;

        address kakashi = vm.addr(privteKey); // Set up kakashi for permit signatures
        deal(address(principalToken), kakashi, principalsIn);

        // Sign permit2 signature
        IAllowanceTransfer.PermitSingle memory permit = defaultERC20PermitAllowance(
            address(principalToken), uint160(principalsIn), uint48(block.timestamp + 1 hours), 0
        );
        bytes memory sig = getPermitSignature(permit, privteKey, DOMAIN_SEPARATOR);

        // Once time approve for permit2
        vm.startPrank(kakashi);
        SafeTransferLib.safeApprove(address(principalToken), address(permit2), type(uint256).max);
        permit2.approve(address(principalToken), address(zap), uint160(principalsIn), uint48(block.timestamp + 1 days));

        bytes memory commands;
        bytes[] memory inputs;
        if (viaConnector) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)),
                bytes1(uint8(Commands.V4_SWAP)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)),
                bytes1(uint8(Commands.SWEEP))
            );
            bytes memory v4Actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE))
            );
            bytes[] memory v4Params = new bytes[](3);
            v4Params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: false,
                    amountIn: uint128(principalsIn),
                    amountOutMinimum: 0,
                    hookData: ""
                })
            ); // SWAP_EXACT_IN_SINGLE params
            v4Params[1] = abi.encode(principalToken, principalsIn); // SETTLE_ALL params
            v4Params[2] = abi.encode(target, ActionConstants.ADDRESS_THIS, ActionConstants.OPEN_DELTA); // TAKE

            inputs = new bytes[](4);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(v4Actions, v4Params);
            inputs[2] =
                abi.encode(target, base, tokenOut, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
            inputs[3] = abi.encode(tokenOut, ActionConstants.MSG_SENDER, 0);
        } else {
            commands = abi.encodePacked(bytes1(uint8(Commands.PERMIT2_PERMIT)), bytes1(uint8(Commands.V4_SWAP)));
            bytes memory v4Actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            );
            bytes[] memory v4Params = new bytes[](3);
            v4Params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: false,
                    amountIn: principalsIn,
                    amountOutMinimum: 0,
                    hookData: ""
                })
            );
            v4Params[1] = abi.encode(principalToken, principalsIn);
            v4Params[2] = abi.encode(target, 0);

            inputs = new bytes[](2);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(v4Actions, v4Params);
        }

        uint256 tokenOutBalanceBefore = SafeTransferLib.balanceOf(tokenOut, kakashi);
        uint256 ptBalanceBefore = principalToken.balanceOf(kakashi);
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        uint256 ptBalanceAfter = principalToken.balanceOf(kakashi);
        uint256 tokenOutBalanceAfter = SafeTransferLib.balanceOf(tokenOut, kakashi);
        assertEq(ptBalanceAfter, ptBalanceBefore - principalsIn, "principalToken balance");
        assertGt(tokenOutBalanceAfter, tokenOutBalanceBefore, "tokenOut balance");

        assertNoFundLeftInZap();
    }

    function testFork_BuyYieldToken() public virtual {
        // Set up initial liquidity
        uint256 initialDeposit = 5000 * tOne;
        _testFork_DepositInitialLiquidity(initialDeposit);

        // If the market routes through a vault connector, we trade the connector token
        // Otherwise, we trade the underlying token directly
        address connectorToken = _connectorToken();
        bool viaConnector = connectorToken != address(0);
        address tokenIn = viaConnector ? connectorToken : address(target);
        uint256 amountIn = 10 ** ERC20(tokenIn).decimals();
        address kakashi = vm.addr(privteKey); // Set up kakashi for permit signatures
        _dealToken(tokenIn, kakashi, amountIn);

        // Sign permit2 signature
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(tokenIn, uint160(amountIn), uint48(block.timestamp + 1 hours), 0);
        bytes memory sig = getPermitSignature(permit, privteKey, DOMAIN_SEPARATOR);

        // Once time approve for permit2
        vm.startPrank(kakashi);
        SafeTransferLib.safeApprove(tokenIn, address(permit2), type(uint256).max);
        permit2.approve(tokenIn, address(zap), uint160(amountIn), uint48(block.timestamp + 1 days));

        bytes memory commands;
        bytes[] memory inputs;
        if (viaConnector) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)),
                bytes1(uint8(Commands.YT_SWAP_UNDERLYING_FOR_YT))
            );
            inputs = new bytes[](3);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(target, base, tokenIn, amountIn, ActionConstants.ADDRESS_THIS);
            inputs[2] = abi.encode(
                poolKey,
                ActionConstants.CONTRACT_BALANCE,
                0,
                ActionConstants.MSG_SENDER,
                ActionConstants.MSG_SENDER,
                ApproximationParams({guessMin: 0, guessMax: 0, eps: 0})
            );
        } else {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)), bytes1(uint8(Commands.YT_SWAP_UNDERLYING_FOR_YT))
            );
            inputs = new bytes[](2);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(
                poolKey,
                amountIn,
                0,
                ActionConstants.MSG_SENDER,
                ActionConstants.MSG_SENDER,
                ApproximationParams({guessMin: 0, guessMax: 0, eps: 0})
            );
        }

        uint256 tokenInBalanceBefore = SafeTransferLib.balanceOf(tokenIn, kakashi);
        uint256 ytBalanceBefore = yt.balanceOf(kakashi);
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        uint256 tokenInBalanceAfter = SafeTransferLib.balanceOf(tokenIn, kakashi);
        uint256 ytBalanceAfter = yt.balanceOf(kakashi);
        if (viaConnector) {
            assertEq(tokenInBalanceAfter, tokenInBalanceBefore - amountIn, "tokenIn balance");
        } else {
            assertLt(tokenInBalanceAfter, tokenInBalanceBefore, "tokenIn balance");
            assertApproxEqRel(tokenInBalanceBefore - tokenInBalanceAfter, amountIn, 0.01e18, "tokenIn spent");
        }
        assertGt(ytBalanceAfter, ytBalanceBefore, "yt balance");

        assertNoFundLeftInZap();
    }

    function testFork_SellYieldToken() public virtual {
        // Set up initial liquidity
        uint256 initialDeposit = 5000 * tOne;
        _testFork_DepositInitialLiquidity(initialDeposit);

        // If the market routes through a vault connector, we trade the connector token
        // Otherwise, we trade the underlying token directly
        address connectorToken = _connectorToken();
        bool viaConnector = connectorToken != address(0);
        address tokenOut = viaConnector ? connectorToken : address(target);
        uint256 principalsIn = bOne;

        address kakashi = vm.addr(privteKey); // Set up kakashi for permit signatures
        deal(address(yt), kakashi, principalsIn);

        // Sign permit2 signature
        IAllowanceTransfer.PermitSingle memory permit =
            defaultERC20PermitAllowance(address(yt), uint160(principalsIn), uint48(block.timestamp + 1 hours), 0);
        bytes memory sig = getPermitSignature(permit, privteKey, DOMAIN_SEPARATOR);

        // Once time approve for permit2
        vm.startPrank(kakashi);
        SafeTransferLib.safeApprove(address(yt), address(permit2), type(uint256).max);
        permit2.approve(address(yt), address(zap), uint160(principalsIn), uint48(block.timestamp + 1 days));

        bytes memory commands;
        bytes[] memory inputs;
        if (viaConnector) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)),
                bytes1(uint8(Commands.YT_SWAP_YT_FOR_UNDERLYING)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)),
                bytes1(uint8(Commands.SWEEP))
            );
            inputs = new bytes[](4);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(poolKey, principalsIn, 0, ActionConstants.ADDRESS_THIS);
            inputs[2] =
                abi.encode(target, base, tokenOut, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
            inputs[3] = abi.encode(tokenOut, ActionConstants.MSG_SENDER, 0);
        } else {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.PERMIT2_PERMIT)), bytes1(uint8(Commands.YT_SWAP_YT_FOR_UNDERLYING))
            );
            inputs = new bytes[](2);
            inputs[0] = abi.encode(permit, sig);
            inputs[1] = abi.encode(poolKey, principalsIn, 0, ActionConstants.MSG_SENDER);
        }

        uint256 tokenOutBalanceBefore = SafeTransferLib.balanceOf(tokenOut, kakashi);
        uint256 ytBalanceBefore = yt.balanceOf(kakashi);
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        uint256 ytBalanceAfter = yt.balanceOf(kakashi);
        uint256 tokenOutBalanceAfter = SafeTransferLib.balanceOf(tokenOut, kakashi);
        assertEq(ytBalanceAfter, ytBalanceBefore - principalsIn, "yt balance");
        assertGt(tokenOutBalanceAfter, tokenOutBalanceBefore, "tokenOut balance");

        assertNoFundLeftInZap();
    }

    function _testFork_DepositInitialLiquidity(uint256 initialDeposit) internal virtual {
        _dealToken(address(target), alice, initialDeposit);

        uint256 underlyingToPt = initialDeposit * 2 / 3;
        uint256 previewPrincipal = principalToken.previewSupply(underlyingToPt);

        // Add liquidity
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.PT_SUPPLY)), bytes1(uint8(Commands.TP_ADD_LIQUIDITY)), bytes1(uint8(Commands.SWEEP))
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(principalToken, underlyingToPt, ActionConstants.ADDRESS_THIS);
        inputs[1] = abi.encode(
            poolKey, initialDeposit - underlyingToPt, ActionConstants.CONTRACT_BALANCE, 900, ActionConstants.MSG_SENDER
        );
        inputs[2] = abi.encode(address(yt), alice, 0);

        vm.startPrank(alice);
        SafeTransferLib.safeApprove(Currency.unwrap(poolKey.currency0), address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(poolKey.currency0), address(zap), type(uint160).max, type(uint48).max);

        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        assertEq(poolKey.currency0.balanceOf(alice), 0, "target balance");
        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice);
        assertGt(liquidity, 0, "liquidity");
        uint256 ytBalance = SafeTransferLib.balanceOf(address(yt), alice);
        assertEq(ytBalance, previewPrincipal, "ytBalance");
        assertNoFundLeftInZap();
    }

    function _testFork_RemoveLiquidity(uint256 liquidity) internal virtual {
        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
            bytes1(uint8(Commands.PT_REDEEM)),
            bytes1(uint8(Commands.SWEEP))
        );

        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(poolKey, liquidity, 0, 0, ActionConstants.ADDRESS_THIS);
        inputs[1] = abi.encode(principalToken, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
        inputs[2] = abi.encode(target, bob, 0);

        vm.startPrank(alice);
        SafeTransferLib.safeApprove(pool, address(permit2), type(uint256).max);
        permit2.approve(pool, address(zap), type(uint160).max, type(uint48).max);

        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();

        assertEq(principalToken.balanceOf(alice), 0, "principalToken balance");
        assertNoFundLeftInZap();
    }

    function testFork_CreateAndAddLiquidity() public virtual {
        PoolKey memory ZERO_KEY;
        uint256 desiredImpliedRate = 0.185e18;
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getDeploymentParams();
        address connectorToken = _connectorToken();
        bool viaConnector = connectorToken != address(0);
        address tokenIn = viaConnector ? connectorToken : address(target);
        uint256 assets = 1_000 * 10 ** ERC20(tokenIn).decimals();

        _dealToken(tokenIn, alice, assets);

        bytes32 salt = SaltMiner.findPrincipalTokenSalt(address(factory), alice, pt_blueprint, address(zap));
        bytes memory commands;
        bytes[] memory inputs;
        if (viaConnector) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.TP_CREATE_POOL)),
                bytes1(uint8(Commands.VAULT_CONNECTOR_DEPOSIT)),
                bytes1(uint8(Commands.TP_SPLIT_INITIAL_LIQUIDITY)),
                bytes1(uint8(Commands.TP_ADD_LIQUIDITY))
            );
            inputs = new bytes[](4);
            inputs[0] = abi.encode(suite, params, expiry, curator, salt);
            inputs[1] = abi.encode(target, base, tokenIn, assets, ActionConstants.ADDRESS_THIS);
            inputs[2] = abi.encode(ZERO_KEY, ActionConstants.CONTRACT_BALANCE, alice, desiredImpliedRate);
            inputs[3] = abi.encode(
                ZERO_KEY,
                ActionConstants.CONTRACT_BALANCE,
                ActionConstants.CONTRACT_BALANCE,
                900,
                ActionConstants.MSG_SENDER
            );
        } else {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.TP_CREATE_POOL)),
                bytes1(uint8(Commands.TP_SPLIT_INITIAL_LIQUIDITY)),
                bytes1(uint8(Commands.TP_ADD_LIQUIDITY))
            );
            inputs = new bytes[](3);
            inputs[0] = abi.encode(suite, params, expiry, curator, salt);
            inputs[1] = abi.encode(ZERO_KEY, assets, alice, desiredImpliedRate);
            inputs[2] = abi.encode(
                ZERO_KEY,
                ActionConstants.CONTRACT_BALANCE,
                ActionConstants.CONTRACT_BALANCE,
                900,
                ActionConstants.MSG_SENDER
            );
        }

        vm.startPrank(alice);
        SafeTransferLib.safeApprove(tokenIn, address(permit2), type(uint256).max);
        permit2.approve(tokenIn, address(zap), type(uint160).max, type(uint48).max);

        vm.recordLogs();
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("Deployed(address,address,address,uint256,address)")) {
                address _pt = address(uint160(uint256(logs[i].topics[1])));
                address _yt = address(uint160(uint256(logs[i].topics[2])));
                address _pool = address(uint160(uint256(logs[i].topics[3])));
                pool = _pool;
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

        uint256 liquidity = SafeTransferLib.balanceOf(pool, alice);
        assertGt(liquidity, 0, "liquidity");
        assertNoFundLeftInZap();
    }

    function defaultERC20PermitAllowance(address token, uint160 amount, uint48 expiration, uint48 nonce)
        internal
        view
        returns (IAllowanceTransfer.PermitSingle memory)
    {
        IAllowanceTransfer.PermitDetails memory details =
            IAllowanceTransfer.PermitDetails({token: token, amount: amount, expiration: expiration, nonce: nonce});
        return IAllowanceTransfer.PermitSingle({
            details: details,
            spender: address(zap),
            sigDeadline: block.timestamp + 100
        });
    }

    function getPermitSignatureRaw(
        IAllowanceTransfer.PermitSingle memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 permitHash = keccak256(abi.encode(_PERMIT_DETAILS_TYPEHASH, permit.details));

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                domainSeparator,
                keccak256(abi.encode(_PERMIT_SINGLE_TYPEHASH, permitHash, permit.spender, permit.sigDeadline))
            )
        );

        (v, r, s) = vm.sign(privateKey, msgHash);
    }

    function getPermitSignature(
        IAllowanceTransfer.PermitSingle memory permit,
        uint256 privateKey,
        bytes32 domainSeparator
    ) internal pure returns (bytes memory sig) {
        (uint8 v, bytes32 r, bytes32 s) = getPermitSignatureRaw(permit, privateKey, domainSeparator);
        return bytes.concat(r, s, bytes1(v));
    }
}
