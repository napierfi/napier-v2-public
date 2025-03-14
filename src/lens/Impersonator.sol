// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {LibCall} from "solady/src/utils/LibCall.sol";

import {Factory} from "../Factory.sol";
import {VaultInfoResolver} from "../modules/resolvers/VaultInfoResolver.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "../zap/TwoCryptoZap.sol";
import {RouterPayload} from "../modules/aggregator/AggregationRouter.sol";
import {Quoter} from "./Quoter.sol";

import {LibTwoCryptoNG} from "../utils/LibTwoCryptoNG.sol";
import {LibBlueprint} from "../utils/LibBlueprint.sol";
import {ConversionLib} from "./ConversionLib.sol";
import {RouterPayload} from "../modules/aggregator/AggregationRouter.sol";

import "../Types.sol";
import "../Constants.sol";

/// @notice Impersonate a user to simulate a interaction with a contract.
/// @dev This contract is not meant to ever actually be deployed, only mock deployed and used via a static `eth_call` and `stateOverride` option.
contract Impersonator {
    using LibTwoCryptoNG for TwoCrypto;

    error Impersonator_FunctionNotFound();
    error Impersonator_ApproveTokenFailed();
    error Impersonator_InsufficientNativeTokenBalance();
    error Impersonator_ErrorMarginExceeds10000Bps();
    error Impersonator_InvalidResolverBlueprint();
    error Impersonator_ExpiryIsInThePast();
    error Impersonator_InvalidResolverConfig();
    error Impersonator_IntermediateAmountTooLow();

    uint256 constant DEFAULT_SLIPPAGE_BPS = 10; // 0.1%

    /// @notice User should be able to receive native tokens.
    receive() external payable {}

    /// @dev Explicit error message when the function is not found.
    fallback() external {
        revert Impersonator_FunctionNotFound();
    }

    /// @notice Simulate a Zap contract function call.
    /// @param zap - Target contract that the user interact with
    /// @param tokenIns - List of tokens that the user spends. The user's tokens spend by Zap must be included in this list.
    /// @param value - The amount of native token that the user sends to the Zap contract.
    /// @param simPayload - The Zap contract function call to be simulated. The params must be abi-encoded, starting with a function selector.
    function query(address zap, Token[] memory tokenIns, uint256 value, bytes memory simPayload)
        public
        payable
        returns (bytes memory)
    {
        for (uint256 i = 0; i != tokenIns.length; i++) {
            try this.extApprove(tokenIns[i], zap) {}
            catch {
                revert Impersonator_ApproveTokenFailed();
            }
        }
        if (address(this).balance < value) {
            revert Impersonator_InsufficientNativeTokenBalance();
        }

        (bool success, bytes memory ret) = zap.call{value: value}(simPayload);
        if (!success) LibCall.bubbleUpRevert(ret);
        return ret;
    }

    function query(address zap, Token tokenIn, uint256 value, bytes memory simPayload)
        public
        payable
        returns (bytes memory ret)
    {
        Token[] memory tokenIns = new Token[](1);
        tokenIns[0] = tokenIn;
        return query(zap, tokenIns, value, simPayload);
    }

    /// @dev Calculate the initial price of the principal token in shares based on the implied APY and current share price of the underlying token.
    function queryInitialPrice(
        address zap,
        uint256 expiry, // In seconds
        int256 impliedAPY, // 1e18 == 100%
        address resolverBlueprint,
        bytes calldata resolverArg
    ) external returns (uint256 initialPtPrice) {
        if (!TwoCryptoZap(payable(zap)).i_factory().s_resolverBlueprints(resolverBlueprint)) {
            revert Impersonator_InvalidResolverBlueprint();
        }
        if (expiry <= block.timestamp) revert Impersonator_ExpiryIsInThePast();

        address resolver = LibBlueprint.tryCreate(resolverBlueprint, resolverArg);
        if (resolver == address(0)) revert Impersonator_InvalidResolverConfig();

        uint256 scale;
        try VaultInfoResolver(resolver).scale() returns (uint256 s) {
            // Dev: Solidity try-catch doesn't catch errors inside try block. So we must outsource remaining logic to outside of try block.
            scale = s;
        } catch {
            revert Impersonator_InvalidResolverConfig();
        }
        uint256 scaleUnit =
            10 ** (18 + VaultInfoResolver(resolver).assetDecimals() - VaultInfoResolver(resolver).decimals());
        // Unit conversions: scale is in (18 + assetDecimals - underlyingDecimals) units
        // e.g. vault: 6 decimals, underlying: 6 decimals, share price: 1.2
        // scale = 1.2e6 * 10**(18 - 6) = 1.2e6 * 1e12. It should be divided by 10**(18 + 6 - 6)
        // e.g. vault: 6 decimals, underlying: 18 decimals, share price: 1.2
        // scale = 1.2e6 * 10**(18 - 18) = 1.2e6. It should be divided by 10**(18 + 18 - 18)
        uint256 timeToExpiry = expiry - block.timestamp;
        initialPtPrice = ConversionLib.convertToPriceInAsset(impliedAPY, timeToExpiry) * scaleUnit / scale;
    }

    /// @dev WARNING: This function can't predict the addresses of instances.
    function queryCreateAndAddLiquidity(
        address zap,
        address quoter,
        Factory.Suite calldata suite,
        Factory.ModuleParam[] calldata modules,
        uint256 expiry,
        address curator,
        uint256 shares
    ) external returns (uint256 liquidity, uint256 principal) {
        QueryCreateAndAddLiquidityParams memory params = QueryCreateAndAddLiquidityParams({
            zap: zap,
            quoter: quoter,
            suite: suite,
            modules: modules,
            expiry: expiry,
            curator: curator,
            shares: shares
        });
        return _queryCreateAndAddLiquidity(params);
    }

    /// @dev Workaround to avoid stack-too-deep error.
    struct QueryCreateAndAddLiquidityParams {
        address zap;
        address quoter; // Not used just for consistency with other query functions
        Factory.Suite suite;
        Factory.ModuleParam[] modules;
        uint256 expiry;
        address curator;
        uint256 shares;
    }

    /// @dev NOTE: This function doesn't return `pt`, `yt` and `twoCrypto` because those addresses are different from the actual ones.
    function _queryCreateAndAddLiquidity(QueryCreateAndAddLiquidityParams memory params)
        internal
        returns (uint256 liquidity, uint256 principal)
    {
        // Factory depends on `msg.sender` to determine the salt. We can't correctly derive addresses of instances
        ( /* pt */ , /* yt */, address twoCrypto) = TwoCryptoZap(payable(params.zap)).i_factory().deploy(
            params.suite, params.modules, params.expiry, params.curator
        );

        Token underlying = Token.wrap(TwoCrypto.wrap(twoCrypto).coins(TARGET_INDEX));
        // Note: We don't use `Quoter.previewAddLiquidityOneToken()` because it fails when total supply is zero.
        // Instead, we simulate the add liquidity with the same logic as `TwoCryptoZap.addLiquidityOneToken()`.
        TwoCryptoZap.AddLiquidityOneTokenParams memory p = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: TwoCrypto.wrap(twoCrypto),
            tokenIn: underlying,
            amountIn: params.shares,
            minLiquidity: 0,
            minYt: 0,
            receiver: address(this),
            deadline: block.timestamp
        });
        // Simulate the add liquidity
        bytes memory ret = query(params.zap, underlying, 0, abi.encodeCall(TwoCryptoZap.addLiquidityOneToken, (p)));

        (liquidity, principal) = abi.decode(ret, (uint256, uint256));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        QUERY SWAP PT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct QuerySwapPtForAnyTokenParams {
        address zap;
        Quoter quoter;
        TwoCrypto twoCrypto;
        uint256 principal;
        Token tokenOut;
        Token tokenRedeemShares;
        address router;
        bytes swapData;
    }

    function querySwapPtForToken(address zap, Quoter quoter, TwoCrypto twoCrypto, Token tokenOut, uint256 principal)
        public
        returns (
            uint256 amountOut,
            uint256 shares,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPriceWei
        )
    {
        (amountOut, shares, priceInAssetWei, impliedApyWei, executionPriceWei) = querySwapPtForAnyToken(
            QuerySwapPtForAnyTokenParams({
                zap: zap,
                quoter: quoter,
                twoCrypto: twoCrypto,
                principal: principal,
                tokenOut: tokenOut,
                tokenRedeemShares: Token.wrap(address(0)),
                router: address(0),
                swapData: bytes("")
            })
        );
    }

    /// @return amountOut - The amount of tokenOut the user receives.
    /// @return shares - The intermediate amount of shares the zap receives.
    /// @return priceInAssetWei - The execution price of the principal token in the asset in Wei. (e.g. 1 PT-wstETH = 0.9 ETH => 0.9e18). It can be greater than 1e18 if the PT is not discounted at all.
    /// @return impliedApyWei - The implied APY of the principal token in wei. (e.g. 1e18 = 100%, 5% => 0.05e18). Returns 0 if the PT is expired.
    /// @return executionPriceWei - The execution price of tokenOut against the PT in Wei. (e.g. 1 USDC = 0.9 PT-wstETH => 0.9e18).
    function querySwapPtForAnyToken(QuerySwapPtForAnyTokenParams memory params)
        public
        returns (
            uint256 amountOut,
            uint256 shares,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPriceWei
        )
    {
        (amountOut, shares) = _querySwapPtForAnyToken(params);

        priceInAssetWei = ConversionLib.calculateEffectivePtPrice(
            params.twoCrypto, params.principal, shares, ConversionLib.SwapKind.PT
        );
        impliedApyWei = _convertToImpliedAPY(params.twoCrypto.coins(PT_INDEX), priceInAssetWei);
        executionPriceWei = ConversionLib.calculateEffectivePrice(
            Token.wrap(params.twoCrypto.coins(PT_INDEX)), params.tokenOut, params.principal, amountOut
        );
    }

    function _querySwapPtForAnyToken(QuerySwapPtForAnyTokenParams memory params)
        internal
        returns (uint256 amountOut, uint256 shares)
    {
        uint256 sharesBefore = params.twoCrypto.balances(TARGET_INDEX);

        bool anyToken = params.router != address(0);

        // If the simulation uses the third-party router, skip quote.
        uint256 amountOutMin;
        if (!anyToken) {
            uint256 preview = params.quoter.previewSwapPtForToken(params.twoCrypto, params.tokenOut, params.principal);
            amountOutMin = preview * (BASIS_POINTS - DEFAULT_SLIPPAGE_BPS) / BASIS_POINTS;
        }

        TwoCryptoZap.SwapPtParams memory swapParams = TwoCryptoZap.SwapPtParams({
            twoCrypto: params.twoCrypto,
            tokenOut: params.tokenOut,
            principal: params.principal,
            receiver: address(this),
            // If not anyToken, intermediateToken is the tokenOut.
            amountOutMin: amountOutMin,
            deadline: block.timestamp
        });
        bytes memory simPayload;
        if (anyToken) {
            TwoCryptoZap.SwapTokenOutput memory tokenOutput = TwoCryptoZap.SwapTokenOutput({
                tokenRedeemShares: params.tokenRedeemShares,
                swapData: RouterPayload({router: params.router, payload: params.swapData})
            });
            simPayload = abi.encodeCall(TwoCryptoZap.swapPtForAnyToken, (swapParams, tokenOutput));
        } else {
            simPayload = abi.encodeCall(TwoCryptoZap.swapPtForToken, (swapParams));
        }

        Token pt = Token.wrap(params.twoCrypto.coins(PT_INDEX));
        bytes memory ret = query(params.zap, pt, 0, simPayload);

        amountOut = abi.decode(ret, (uint256));
        shares = sharesBefore - params.twoCrypto.balances(TARGET_INDEX);
    }

    struct QuerySwapAnyTokenForPtParams {
        address zap;
        Quoter quoter;
        TwoCrypto twoCrypto;
        Token tokenIn;
        uint256 amountIn;
        Token tokenMintShares;
        address router;
        bytes swapData;
    }

    function querySwapTokenForPt(address zap, Quoter quoter, TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
        public
        returns (
            uint256 principal,
            uint256 shares,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPriceWei
        )
    {
        (principal, shares, priceInAssetWei, impliedApyWei, executionPriceWei) = querySwapAnyTokenForPt(
            QuerySwapAnyTokenForPtParams({
                zap: zap,
                quoter: quoter,
                twoCrypto: twoCrypto,
                tokenIn: tokenIn,
                amountIn: amountIn,
                tokenMintShares: Token.wrap(address(0)),
                router: address(0),
                swapData: bytes("")
            })
        );
    }

    /// @return principal - The amount of principal tokens the user will receive
    /// @return shares - The amount of shares used in the swap
    /// @return priceInAssetWei - The price of PT in terms of the underlying asset in WAD (e.g. 1 PT-wstETH = 0.95 ETH => 0.95e18)
    /// @return impliedApyWei - The implied APY of the principal token in WAD (e.g. 5% => 0.05e18)
    /// @return executionPriceWei - The execution price of PT against tokenIn in WAD (e.g. 1 PT-wstETH = 0.8 USDC => 0.8e18)
    function querySwapAnyTokenForPt(QuerySwapAnyTokenForPtParams memory params)
        public
        returns (
            uint256 principal,
            uint256 shares,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPriceWei
        )
    {
        (principal, shares) = _querySwapAnyTokenForPt(params);
        priceInAssetWei =
            ConversionLib.calculateEffectivePtPrice(params.twoCrypto, principal, shares, ConversionLib.SwapKind.PT);
        impliedApyWei = _convertToImpliedAPY(params.twoCrypto.coins(PT_INDEX), priceInAssetWei);
        executionPriceWei = ConversionLib.calculateEffectivePrice(
            params.tokenIn, Token.wrap(params.twoCrypto.coins(PT_INDEX)), params.amountIn, principal
        );
    }

    function _querySwapAnyTokenForPt(QuerySwapAnyTokenForPtParams memory params)
        internal
        returns (uint256 principal, uint256 shares)
    {
        uint256 sharesBefore = params.twoCrypto.balances(TARGET_INDEX);

        bool anyToken = params.router != address(0);

        // If the simulation uses the third-party router, skip quote.
        uint256 minPrincipal;
        if (!anyToken) {
            uint256 preview = params.quoter.previewSwapTokenForPt(params.twoCrypto, params.tokenIn, params.amountIn);
            minPrincipal = preview * (BASIS_POINTS - DEFAULT_SLIPPAGE_BPS) / BASIS_POINTS;
        }

        TwoCryptoZap.SwapTokenParams memory swapParams = TwoCryptoZap.SwapTokenParams({
            twoCrypto: params.twoCrypto,
            tokenIn: params.tokenIn,
            amountIn: params.amountIn,
            receiver: address(this),
            minPrincipal: minPrincipal,
            deadline: block.timestamp
        });

        bytes memory simPayload;
        uint256 value = params.tokenIn.isNative() ? params.amountIn : 0;
        if (anyToken) {
            TwoCryptoZap.SwapTokenInput memory tokenInput = TwoCryptoZap.SwapTokenInput({
                tokenMintShares: params.tokenMintShares,
                swapData: RouterPayload({router: params.router, payload: params.swapData})
            });
            simPayload = abi.encodeCall(TwoCryptoZap.swapAnyTokenForPt, (swapParams, tokenInput));
        } else {
            simPayload = abi.encodeCall(TwoCryptoZap.swapTokenForPt, (swapParams));
        }
        // Simulate the swap
        bytes memory ret = query(params.zap, params.tokenIn, value, simPayload);
        principal = abi.decode(ret, (uint256));

        shares = params.twoCrypto.balances(TARGET_INDEX) - sharesBefore;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        QUERY SWAP YT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function querySwapTokenForYt(
        address zap,
        Quoter quoter,
        TwoCrypto twoCrypto,
        Token tokenIn,
        uint256 amountIn,
        uint256 errorMarginBps
    )
        public
        returns (
            uint256 principal,
            ApproxValue sharesFlashBorrowWithMargin,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPrice
        )
    {
        return querySwapAnyTokenForYt(
            QuerySwapAnyTokenForYtParams({
                zap: zap,
                quoter: quoter,
                twoCrypto: twoCrypto,
                tokenIn: tokenIn,
                amountIn: amountIn,
                errorMarginBps: errorMarginBps,
                tokenMintShares: Token.wrap(address(0)),
                tokenMintEstimate: 0,
                router: address(0),
                payload: bytes("")
            })
        );
    }

    /// @notice Parameters for querying a swap of any token for YT
    /// @param zap The address of the TwoCryptoZap contract
    /// @param quoter The Quoter contract used for price quotes
    /// @param twoCrypto The TwoCrypto pool contract
    /// @param tokenIn The input token to swap from
    /// @param amountIn The amount of input token to swap
    /// @param errorMarginBps The error margin in basis points (1 basis point = 0.01%).  It affects `sharesFlashBorrowWithMargin` and `principal` the user is going to receive.
    /// @param tokenMintShares The intermediate token that should be output from third-party router swaps
    /// @param tokenMintEstimate The expected amount of tokenMintShares to receive from third-party router
    /// @param router The address of the third-party router to use
    /// @param payload The calldata payload to send to the third-party router
    struct QuerySwapAnyTokenForYtParams {
        address zap;
        Quoter quoter;
        TwoCrypto twoCrypto;
        Token tokenIn;
        uint256 amountIn;
        uint256 errorMarginBps;
        // If anyToken endpoint is used, fill in the following fields.
        Token tokenMintShares;
        uint256 tokenMintEstimate;
        address router;
        bytes payload;
    }

    /// @return principal - The amount of principal the user is going to receive.
    /// @return sharesFlashBorrowWithMargin - The amount of shares the user is going to borrow with the error margin.
    /// @return priceInAssetWei - The execution price of the principal token against the asset in Wei. (e.g. 1 PT-wstETH = 0.9 ETH => 0.9e18). The price is in range [0, 1e18] if the the price can be negative, returns 0.
    /// @return impliedApyWei - The implied APY of the principal token in wei. (e.g. 1e18 = 100%, 5% => 0.05e18). Returns 0 if the PT is expired.
    /// @return executionPrice - The execution price of tokenIn against the YT in Wei. (e.g. 1 YT-wstETH = 0.01 USDC => 0.01e18).
    function querySwapAnyTokenForYt(QuerySwapAnyTokenForYtParams memory params)
        public
        returns (
            uint256 principal,
            ApproxValue sharesFlashBorrowWithMargin,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPrice
        )
    {
        uint256 sharesSpent;
        (principal, sharesFlashBorrowWithMargin, sharesSpent) = _querySwapAnyTokenForYt(params);

        address pt = params.twoCrypto.coins(PT_INDEX);
        priceInAssetWei =
            ConversionLib.calculateEffectivePtPrice(params.twoCrypto, principal, sharesSpent, ConversionLib.SwapKind.YT);
        impliedApyWei = _convertToImpliedAPY(pt, priceInAssetWei);
        executionPrice = ConversionLib.calculateEffectivePrice(
            params.tokenIn, Token.wrap(address(PrincipalToken(pt).i_yt())), params.amountIn, principal
        );
    }

    function _querySwapAnyTokenForYt(QuerySwapAnyTokenForYtParams memory params)
        internal
        returns (uint256 principal, ApproxValue sharesFlashBorrowWithMargin, uint256 sharesSpent)
    {
        if (params.errorMarginBps > BASIS_POINTS) revert Impersonator_ErrorMarginExceeds10000Bps();

        bytes memory simPayload;
        bool anyToken = params.router != address(0);
        {
            // Get preview for swapping intermediate token to YT

            // If aggregator API is used, the intermediate amount is `estimate.dstAmount`.
            // USDC -> [1inch] -> WETH -> [connector] -> wstETH -> [pool] -> YT
            Token intermediateToken = anyToken ? params.tokenMintShares : params.tokenIn;
            uint256 intermediateAmount = anyToken ? params.tokenMintEstimate : params.amountIn;

            uint256 quoterAmountIn = intermediateAmount * (BASIS_POINTS - params.errorMarginBps) / BASIS_POINTS;
            (, sharesFlashBorrowWithMargin, sharesSpent) =
                params.quoter.previewSwapTokenForYt(params.twoCrypto, intermediateToken, quoterAmountIn);

            TwoCryptoZap.SwapTokenParams memory swapParams = TwoCryptoZap.SwapTokenParams({
                twoCrypto: params.twoCrypto,
                tokenIn: params.tokenIn,
                amountIn: params.amountIn,
                receiver: address(this),
                minPrincipal: 0,
                deadline: block.timestamp
            });
            if (anyToken) {
                TwoCryptoZap.SwapTokenInput memory tokenInput = TwoCryptoZap.SwapTokenInput({
                    tokenMintShares: params.tokenMintShares,
                    swapData: RouterPayload({router: params.router, payload: params.payload})
                });
                simPayload = abi.encodeCall(
                    TwoCryptoZap.swapAnyTokenForYt, (swapParams, sharesFlashBorrowWithMargin, tokenInput)
                );
            } else {
                simPayload = abi.encodeCall(TwoCryptoZap.swapTokenForYt, (swapParams, sharesFlashBorrowWithMargin));
            }
        }
        uint256 value = params.tokenIn.isNative() ? params.amountIn : 0;

        // Simulate the swap
        bytes memory ret = query(params.zap, params.tokenIn, value, simPayload);

        principal = abi.decode(ret, (uint256));
    }

    function querySwapYtForToken(
        address zap,
        Quoter quoter,
        TwoCrypto twoCrypto,
        Token tokenOut,
        uint256 principal,
        uint256 errorMarginBps
    )
        public
        returns (
            uint256 amountOut,
            uint256 ytSpent,
            ApproxValue dxResultWithMargin,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPrice
        )
    {
        return querySwapYtForAnyToken(
            QuerySwapYtForAnyTokenParams({
                zap: zap,
                quoter: quoter,
                twoCrypto: twoCrypto,
                tokenOut: tokenOut,
                principal: principal,
                errorMarginBps: errorMarginBps,
                tokenRedeemShares: Token.wrap(address(0)),
                tokenRedeemEstimate: 0,
                router: address(0),
                payload: bytes("")
            })
        );
    }

    struct QuerySwapYtForAnyTokenParams {
        address zap;
        Quoter quoter;
        TwoCrypto twoCrypto;
        Token tokenOut;
        uint256 principal;
        uint256 errorMarginBps;
        // If anyToken endpoint is used, fill in the following fields.
        Token tokenRedeemShares;
        uint256 tokenRedeemEstimate;
        address router;
        bytes payload;
    }

    /// @return amountOut - The amount of tokenOut the user receives.
    /// @return ytSpent - The amount of YT the user actually spends.
    /// @return dxResultWithMargin - The approximate amount of `get_dx({i: TARGET, j: PT}, principal)` with the error margin.
    /// @return priceInAssetWei - The execution price of the PT in the asset in Wei. (e.g. 1 PT-wstETH = 0.9 ETH => 0.9e18).
    /// @return impliedApyWei - The implied APY of the principal token in wei. (e.g. 1e18 = 100%, 5% => 0.05e18). Returns 0 if the PT is expired. Returns `type(int256).max` if math error.
    /// @return executionPrice - The execution price of tokenOut against the YT in Wei. (e.g. 1 USDC = 100 YT-wstETH => 100e18).
    function querySwapYtForAnyToken(QuerySwapYtForAnyTokenParams memory params)
        public
        returns (
            uint256 amountOut,
            uint256 ytSpent,
            ApproxValue dxResultWithMargin,
            uint256 priceInAssetWei,
            int256 impliedApyWei,
            uint256 executionPrice
        )
    {
        uint256 sharesOut;
        (amountOut, ytSpent, dxResultWithMargin, sharesOut) = _querySwapYtForAnyToken(params);

        // See `TwoCryptoZap.swapYtForToken()` for the logic of shares change.
        // Calculate the execution price and implied APY
        // Note: `shares` will be slightly different from actual because of the error margin.
        address pt = params.twoCrypto.coins(PT_INDEX);
        priceInAssetWei =
            ConversionLib.calculateEffectivePtPrice(params.twoCrypto, ytSpent, sharesOut, ConversionLib.SwapKind.YT);
        impliedApyWei = _convertToImpliedAPY(pt, priceInAssetWei);
        executionPrice = ConversionLib.calculateEffectivePrice(
            Token.wrap(address(PrincipalToken(pt).i_yt())), params.tokenOut, ytSpent, amountOut
        );
    }

    function _querySwapYtForAnyToken(QuerySwapYtForAnyTokenParams memory params)
        internal
        returns (uint256 amountOut, uint256 ytSpent, ApproxValue dxResultWithMargin, uint256 sharesOut)
    {
        if (params.errorMarginBps > BASIS_POINTS) revert Impersonator_ErrorMarginExceeds10000Bps();

        uint256 ytBalanceBefore =
            SafeTransferLib.balanceOf(address(PrincipalToken(params.twoCrypto.coins(PT_INDEX)).i_yt()), address(this));

        bytes memory simPayload;
        // Get preview
        {
            // If the router is not zero address, `any token` function should be simulated
            // For example, YT -> [pool] -> wstETH -> [1inch] -> USDC
            bool anyToken = params.router != address(0);

            Token intermediateToken = anyToken ? params.tokenRedeemShares : params.tokenOut;
            (uint256 intermediateAmount, /* ApproxValue ytSpendPreview, */, ApproxValue getDxResult) =
                params.quoter.previewSwapYtForToken(params.twoCrypto, intermediateToken, params.principal);

            // The intermediate amount should be greater than the estimate. Otherwise, the swap will fail with insufficient balance on third-party router.
            // The thrid-pary API estimate may be old. Pass smaller estimate `srcAmount`, taking slippage into account.
            if (anyToken && params.tokenRedeemEstimate > intermediateAmount) {
                revert Impersonator_IntermediateAmountTooLow();
            }

            dxResultWithMargin =
                ApproxValue.wrap(getDxResult.unwrap() * (BASIS_POINTS - params.errorMarginBps) / BASIS_POINTS);

            simPayload = _encodeSwapYtForAnyTokenPayload(params, dxResultWithMargin);
        }

        address yt = address(PrincipalToken(params.twoCrypto.coins(PT_INDEX)).i_yt());

        // Simulate the swap
        bytes memory ret = query(params.zap, Token.wrap(yt), 0, simPayload);

        // Get the result
        amountOut = abi.decode(ret, (uint256));
        ytSpent = ytBalanceBefore - SafeTransferLib.balanceOf(yt, address(this));
        sharesOut =
            PrincipalToken(params.twoCrypto.coins(PT_INDEX)).previewCombine(ytSpent) - dxResultWithMargin.unwrap();
    }

    /// @dev Workaround for stack too deep error.
    function _encodeSwapYtForAnyTokenPayload(QuerySwapYtForAnyTokenParams memory params, ApproxValue dxResultWithMargin)
        internal
        view
        returns (bytes memory)
    {
        TwoCryptoZap.SwapYtParams memory swapParams = TwoCryptoZap.SwapYtParams({
            twoCrypto: params.twoCrypto,
            tokenOut: params.tokenOut,
            principal: params.principal,
            receiver: address(this),
            // We don't need to set this because we simulate swap with off-chain value `getDxResult` inclusive of some margin, so we will get slightly different result from the preview.
            // In some cases, the swap fails because of this reason. So we set this to 0.
            amountOutMin: 0,
            deadline: block.timestamp
        });

        if (params.router != address(0)) {
            TwoCryptoZap.SwapTokenOutput memory tokenOutput = TwoCryptoZap.SwapTokenOutput({
                tokenRedeemShares: params.tokenRedeemShares,
                swapData: RouterPayload({router: params.router, payload: params.payload})
            });
            return abi.encodeCall(TwoCryptoZap.swapYtForAnyToken, (swapParams, dxResultWithMargin, tokenOutput));
        } else {
            return abi.encodeCall(TwoCryptoZap.swapYtForToken, (swapParams, dxResultWithMargin));
        }
    }

    /// @dev Return `type(int256).max` if `ExpOverflow` or math error.
    function _convertToImpliedAPY(address pt, uint256 priceInAssetWei) internal view returns (int256) {
        try this.extConvertToImpliedAPY(pt, priceInAssetWei) returns (int256 impliedApyWei) {
            return impliedApyWei;
        } catch {
            return type(int256).max;
        }
    }

    /// @dev Workaround for try-catch.
    function extConvertToImpliedAPY(address pt, uint256 priceInAssetWei) external view returns (int256) {
        return ConversionLib.convertToImpliedAPY(pt, priceInAssetWei);
    }

    function extApprove(Token token, address spender) external {
        // For tokens like USDT, it requires to reset the approval to 0 before setting it to max.
        if (token.isNotNative()) SafeTransferLib.safeApproveWithRetry(token.unwrap(), spender, type(uint256).max);
    }
}
