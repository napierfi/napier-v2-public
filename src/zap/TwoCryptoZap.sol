// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import "../Types.sol";
import {IHook} from "../interfaces/IHook.sol";
import {Factory} from "../Factory.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {VaultConnector} from "../modules/connectors/VaultConnector.sol";
import {VaultConnectorRegistry} from "../modules/connectors/VaultConnectorRegistry.sol";
import {AggregationRouter, RouterPayload} from "../modules/aggregator/AggregationRouter.sol";
// Libraries
import {LibTwoCryptoNG} from "../utils/LibTwoCryptoNG.sol";
import {ZapHookEncoder} from "../utils/ZapHookEncoder.sol";
import {ContractValidation} from "../utils/ContractValidation.sol";
import {LibExpiry} from "../utils/LibExpiry.sol";
import {Casting} from "../utils/Casting.sol";
import {CustomRevert} from "../utils/CustomRevert.sol";
import {TARGET_INDEX, PT_INDEX} from "../Constants.sol";
import {Events} from "../Events.sol";
import {Errors} from "../Errors.sol";
// Math
import {ZapMathLib} from "../utils/ZapMathLib.sol";
// Inherits
import {HookValidation} from "../utils/HookValidation.sol";
import {ZapBase} from "./ZapBase.sol";

contract TwoCryptoZap is ZapBase, HookValidation, IHook {
    using Casting for *;
    using LibTwoCryptoNG for TwoCrypto;
    using CustomRevert for bytes4;

    address internal immutable i_twoCryptoDeployer;
    Factory public immutable i_factory;
    VaultConnectorRegistry public immutable i_vaultConnectorRegistry;
    AggregationRouter public immutable i_aggregationRouter;

    receive() external payable {}

    constructor(
        Factory factory,
        VaultConnectorRegistry vaultConnectorRegistry,
        address twoCryptoDeployer,
        AggregationRouter aggregationRouter
    ) {
        i_factory = factory;
        i_vaultConnectorRegistry = vaultConnectorRegistry;
        i_twoCryptoDeployer = twoCryptoDeployer;
        i_aggregationRouter = aggregationRouter;
    }

    struct AddLiquidityOneTokenParams {
        TwoCrypto twoCrypto;
        Token tokenIn;
        uint256 amountIn;
        uint256 minLiquidity;
        uint256 minYt;
        address receiver;
        uint256 deadline;
    }

    struct AddLiquidityParams {
        TwoCrypto twoCrypto;
        uint256 shares;
        uint256 principal;
        uint256 minLiquidity;
        address receiver;
        uint256 deadline;
    }

    struct RemoveLiquidityOneTokenParams {
        TwoCrypto twoCrypto;
        uint256 liquidity;
        Token tokenOut;
        uint256 amountOutMin;
        address receiver;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        TwoCrypto twoCrypto;
        uint256 liquidity;
        uint256 minPrincipal;
        uint256 minShares;
        address receiver;
        uint256 deadline;
    }

    /// @notice Data structure for `swapTokenFor{Pt, Yt}` functions
    struct SwapTokenParams {
        TwoCrypto twoCrypto;
        Token tokenIn;
        uint256 amountIn;
        uint256 minPrincipal;
        address receiver;
        uint256 deadline;
    }

    /// @notice Data structure for `swapPtForToken` functions
    struct SwapPtParams {
        TwoCrypto twoCrypto;
        uint256 principal;
        Token tokenOut;
        uint256 amountOutMin;
        address receiver;
        uint256 deadline;
    }

    /// @notice Data structure for `swapYtForToken` functions
    /// @dev Actually this struct is same as SwapPtParams
    struct SwapYtParams {
        TwoCrypto twoCrypto;
        uint256 principal;
        Token tokenOut;
        uint256 amountOutMin;
        address receiver;
        uint256 deadline;
    }

    struct SwapTokenInput {
        Token tokenMintShares; // token to mint shares via connector
        RouterPayload swapData; // aggregator data
    }

    struct SwapTokenOutput {
        Token tokenRedeemShares; // token to redeem shares via connector
        RouterPayload swapData; // aggregator data
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    Liquidity Providing                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct CreateAndAddLiquidityParams {
        // Params for new deployment
        Factory.Suite suite;
        Factory.ModuleParam[] modules;
        uint256 expiry;
        address curator;
        // Params for initial liquidity
        uint256 shares;
        uint256 minYt;
        uint256 minLiquidity;
        uint256 deadline;
    }

    /// @notice Create new instance and deposit initial liquidity to the pool.
    /// @notice Similar to `addLiquidityOneToken` function, this function minimizes price impact on deposit
    function createAndAddLiquidity(CreateAndAddLiquidityParams calldata params)
        external
        nonReentrant
        checkDeadline(params.deadline)
        returns (address pt, address yt, address twoCrypto, uint256 liquidity, uint256 principal)
    {
        // Factory is AMM-agnostic. Make sure we're trying to create twoCrypto pool.
        if (params.suite.poolDeployerImpl != i_twoCryptoDeployer) Errors.Zap_BadPoolDeployer.selector.revertWith();

        (pt, yt, twoCrypto) = i_factory.deploy(params.suite, params.modules, params.expiry, params.curator);

        address underlying = TwoCrypto.wrap(twoCrypto).coins(TARGET_INDEX);

        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), params.shares);

        (liquidity, principal) = _addLiquidityOneUnderlying(
            AddLiquidityOneUnderlyingParams({
                twoCrypto: TwoCrypto.wrap(twoCrypto),
                principalToken: PrincipalToken(pt),
                underlying: underlying,
                shares: params.shares,
                minYt: params.minYt,
                minLiquidity: params.minLiquidity,
                receiver: msg.sender
            })
        );

        Events.emitZapAddLiquidityOneToken({
            by: msg.sender,
            receiver: msg.sender,
            twoCrypto: TwoCrypto.wrap(twoCrypto),
            liquidity: liquidity,
            ytOut: principal,
            tokenIn: Token.wrap(underlying),
            amountIn: params.shares
        });
    }

    /// @notice Issue some PT with some portion of `shares` and add the issued PT and remaining `shares` into `pool` and send back the LP tokens and YT to `receiver`
    /// with zero price impact
    function addLiquidityOneToken(AddLiquidityOneTokenParams calldata params)
        external
        payable
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 liquidity, uint256 principal)
    {
        TwoCrypto twoCrypto = params.twoCrypto;
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));
        address underlying = twoCrypto.coins(TARGET_INDEX);

        uint256 shares = _deposit(
            underlying, principalToken.i_asset().asAddr(), params.tokenIn, params.amountIn, address(this), msg.sender
        );

        (liquidity, principal) = _addLiquidityOneUnderlying(
            AddLiquidityOneUnderlyingParams({
                twoCrypto: twoCrypto,
                principalToken: principalToken,
                underlying: underlying,
                shares: shares,
                minYt: params.minYt,
                minLiquidity: params.minLiquidity,
                receiver: params.receiver
            })
        );

        Events.emitZapAddLiquidityOneToken({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            ytOut: principal,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn
        });
    }

    function addLiquidityAnyOneToken(AddLiquidityOneTokenParams calldata params, SwapTokenInput calldata tokenInput)
        external
        payable
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 liquidity, uint256 principal)
    {
        TwoCrypto twoCrypto = params.twoCrypto;
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));
        address underlying = twoCrypto.coins(TARGET_INDEX);

        _pullToken(params.tokenIn, params.amountIn);
        approveIfNeeded(params.tokenIn, address(i_aggregationRouter));

        {
            // Step 1: Swap input token to tokenMintShares using the aggregator
            uint256 tokenMintSharesAmount = i_aggregationRouter.swap{value: msg.value}({
                tokenIn: params.tokenIn,
                tokenOut: tokenInput.tokenMintShares,
                amountIn: params.amountIn,
                data: tokenInput.swapData,
                receiver: address(this)
            });

            // Step 2: Deposit tokenMintShares and get shares
            uint256 shares = _deposit(
                underlying,
                principalToken.i_asset().asAddr(),
                tokenInput.tokenMintShares,
                tokenMintSharesAmount,
                address(this),
                address(this)
            );

            (liquidity, principal) = _addLiquidityOneUnderlying(
                AddLiquidityOneUnderlyingParams({
                    twoCrypto: twoCrypto,
                    principalToken: principalToken,
                    underlying: underlying,
                    shares: shares,
                    minYt: params.minYt,
                    minLiquidity: params.minLiquidity,
                    receiver: params.receiver
                })
            );
        }

        Events.emitZapAddLiquidityOneToken({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            ytOut: principal,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn
        });

        _refund(params.tokenIn);
    }

    /// @dev Helper struct to avoid stack too deep errors
    struct AddLiquidityOneUnderlyingParams {
        TwoCrypto twoCrypto;
        PrincipalToken principalToken;
        address underlying;
        uint256 shares;
        uint256 minYt;
        uint256 minLiquidity;
        address receiver;
    }

    /// @dev Internal helper function to handle the common liquidity adding logic
    function _addLiquidityOneUnderlying(AddLiquidityOneUnderlyingParams memory params)
        internal
        returns (uint256 liquidity, uint256 principal)
    {
        uint256 sharesToPool =
            ZapMathLib.computeSharesToTwoCrypto(params.twoCrypto, params.principalToken, params.shares);

        // Split the `shares` into PT and shares
        approveIfNeeded(params.underlying, address(params.principalToken));
        principal = params.principalToken.supply(params.shares - sharesToPool, address(this));

        if (principal < params.minYt) Errors.Zap_InsufficientYieldTokenOutput.selector.revertWith();

        approveIfNeeded(address(params.principalToken), params.twoCrypto.unwrap());
        approveIfNeeded(params.underlying, params.twoCrypto.unwrap());

        // Add the issued PT and remaining `shares` into `twoCrypto`
        liquidity = params.twoCrypto.add_liquidity({
            amount0: sharesToPool,
            amount1: principal,
            minLiquidity: params.minLiquidity,
            receiver: params.receiver
        });
        SafeTransferLib.safeTransfer(params.principalToken.i_yt().asAddr(), params.receiver, principal);
    }

    /// @notice Forwards the call to the TwoCrypto contract to add liquidity
    function addLiquidity(AddLiquidityParams calldata params)
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 liquidity)
    {
        TwoCrypto twoCrypto = params.twoCrypto;
        address pt = twoCrypto.coins(PT_INDEX);
        address underlying = twoCrypto.coins(TARGET_INDEX);

        SafeTransferLib.safeTransferFrom(pt, msg.sender, address(this), params.principal);
        SafeTransferLib.safeTransferFrom(underlying, msg.sender, address(this), params.shares);

        approveIfNeeded(pt, twoCrypto.unwrap());
        approveIfNeeded(underlying, twoCrypto.unwrap());
        liquidity = twoCrypto.add_liquidity({
            amount0: params.shares,
            amount1: params.principal,
            minLiquidity: params.minLiquidity,
            receiver: params.receiver
        });

        Events.emitZapAddLiquidity({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            shares: params.shares,
            principal: params.principal
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  Liquidity Withdrawals                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Burn `liquidity` of `twoCrypto` LP token and convert the PT and underlying tokens to a single token `tokenOut` and send it to `receiver`
    /// @notice `tokenOut` must be supported by the connector or its underlying token.
    /// @notice When the PT is not expired, the withdrawn PT is swapped to shares on secondary market.
    /// @notice When the PT is expired, the withdrawn PT is redeemed for underlying tokens.
    /// @dev Flow: LP -> [twoCrypto] -> PT and underlying tokens -> [connector] -> tokenOut
    function removeLiquidityOneToken(RemoveLiquidityOneTokenParams calldata params)
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        amountOut = _removeLiquidityOneToken(params.twoCrypto, params.liquidity, params.tokenOut, params.receiver);

        if (amountOut < params.amountOutMin) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapRemoveLiquidityOneToken({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: params.twoCrypto,
            liquidity: params.liquidity,
            tokenOut: params.tokenOut,
            amountOut: amountOut
        });
    }

    /// @notice Same as `removeLiquidityOneToken` but with aggregator support for the `tokenOut`
    /// @notice `tokenOut` can be any token supported by `AggregationRouter`.
    function removeLiquidityAnyOneToken(
        RemoveLiquidityOneTokenParams calldata params,
        SwapTokenOutput calldata tokenOutput
    )
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        uint256 tokenRedeemSharesAmount =
            _removeLiquidityOneToken(params.twoCrypto, params.liquidity, tokenOutput.tokenRedeemShares, address(this));

        approveIfNeeded(tokenOutput.tokenRedeemShares, address(i_aggregationRouter));
        amountOut = i_aggregationRouter.swap{
            value: FixedPointMathLib.ternary(tokenOutput.tokenRedeemShares.isNative(), address(this).balance, 0)
        }({
            tokenIn: tokenOutput.tokenRedeemShares,
            tokenOut: params.tokenOut,
            amountIn: tokenRedeemSharesAmount,
            data: tokenOutput.swapData,
            receiver: params.receiver
        });

        if (amountOut < params.amountOutMin) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapRemoveLiquidityOneToken({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: params.twoCrypto,
            liquidity: params.liquidity,
            tokenOut: params.tokenOut,
            amountOut: amountOut
        });

        // `tokenRedeemShares` may be left in the contract.
        _refund(tokenOutput.tokenRedeemShares);
    }

    function _removeLiquidityOneToken(TwoCrypto twoCrypto, uint256 liquidity, Token tokenOut, address receiver)
        internal
        returns (uint256 amount)
    {
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));

        SafeTransferLib.safeTransferFrom(twoCrypto.unwrap(), msg.sender, address(this), liquidity);

        uint256 sharesWithdrawn;
        if (LibExpiry.isNotExpired(principalToken)) {
            sharesWithdrawn = twoCrypto.remove_liquidity_one_coin(liquidity, TARGET_INDEX, 0);
        } else {
            (uint256 shares, uint256 principal) = twoCrypto.remove_liquidity(liquidity, 0, 0);
            uint256 sharesFromPT = principalToken.redeem(principal, address(this), address(this));
            sharesWithdrawn = shares + sharesFromPT;
        }

        amount = _redeem({
            underlying: twoCrypto.coins(TARGET_INDEX),
            asset: principalToken.i_asset().asAddr(),
            tokenOut: tokenOut,
            shares: sharesWithdrawn,
            receiver: receiver
        });
    }

    /// @notice Forward the call to the TwoCrypto contract to remove liquidity
    function removeLiquidity(RemoveLiquidityParams calldata params)
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 shares, uint256 principal)
    {
        TwoCrypto twoCrypto = params.twoCrypto;

        SafeTransferLib.safeTransferFrom(twoCrypto.unwrap(), msg.sender, address(this), params.liquidity);

        (shares, principal) = twoCrypto.remove_liquidity({
            liquidity: params.liquidity,
            minAmount0: params.minShares,
            minAmount1: params.minPrincipal,
            receiver: params.receiver
        });

        Events.emitZapRemoveLiquidity({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            liquidity: params.liquidity,
            shares: shares,
            principal: principal
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    Swap Principal Token                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Swap `amountIn` of `token` to PT and send the PT to `receiver`
    /// @notice `token` must be supported by connector. Otherwise, the swap will fail.
    /// @notice When `token` is native ETH, wrap the asset to WETH, and when `token` is not native ETH, the caller must approve this contract to spend `amountIn` of `token`.
    /// @dev Flow: token -> [connector] -> shares -> [twoCrypto] -> PT
    /// @dev e.g. wstETH-PT (1) native ETH -> [connector]-> wstETH -> PT (2) stETH -> [connector] -> wsETH -> PT (3) wstETH -> PT (4) WETH -> [connector] -> wstETH -> PT
    ///  ┌────┐       ┌─────────┐          ┌──────┐┌───┐            ┌─────────┐
    ///  │User│       │Connector│          │wstETH││Zap│            │TwoCrypto│
    ///  └─┬──┘       └───┬─────┘          └──┬───┘└─┬─┘            └────┬────┘
    ///    │              │                 │      │                   │
    ///    │send nativeETH│                 │      │                   │
    ///    │─────────────>│                 │      │                   │
    ///    │              │                 │      │                   │
    ///    │              │convert to wstETH│      │                   │
    ///    │              │────────────────>│      │                   │
    ///    │              │                 │      │                   │
    ///    │              │   send wsETH    │      │                   │
    ///    │              │<────────────────│      │                   │
    ///    │              │                 │      │                   │
    ///    │              │      send wstETH│      │                   │
    ///    │              │───────────────────────>│                   │
    ///    │              │                 │      │                   │
    ///    │              │                 │      │swap wstETH on pool│
    ///    │              │                 │      │──────────────────>│
    ///    │              │                 │      │                   │
    ///    │              │           send PT      │                   │
    ///    │<──────────────────────────────────────────────────────────│
    ///  ┌─┴──┐       ┌───┴─────┐          ┌──┴───┐┌─┴─┐            ┌────┴────┐
    ///  │User│       │Connector│          │wstETH││Zap│            │TwoCrypto│
    ///  └────┘       └─────────┘          └──────┘└───┘            └─────────┘
    function swapTokenForPt(SwapTokenParams calldata params)
        external
        payable
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 ptOut)
    {
        // At this point, `twoCrypto` is verified as an instance deployed from our factory
        TwoCrypto twoCrypto = params.twoCrypto;
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));
        address underlying = twoCrypto.coins(TARGET_INDEX);

        // Deposit tokens and get shares
        uint256 shares = _deposit(
            underlying,
            principalToken.i_asset().asAddr(),
            params.tokenIn,
            params.amountIn,
            twoCrypto.unwrap(),
            msg.sender
        );

        // Swap shares for PT using TwoCrypto
        ptOut =
            twoCrypto.exchange_received({i: TARGET_INDEX, j: PT_INDEX, dx: shares, minDy: 0, receiver: params.receiver});

        if (ptOut < params.minPrincipal) Errors.Zap_InsufficientPrincipalTokenOutput.selector.revertWith();

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            tokenOut: Token.wrap(address(principalToken)),
            amountOut: ptOut
        });
    }

    /// @notice Swap any token to another token through an aggregator and then swap the token to PT
    /// @notice `tokenMintShares` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice When `token` is not native ETH, the caller must approve this contract to spend `amountIn` of `token`.
    /// @dev Flow: token -> [aggregator] -> tokenMintShares -> [connector] -> shares -> [twoCrypto] -> PT OR token -> [aggregator] -> shares(=tokenMintShares) -> [twoCrypto] -> PT
    /// @dev e.g. wstETH-PT (1) USDC -> [aggregator] -> WETH -> [connector]-> wstETH -> PT (2) USDC -> [aggregator] -> wstETH -> PT (3) USDC -> [aggregator] -> stETH -> [connector] -> wsETH -> PT
    function swapAnyTokenForPt(SwapTokenParams calldata params, SwapTokenInput calldata tokenInput)
        external
        payable
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 ptOut)
    {
        TwoCrypto twoCrypto = params.twoCrypto;
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));
        address underlying = twoCrypto.coins(TARGET_INDEX);

        _pullToken(params.tokenIn, params.amountIn);

        approveIfNeeded(params.tokenIn, address(i_aggregationRouter));

        // Step 1: Swap input token to tokenMintShares using the aggregator
        uint256 tokenMintSharesAmount = i_aggregationRouter.swap{value: msg.value}({
            tokenIn: params.tokenIn,
            tokenOut: tokenInput.tokenMintShares,
            amountIn: params.amountIn,
            data: tokenInput.swapData,
            receiver: address(this)
        });

        // Step 2: Deposit tokenMintShares and get shares
        uint256 shares = _deposit(
            underlying,
            principalToken.i_asset().asAddr(),
            tokenInput.tokenMintShares,
            tokenMintSharesAmount,
            twoCrypto.unwrap(),
            address(this)
        );

        // Step 3: Swap shares for PT using TwoCrypto
        ptOut =
            twoCrypto.exchange_received({i: TARGET_INDEX, j: PT_INDEX, dx: shares, minDy: 0, receiver: params.receiver});

        if (ptOut < params.minPrincipal) Errors.Zap_InsufficientPrincipalTokenOutput.selector.revertWith();

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            tokenOut: Token.wrap(address(principalToken)),
            amountOut: ptOut
        });

        _refund(params.tokenIn);
    }

    /// @notice Swap `principal` of PT to at least `minAmount` of `token` and send the `token` to `receiver`
    /// @notice `token` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice Caller must approve this contract to spend `principal` of PT.
    /// @dev Flow: PT -> [twoCrypto] -> shares -> [connector] -> token
    /// @dev e.g. wstETH-PT (1) PT -> wstETH (2) PT -> wstETH -> [connector] -> stETH
    /// @dev e.g. rETH-PT (1) PT -> rETH (2) PT -> rETH -> [connector] -> WETH (3) PT -> rETH -> [connector] -> native ETH
    function swapPtForToken(SwapPtParams calldata params)
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        PrincipalToken principalToken = PrincipalToken(params.twoCrypto.coins(PT_INDEX));
        address underlying = params.twoCrypto.coins(TARGET_INDEX);

        SafeTransferLib.safeTransferFrom(
            address(principalToken), msg.sender, params.twoCrypto.unwrap(), params.principal
        );
        // Swap PT for shares in TwoCrypto
        uint256 shares =
            params.twoCrypto.exchange_received({i: PT_INDEX, j: TARGET_INDEX, dx: params.principal, minDy: 0});

        // If the token is the same as the underlying, we're done
        amountOut = _redeem(underlying, principalToken.i_asset().asAddr(), params.tokenOut, shares, params.receiver);

        if (amountOut < params.amountOutMin) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: params.twoCrypto,
            tokenIn: Token.wrap(address(principalToken)),
            amountIn: params.principal,
            tokenOut: params.tokenOut,
            amountOut: amountOut
        });
    }

    /// @notice Swap `principal` of PT to at least `minAmount` of `token` and send the `token` to `receiver`
    /// @notice `tokenRedeemShares` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice Caller must approve this contract to spend `principal` of PT.
    /// @dev Flow: PT -> [twoCrypto] -> shares -> [aggregator] -> tokenRedeemShares -> [connector] -> token
    /// @dev e.g. wstETH-PT (1) PT -> wstETH -> [aggregator] -> USDC (2) PT -> wstETH -> [connector] -> stETH -> [aggregator] -> native ETH
    function swapPtForAnyToken(SwapPtParams calldata params, SwapTokenOutput calldata tokenOutput)
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        PrincipalToken principalToken = PrincipalToken(params.twoCrypto.coins(PT_INDEX));
        address underlying = params.twoCrypto.coins(TARGET_INDEX);

        // Transfer PT from user to TwoCrypto pool
        SafeTransferLib.safeTransferFrom(
            address(principalToken), msg.sender, params.twoCrypto.unwrap(), params.principal
        );

        // Swap PT for shares in TwoCrypto
        uint256 shares =
            params.twoCrypto.exchange_received({i: PT_INDEX, j: TARGET_INDEX, dx: params.principal, minDy: 0});

        uint256 tokenRedeemSharesAmount =
            _redeem(underlying, principalToken.i_asset().asAddr(), tokenOutput.tokenRedeemShares, shares, address(this));

        approveIfNeeded(tokenOutput.tokenRedeemShares, address(i_aggregationRouter));

        // Determine the value to send with the swap call
        uint256 valueToSend =
            FixedPointMathLib.ternary(tokenOutput.tokenRedeemShares.isNative(), address(this).balance, 0);

        // Swap tokenRedeemShares for the desired token using the aggregator
        amountOut = i_aggregationRouter.swap{value: valueToSend}({
            tokenIn: tokenOutput.tokenRedeemShares,
            tokenOut: params.tokenOut,
            amountIn: tokenRedeemSharesAmount,
            data: tokenOutput.swapData,
            receiver: params.receiver
        });
        if (amountOut < params.amountOutMin) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: params.twoCrypto,
            tokenIn: Token.wrap(address(principalToken)),
            amountIn: params.principal,
            tokenOut: params.tokenOut,
            amountOut: amountOut
        });

        // Note that the remaining of `tokenRedeemShares` are left in the contract because the result of swap on the twoCrypto may be different from the estimation
        _refund(tokenOutput.tokenRedeemShares);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      Swap Yield Token                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Swap `amountIn` of `token` to YT and send the YT to `receiver`
    /// @notice `token` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice When `token` is native ETH, wrap the asset to WETH, and when `token` is not native ETH, the caller must approve this contract to spend `amountIn` of `token`.
    /// @dev Flow: token -> [connector] -> shares -> [twoCrypto] -> YT
    /// @dev e.g. wstETH-YT (1) native ETH -> [connector]-> wstETH -> YT (2) stETH -> [connector] -> wsETH -> YT (3) wstETH -> YT (4) WETH -> [connector] -> wstETH -> YT
    ///  ┌────┐                     ┌───┐           ┌─────────┐             ┌───────┐┌─────────┐
    ///  │User│                     │Zap│           │Connector│             │PrincipalToken││TwoCrypto│
    ///  └─┬──┘                     └─┬─┘           └───┬─────┘             └───┬───┘└────┬────┘
    ///    │                          │                 │                     │         │
    ///    │        Send token        │                 │                     │         │
    ///    │─────────────────────────>│                 │                     │         │
    ///    │                          │                 │                     │         │
    ///    │                          │Convert to shares│                     │         │
    ///    │                          │────────────────>│                     │         │
    ///    │                          │                 │                     │         │
    ///    │                          │          Invoke flashmint op          │         │
    ///    │                          │──────────────────────────────────────>│         │
    ///    │                          │                 │                     │         │
    ///    │                          │Mint PT and YT with callback (onSupply)│         │
    ///    │                          │<──────────────────────────────────────│         │
    ///    │                          │                 │                     │         │
    ///    │                          │              swap the PT to shares    │         │
    ///    │                          │────────────────────────────────────────────────>│
    ///    │                          │                 │                     │         │
    ///    │                          │    Repay shares, otherwise revert     │         │
    ///    │                          │──────────────────────────────────────>│         │
    ///    │                          │                 │                     │         │
    ///    │    Send the minted YT    │                 │                     │         │
    ///    │<─────────────────────────│                 │                     │         │
    ///    │                          │                 │                     │         │
    ///    │Send the remaining sharses│                 │                     │         │
    ///    │<─────────────────────────│                 │                     │         │
    ///  ┌─┴──┐                     ┌─┴─┐           ┌───┴─────┐             ┌───┴───┐┌────┴────┐
    ///  │User│                     │Zap│           │Connector│             │PrincipalToken││TwoCrypto│
    ///  └────┘                     └───┘           └─────────┘             └───────┘└─────────┘
    function swapTokenForYt(SwapTokenParams calldata params, ApproxValue sharesFlashBorrow)
        external
        payable
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 principal)
    {
        TwoCrypto twoCrypto = params.twoCrypto;
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));
        address underlying = twoCrypto.coins(TARGET_INDEX);

        uint256 sharesFromUser = _deposit(
            underlying, principalToken.i_asset().asAddr(), params.tokenIn, params.amountIn, address(this), msg.sender
        );

        setHookContext();
        bytes memory data = ZapHookEncoder.encodeSupply(twoCrypto, underlying, msg.sender, sharesFromUser);
        principal = principalToken.supply(sharesFlashBorrow.unwrap(), address(this), data);

        // Send the minted YT to `receiver`
        if (principal < params.minPrincipal) Errors.Zap_InsufficientYieldTokenOutput.selector.revertWith();
        address yt = principalToken.i_yt().asAddr();
        SafeTransferLib.safeTransfer(yt, params.receiver, principal);

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            tokenOut: Token.wrap(yt),
            amountOut: principal
        });
    }

    /// @notice Swap any token to another token through an aggregator and then swap the token to YT
    /// @notice `tokenMintShares` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice When `token` is not native ETH, the caller must approve this contract to spend `amountIn` of `token`.
    /// @dev Flow: token -> [aggregator] -> tokenMintShares -> [connector] -> shares -> [twoCrypto] -> YT OR token -> [aggregator] -> shares(=tokenMintShares) -> [twoCrypto] -> YT
    /// @dev e.g. wstETH-YT (1) USDC -> [aggregator] -> WETH -> [connector]-> wstETH -> YT (2) USDC -> [aggregator] -> wstETH -> YT (3) USDC -> [aggregator] -> stETH -> [connector] -> wsETH -> YT
    function swapAnyTokenForYt(
        SwapTokenParams calldata params,
        ApproxValue sharesFlashBorrow,
        SwapTokenInput calldata tokenInput
    )
        external
        payable
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 principal)
    {
        TwoCrypto twoCrypto = params.twoCrypto;
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(PT_INDEX));
        address underlying = twoCrypto.coins(TARGET_INDEX);

        _pullToken(params.tokenIn, params.amountIn);

        approveIfNeeded(params.tokenIn, address(i_aggregationRouter));

        {
            // Step 1: Swap input token to tokenMintShares using the aggregator
            uint256 tokenMintSharesAmount = i_aggregationRouter.swap{value: msg.value}({
                tokenIn: params.tokenIn,
                tokenOut: tokenInput.tokenMintShares,
                amountIn: params.amountIn,
                data: tokenInput.swapData,
                receiver: address(this)
            });

            // Step 2: Deposit tokenMintShares and get shares
            uint256 shares = _deposit(
                underlying,
                principalToken.i_asset().asAddr(),
                tokenInput.tokenMintShares,
                tokenMintSharesAmount,
                address(this),
                address(this)
            );

            // Step 4: Mint YT using the PT
            setHookContext();
            bytes memory data = ZapHookEncoder.encodeSupply(twoCrypto, underlying, msg.sender, shares);
            principal = principalToken.supply(sharesFlashBorrow.unwrap(), address(this), data);

            if (principal < params.minPrincipal) Errors.Zap_InsufficientYieldTokenOutput.selector.revertWith();
        }

        // Transfer YT to the receiver
        address yt = principalToken.i_yt().asAddr();
        SafeTransferLib.safeTransfer(yt, params.receiver, principal);

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: twoCrypto,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            tokenOut: Token.wrap(yt),
            amountOut: principal
        });

        _refund(params.tokenIn);
    }

    function onSupply(uint256 sharesFlashBorrowed, uint256 principal, bytes calldata data) external {
        verifyAndClearHookContext();

        // Decode callback data
        (TwoCrypto twoCrypto, address underlying, address by, uint256 sharesFromUser) =
            ZapHookEncoder.decodeSupply(data);

        SafeTransferLib.safeTransfer(msg.sender, twoCrypto.unwrap(), principal);
        uint256 sharesDy = twoCrypto.exchange_received({i: PT_INDEX, j: TARGET_INDEX, dx: principal, minDy: 0});
        if (sharesFlashBorrowed > sharesDy + sharesFromUser) {
            Errors.Zap_DebtExceedsUnderlyingReceived.selector.revertWith();
        }

        // Repay the debt (shares) to the `principalToken`
        SafeTransferLib.safeTransfer(underlying, msg.sender, sharesFlashBorrowed);
        // Send the remaining shares to `by` (the user who initiated the swap)
        SafeTransferLib.safeTransfer(underlying, by, sharesDy + sharesFromUser - sharesFlashBorrowed);
    }

    /// @notice Swap approx `principal` of YT to at least `minAmount` of `token` and send the `token` to `receiver`
    /// @dev This function can't swap exact `principal` of YT, instead it swaps at most `principal` of YT because of the slippage related to the off-chain approximation value.
    /// @notice `token` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice Caller must approve this contract to spend `principal` of YT.
    /// @param getDxResult Off-chain approximation result of `get_dx` result for the given `principal` of YT.
    /// @dev Flow: YT -> [twoCrypto] -> shares -> [connector] -> token
    /// @dev e.g. wstETH-YT (1) YT -> wstETH (2) YT -> wstETH -> [connector] -> stETH
    /// @dev e.g. rETH-YT (1) YT -> rETH (2) YT -> rETH -> [connector] -> WETH (3) YT -> rETH -> [connector] -> native ETH
    ///  ┌────┐  ┌───┐                                    ┌─────────┐┌───────┐┌─────────┐
    ///  │User│  │Zap│                                    │TwoCrypto││PrincipalToken││Connector│
    ///  └─┬──┘  └─┬─┘                                    └────┬────┘└───┬───┘└───┬─────┘
    ///    │       │                                           │         │        │
    ///    │Send YT│                                           │         │        │
    ///    │──────>│                                           │         │        │
    ///    │       │                                           │         │        │
    ///    │       │Estimate swap result with get_dx and get_dy│         │        │
    ///    │       │──────────────────────────────────────────>│         │        │
    ///    │       │                                           │         │        │
    ///    │       │        Flash redeeem with callback (onUnite)        │        │
    ///    │       │────────────────────────────────────────────────────>│        │
    ///    │       │                                           │         │        │
    ///    │       │                      Callback             │         │        │
    ///    │       │<────────────────────────────────────────────────────│        │
    ///    │       │                                           │         │        │
    ///    │       │          Swap the shares for PT           │         │        │
    ///    │       │──────────────────────────────────────────>│         │        │
    ///    │       │                                           │         │        │
    ///    │       │          Burn the PT, otherwise revert    │         │        │
    ///    │       │────────────────────────────────────────────────────>│        │
    ///    │       │                                           │         │        │
    ///    │       │              Convert remaining shares to token      │        │
    ///    │       │─────────────────────────────────────────────────────────────>│
    ///    │       │                                           │         │        │
    ///    │       │                Sends remaining token      │         │        │
    ///    │<─────────────────────────────────────────────────────────────────────│
    ///  ┌─┴──┐  ┌─┴─┐                                    ┌────┴────┐┌───┴───┐┌───┴─────┐
    ///  │User│  │Zap│                                    │TwoCrypto││PrincipalToken││Connector│
    ///  └────┘  └───┘                                    └─────────┘└───────┘└─────────┘
    function swapYtForToken(SwapYtParams calldata params, ApproxValue getDxResult)
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        PrincipalToken principalToken = PrincipalToken(params.twoCrypto.coins(PT_INDEX));
        address yt = principalToken.i_yt().asAddr();
        (uint256 principalSpent, uint256 shares) =
            _swapYtForUnderlying(params.twoCrypto, principalToken, yt, params.principal, getDxResult);

        address underlying = params.twoCrypto.coins(TARGET_INDEX);

        amountOut = _redeem(
            underlying,
            principalToken.i_asset().asAddr(),
            params.tokenOut,
            shares - getDxResult.unwrap(),
            params.receiver
        );

        if (amountOut < params.amountOutMin) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: params.twoCrypto,
            tokenIn: Token.wrap(yt),
            amountIn: principalSpent,
            tokenOut: params.tokenOut,
            amountOut: amountOut
        });
    }

    /// @notice Swap any token to another token through an aggregator and then swap the token to YT
    /// @notice `tokenMintShares` must be supported by the connector. Otherwise, the swap will fail.
    /// @notice When `token` is not native ETH, the caller must approve this contract to spend `amountIn` of `token`.
    /// @dev Flow: token -> [aggregator] -> tokenMintShares -> [connector] -> shares -> [twoCrypto] -> YT OR token -> [aggregator] -> shares(=tokenMintShares) -> [twoCrypto] -> YT
    /// @dev e.g. wstETH-YT (1) USDC -> [aggregator] -> WETH -> [connector]-> wstETH -> YT (2) USDC -> [aggregator] -> wstETH -> YT (3) USDC -> [aggregator] -> stETH -> [connector] -> wsETH -> YT
    function swapYtForAnyToken(
        SwapYtParams calldata params,
        ApproxValue getDxResult,
        SwapTokenOutput calldata tokenOutput
    )
        external
        nonReentrant
        checkTwoCrypto(params.twoCrypto)
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        PrincipalToken principalToken = PrincipalToken(params.twoCrypto.coins(PT_INDEX));
        address yt = principalToken.i_yt().asAddr();

        uint256 principalSpent;
        uint256 tokenRedeemSharesAmount;
        // Stack-too-deep error workaround
        {
            uint256 shares;
            (principalSpent, shares) =
                _swapYtForUnderlying(params.twoCrypto, principalToken, yt, params.principal, getDxResult);
            // Swap the excess shares for the desired token
            tokenRedeemSharesAmount = _redeem(
                principalToken.underlying(),
                principalToken.i_asset().asAddr(),
                tokenOutput.tokenRedeemShares,
                shares - getDxResult.unwrap(),
                address(this)
            );
        }

        // Approve the aggregator to spend the tokenRedeemShares
        approveIfNeeded(tokenOutput.tokenRedeemShares, address(i_aggregationRouter));

        // Swap tokenRedeemShares for the desired token using the aggregator
        // Note: It will fail with aggregator error when the returned amount of `tokenRedeemShares` from the above is less than the the input of aggregator, due to the slippage.
        amountOut = i_aggregationRouter.swap{
            value: FixedPointMathLib.ternary(tokenOutput.tokenRedeemShares.isNative(), tokenRedeemSharesAmount, 0)
        }({
            tokenIn: tokenOutput.tokenRedeemShares,
            tokenOut: params.tokenOut,
            amountIn: tokenRedeemSharesAmount,
            data: tokenOutput.swapData,
            receiver: params.receiver
        });

        if (amountOut < params.amountOutMin) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapSwap({
            by: msg.sender,
            receiver: params.receiver,
            twoCrypto: params.twoCrypto,
            tokenIn: Token.wrap(yt),
            amountIn: principalSpent,
            tokenOut: params.tokenOut,
            amountOut: amountOut
        });

        // Note that the remaining `tokenRedeemShares` are left in the contract because the result of swap on the twoCrypto may be different from the estimation
        _refund(tokenOutput.tokenRedeemShares);
    }

    /// @dev Params (TwoCrypto, principalToken, yt) must match each other.
    function _swapYtForUnderlying(
        TwoCrypto twoCrypto,
        PrincipalToken principalToken,
        address yt,
        uint256 principal,
        ApproxValue sharesDx // Off-chain estimation `get_dx` result
    ) internal returns (uint256 principalSpent, uint256 shares) {
        // If `sharesDx` is not fresh enough or market changes dramatically, it may try to pull more YT than the input.
        principalSpent = twoCrypto.get_dy(TARGET_INDEX, PT_INDEX, sharesDx.unwrap());
        if (principalSpent > principal) Errors.Zap_PullYieldTokenGreaterThanInput.selector.revertWith();

        // Before calling `PrincipalToken.combine`, we need to transfer the principal because YT transfer triggers
        // reentrancy-guarded `PrincipalToken.onYtTransfer` function
        SafeTransferLib.safeTransferFrom(yt, msg.sender, address(this), principalSpent);

        // Economically speaking, in theory the shares we're going to get by combining is always greater than `sharesDx`
        // because PT should be discounted and 1 PT + 1 YT = 1 underlying (except fee).
        // Here, don't care that the `PrincipalToken.combine` will send the enough shares in return of the principal.
        setHookContext();
        shares = principalToken.combine(
            principalSpent,
            address(this),
            ZapHookEncoder.encodeUnite(twoCrypto, twoCrypto.coins(TARGET_INDEX), sharesDx)
        );
    }

    function onUnite(uint256 shares, uint256, /* principal */ bytes calldata data) external {
        verifyAndClearHookContext();

        // Note: If `sharesDx` is not fresh enough or market changes dramatically, it may revert.
        (TwoCrypto twoCrypto, address underlying, uint256 sharesDx) = ZapHookEncoder.decodeUnite(data);
        if (shares < sharesDx) Errors.Zap_InsufficientUnderlyingOutput.selector.revertWith();

        SafeTransferLib.safeTransfer(underlying, twoCrypto.unwrap(), sharesDx);
        twoCrypto.exchange_received({i: TARGET_INDEX, j: PT_INDEX, dx: sharesDx, minDy: 0});
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            PrincipalToken issuance & redemption            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Caller must approve this contract spending `token` before calling this function if `token` is not native token
    /// @notice Supply `amountIn` of `token` to `principalToken` and issue at least `minPrincipal` of PT to `receiver`
    /// @dev Flow: token -> [connector] -> shares -> [principalToken] -> PT
    /// @dev e.g. wstETH-PT (1) native ETH -> [connector] -> wstETH -> [principalToken] -> PT (2) stETH -> [connector] -> wsETH -> [principalToken] -> PT
    function supply(
        PrincipalToken principalToken,
        Token tokenIn,
        uint256 amountIn,
        address receiver,
        uint256 minPrincipal
    ) external payable nonReentrant checkPrincipalToken(principalToken) returns (uint256 principal) {
        principal = _supply({
            principalToken: principalToken,
            tokenIn: tokenIn,
            amountIn: amountIn,
            from: msg.sender,
            receiver: receiver,
            minPrincipal: minPrincipal
        });

        Events.emitZapSupply({
            by: msg.sender,
            receiver: receiver,
            pt: address(principalToken),
            principal: principal,
            tokenIn: tokenIn,
            amountIn: amountIn
        });
    }

    /// @notice Caller must approve this contract spending `tokenIn` before calling this function if `tokenIn` is not native token.
    /// @notice Supply `amountIn` of `tokenIn` to `principalToken` and issue at least `minPrincipal` of PT to `receiver`
    /// @dev Flow: (1) token -> [aggregator] -> tokenMintShares -> [connector] -> shares -> [principalToken] -> PT (2) token -> [aggregator] -> shares(=tokenMintShares) -> [principalToken] -> PT
    /// @dev e.g. wstETH-PT (1) USDC -> [aggregator] -> WETH -> [connector]-> wstETH -> [principalToken] -> PT (2) USDC -> [aggregator] -> wstETH -> [principalToken] -> PT (3) USDC -> [aggregator] -> stETH -> [connector] -> wstETH -> [principalToken] -> PT
    function supplyAnyToken(
        PrincipalToken principalToken,
        Token tokenIn,
        uint256 amountIn,
        address receiver,
        uint256 minPrincipal,
        SwapTokenInput calldata tokenInput
    ) external payable nonReentrant checkPrincipalToken(principalToken) returns (uint256 principal) {
        _pullToken(tokenIn, amountIn);

        approveIfNeeded(tokenIn, address(i_aggregationRouter));
        uint256 tokenMintSharesAmount = i_aggregationRouter.swap{value: msg.value}({
            tokenIn: tokenIn,
            tokenOut: tokenInput.tokenMintShares,
            amountIn: amountIn,
            data: tokenInput.swapData,
            receiver: address(this)
        });

        principal = _supply({
            principalToken: principalToken,
            tokenIn: tokenInput.tokenMintShares,
            amountIn: tokenMintSharesAmount,
            from: address(this),
            receiver: receiver,
            minPrincipal: minPrincipal
        });

        Events.emitZapSupply({
            by: msg.sender,
            receiver: receiver,
            pt: address(principalToken),
            principal: principal,
            tokenIn: tokenIn,
            amountIn: amountIn
        });

        _refund(tokenIn);
    }

    /// @dev The function doesn't validate the `principalToken`.
    /// @dev `from` must be `msg.sender` or this contract basically. Otherwise, allowance can be exploited.
    function _supply(
        PrincipalToken principalToken,
        Token tokenIn,
        uint256 amountIn,
        address from,
        address receiver,
        uint256 minPrincipal
    ) internal returns (uint256 principal) {
        address underlying = principalToken.underlying();
        uint256 shares = _deposit(underlying, principalToken.i_asset().asAddr(), tokenIn, amountIn, address(this), from);
        approveIfNeeded(underlying, address(principalToken));
        principal = principalToken.supply(shares, receiver);

        if (principal < minPrincipal) Errors.Zap_InsufficientPrincipalOutput.selector.revertWith();
    }

    /// @notice Deposit `amount` of `token` from `from` and mint `shares` of `underlying` to `receiver`
    /// @dev Vulnerable to double-spending ETH
    /// DO NOT USE THIS FUNCTION IN LOOP OR INSIDE RECURSIVE CALLS LIKE multicall.
    function _deposit(address underlying, address asset, Token token, uint256 amount, address receiver, address from)
        internal
        returns (uint256 shares)
    {
        if (token.eq(underlying)) {
            shares = amount;
            if (from == address(this)) {
                // Skip the transfer if `from` and `receiver` are the this contract
                if (receiver != address(this)) SafeTransferLib.safeTransfer(token.unwrap(), receiver, amount);
            } else {
                SafeTransferLib.safeTransferFrom(token.unwrap(), from, receiver, amount);
            }
        } else {
            // Convert token to shares via connector
            VaultConnector connector = i_vaultConnectorRegistry.getConnector(underlying, asset);
            shares = _depositToVault(connector, token, amount, receiver, from);
        }
    }

    /// @notice Deposit `amountIn` of `token` from `from` to `vaultConnector` and mint `shares` to `receiver`
    /// @dev Vulnerable to double-spending ETH
    /// DO NOT USE THIS FUNCTION IN LOOP OR INSIDE RECURSIVE CALLS LIKE multicall.
    function _depositToVault(
        VaultConnector vaultConnector,
        Token token,
        uint256 amountIn,
        address receiver,
        address from
    ) internal returns (uint256 shares) {
        uint256 value;
        if (token.isNative()) {
            if (address(this).balance < amountIn) Errors.Zap_InsufficientETH.selector.revertWith();
            value = amountIn; // native ETH -> connector -> wstETH
        } else {
            if (from != address(this)) {
                SafeTransferLib.safeTransferFrom(token.unwrap(), from, address(this), amountIn);
            }
            approveIfNeeded(token, address(vaultConnector)); // token (e.g.stETH) -> connector -> wstETH
        }
        shares = vaultConnector.deposit{value: value}(token, amountIn, receiver);
    }

    struct CollectInput {
        address principalToken;
        PermitCollectInput permit;
    }

    struct PermitCollectInput {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Caller collects interest and rewards in a single transaction
    /// @param inputs Array of CollectInput - If the `deadline` in input is zero, we skip the permit call and directly collect interest and rewards.
    function collectWithPermit(CollectInput[] calldata inputs, address receiver) external nonReentrant {
        uint256 length = inputs.length;
        for (uint256 i = 0; i != length;) {
            CollectInput calldata input = inputs[i];
            ContractValidation.checkPrincipalToken(i_factory, input.principalToken);

            _permitCollector(input);
            PrincipalToken(input.principalToken).collect(receiver, msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice This function is used to claim rewards manually when the `principalToken`'s rewardProxy is not available or not working properly.
    /// @param inputs Array of CollectInput - If the `deadline` in input is zero, we skip the permit call and directly collect interest and rewards.
    /// @param rewardTokens Array of array of rewards to claim - Each inner array contains the reward tokens to be collected from the corresponding `principalToken`.
    function collectRewardsWithPermit(
        CollectInput[] calldata inputs,
        address[][] calldata rewardTokens,
        address receiver
    ) external nonReentrant {
        uint256 length = inputs.length;
        if (length != rewardTokens.length) Errors.Zap_LengthMismatch.selector.revertWith();
        for (uint256 i = 0; i != length;) {
            CollectInput calldata input = inputs[i];
            ContractValidation.checkPrincipalToken(i_factory, input.principalToken);

            _permitCollector(input);
            PrincipalToken(input.principalToken).collectRewards(rewardTokens[i], receiver, msg.sender);
            unchecked {
                ++i;
            }
        }
    }

    /// @dev deadline == 0 means `permitCollector` is skipped.
    function _permitCollector(CollectInput calldata input) internal {
        if (input.permit.deadline == 0) return;

        // Permit signature might be consumed by fruntrun.
        // https://www.trust-security.xyz/post/permission-denied
        try PrincipalToken(input.principalToken).permitCollector(
            msg.sender, address(this), input.permit.deadline, input.permit.v, input.permit.r, input.permit.s
        ) {} catch {
            // Permit potentially got fruntrun. If the Zap is not approved, collect() will revert.
        }
    }

    /// @notice Caller must approve this contract spending `principalToken` before calling this function
    /// @notice Combine `principal` amount of PT and YT to get back underlying shares
    /// @param principalToken The PrincipalToken contract
    /// @param tokenOut The token to receive
    /// @param principal The amount of PT (and YT) to combine
    /// @param receiver The address to receive the output token
    /// @param minAmount The minimum amount of output token to receive
    /// @return amountOut The amount of output token received
    function combine(
        PrincipalToken principalToken,
        Token tokenOut,
        uint256 principal,
        address receiver,
        uint256 minAmount
    ) external nonReentrant checkPrincipalToken(principalToken) returns (uint256 amountOut) {
        amountOut =
            _combine({principalToken: principalToken, token: tokenOut, principal: principal, receiver: receiver});
        if (amountOut < minAmount) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapUnite({
            by: msg.sender,
            receiver: receiver,
            pt: address(principalToken),
            principal: principal,
            tokenOut: tokenOut,
            amountOut: amountOut
        });
    }

    /// @notice Combine PT and YT to get shares and swap those shares to any token through an aggregator
    /// @notice Caller must approve this contract to spend both PT and YT before calling
    /// @param principalToken The PrincipalToken contract
    /// @param principal The amount of PT (and YT) to combine
    /// @param tokenOut The token to receive
    /// @param receiver The address to receive the output token
    /// @param minAmount Minimum amount of output token to receive
    /// @param tokenOutput Data for swapping shares to desired token
    /// @return amountOut The amount of output token received
    function combineToAnyToken(
        PrincipalToken principalToken,
        Token tokenOut,
        uint256 principal,
        address receiver,
        uint256 minAmount,
        SwapTokenOutput calldata tokenOutput
    ) external nonReentrant checkPrincipalToken(principalToken) returns (uint256 amountOut) {
        // Combine PT and YT for intermediate token
        uint256 tokenRedeemSharesAmount = _combine({
            principalToken: principalToken,
            token: tokenOutput.tokenRedeemShares,
            principal: principal,
            receiver: address(this)
        });

        // Approve aggregator to spend intermediate token if needed
        approveIfNeeded(tokenOutput.tokenRedeemShares, address(i_aggregationRouter));

        // Calculate ETH value to send with swap if intermediate token is native ETH
        uint256 valueToSend =
            FixedPointMathLib.ternary(tokenOutput.tokenRedeemShares.isNative(), tokenRedeemSharesAmount, 0);

        // Swap intermediate token for desired output token
        amountOut = i_aggregationRouter.swap{value: valueToSend}({
            tokenIn: tokenOutput.tokenRedeemShares,
            tokenOut: tokenOut,
            amountIn: tokenRedeemSharesAmount,
            data: tokenOutput.swapData,
            receiver: receiver
        });

        if (amountOut < minAmount) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapUnite({
            by: msg.sender,
            receiver: receiver,
            pt: address(principalToken),
            principal: principal,
            tokenOut: tokenOut,
            amountOut: amountOut
        });

        // Refund any remaining intermediate tokens
        _refund(tokenOutput.tokenRedeemShares);
    }

    /// @dev Top-level internal function to combine PT and YT to get underlying shares
    /// @dev The function doesn't validate the `principalToken`.
    function _combine(PrincipalToken principalToken, Token token, uint256 principal, address receiver)
        internal
        returns (uint256 amountOut)
    {
        SafeTransferLib.safeTransferFrom(address(principalToken), msg.sender, address(this), principal);
        SafeTransferLib.safeTransferFrom(principalToken.i_yt().asAddr(), msg.sender, address(this), principal);

        // Combine PT and YT to get underlying shares
        uint256 shares = principalToken.combine(principal, address(this));

        // Redeem shares for intermediate token
        amountOut = _redeem(principalToken.underlying(), principalToken.i_asset().asAddr(), token, shares, receiver);
    }

    /// @notice Caller must approve this contract spending `principal` of PT before calling this function
    /// @notice Redeem `principal` of PT from `principalToken` and send `minAmount` of `token` to `receiver`
    /// @dev Flow: PT -> [principalToken] -> shares -> [connector] -> token
    /// @dev e.g. wstETH-PT (1) PT -> wstETH -> [connector] -> stETH (2) PT -> wstETH
    function redeem(
        PrincipalToken principalToken,
        Token tokenOut,
        uint256 principal,
        address receiver,
        uint256 minAmount
    ) external nonReentrant checkPrincipalToken(principalToken) returns (uint256 amountOut) {
        address underlying = principalToken.underlying();

        uint256 shares = principalToken.redeem(principal, address(this), msg.sender);
        amountOut = _redeem(underlying, principalToken.i_asset().asAddr(), tokenOut, shares, receiver);

        if (amountOut < minAmount) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapRedeem({
            by: msg.sender,
            receiver: receiver,
            pt: address(principalToken),
            principal: principal,
            tokenOut: tokenOut,
            amountOut: amountOut
        });
    }

    function redeemToAnyToken(
        PrincipalToken principalToken,
        Token tokenOut,
        uint256 principal,
        address receiver,
        uint256 minAmount,
        SwapTokenOutput calldata tokenOutput
    ) external nonReentrant checkPrincipalToken(principalToken) returns (uint256 amountOut) {
        address underlying = principalToken.underlying();
        uint256 shares = principalToken.redeem(principal, address(this), msg.sender);

        uint256 tokenRedeemSharesAmount =
            _redeem(underlying, principalToken.i_asset().asAddr(), tokenOutput.tokenRedeemShares, shares, address(this));

        approveIfNeeded(tokenOutput.tokenRedeemShares, address(i_aggregationRouter));

        uint256 valueToSend =
            FixedPointMathLib.ternary(tokenOutput.tokenRedeemShares.isNative(), tokenRedeemSharesAmount, 0);

        amountOut = i_aggregationRouter.swap{value: valueToSend}({
            tokenIn: tokenOutput.tokenRedeemShares,
            tokenOut: tokenOut,
            amountIn: tokenRedeemSharesAmount,
            data: tokenOutput.swapData,
            receiver: receiver
        });

        if (amountOut < minAmount) Errors.Zap_InsufficientTokenOutput.selector.revertWith();

        Events.emitZapRedeem({
            by: msg.sender,
            receiver: receiver,
            pt: address(principalToken),
            principal: principal,
            tokenOut: tokenOut,
            amountOut: amountOut
        });

        _refund(tokenOutput.tokenRedeemShares);
    }

    function _redeemFromVault(address underlying, address asset, Token token, uint256 shares, address receiver)
        internal
        returns (uint256 amountOut)
    {
        VaultConnector vaultConnector = i_vaultConnectorRegistry.getConnector(underlying, asset);
        approveIfNeeded(underlying, address(vaultConnector));
        amountOut = vaultConnector.redeem(token, shares, receiver);
    }

    function _redeem(address underlying, address asset, Token tokenOut, uint256 shares, address receiver)
        internal
        returns (uint256 amountOut)
    {
        if (tokenOut.eq(underlying)) {
            amountOut = shares;
            if (receiver != address(this)) SafeTransferLib.safeTransfer(underlying, receiver, amountOut);
        } else {
            amountOut = _redeemFromVault(underlying, asset, tokenOut, shares, receiver);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     Transfer Helper                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The function should be used in top-level calls only.
    function _pullToken(Token token, uint256 amount) internal {
        if (token.isNative()) {
            if (msg.value != amount) Errors.Zap_InconsistentETHReceived.selector.revertWith();
        } else {
            if (msg.value != 0) Errors.Zap_InconsistentETHReceived.selector.revertWith();
            SafeTransferLib.safeTransferFrom(token.unwrap(), msg.sender, address(this), amount);
        }
    }

    function approveIfNeeded(Token token, address spender) internal {
        if (!token.isNative()) {
            approveIfNeeded(token.unwrap(), spender);
        }
    }

    function _refund(Token token) internal {
        if (token.isNative()) {
            SafeTransferLib.safeTransferAllETH(msg.sender);
        } else {
            SafeTransferLib.safeTransferAll(token.unwrap(), msg.sender);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     　　　Validation                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier checkTwoCrypto(TwoCrypto twoCrypto) {
        ContractValidation.checkTwoCrypto(i_factory, twoCrypto.unwrap(), i_twoCryptoDeployer);
        _;
    }

    modifier checkPrincipalToken(PrincipalToken principalToken) {
        ContractValidation.checkPrincipalToken(i_factory, address(principalToken));
        _;
    }
}
