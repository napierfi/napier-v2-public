// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

library Errors {
    error AccessManaged_Restricted();

    error Expired();
    error NotExpired();

    error PrincipalToken_NotFactory();
    error PrincipalToken_VerificationFailed(uint256 code);
    error PrincipalToken_CollectRewardFailed();
    error PrincipalToken_NotApprovedCollector();
    error PrincipalToken_OnlyYieldToken();
    error PrincipalToken_InsufficientSharesReceived();
    error PrincipalToken_UnderlyingTokenBalanceChanged();
    error PrincipalToken_Unstoppable();
    error PrincipalToken_ProtectedToken();
    error YieldToken_OnlyPrincipalToken();

    // Module
    error Module_CallFailed();

    // FeeModule
    error FeeModule_InvalidFeeParam();
    error FeeModule_SplitFeeExceedsMaximum();
    error FeeModule_SplitFeeMismatchDefault();
    error FeeModule_SplitFeeTooLow();
    error FeeModule_IssuanceFeeExceedsMaximum();
    error FeeModule_PerformanceFeeExceedsMaximum();
    error FeeModule_RedemptionFeeExceedsMaximum();
    error FeeModule_PostSettlementFeeExceedsMaximum();

    // PoolFeeModule
    error PoolFeeModule_FeeExceedsMaximum();
    error PoolFeeModule_ReserveFeeExceedsMaximum();
    error PoolFeeModule_InvalidFeeParam();
    // RewardProxy
    error RewardProxy_InconsistentRewardTokens();
    error MorphoRewardProxy_InvalidDistributor();
    error MorphoRewardProxy_InvalidTreasury();
    error MerklRewardProxy_InvalidDistributor();
    error MerklRewardProxy_InvalidOperator();
    error MerklRewardProxy_InvalidTreasury();
    error SiloRewardProxy_InvalidController();
    error SiloRewardProxy_NoProgramNames();

    error Factory_ModuleNotFound();
    error Factory_InvalidExpiry();
    error Factory_InvalidPoolDeployer();
    error Factory_InvalidModule();
    error Factory_FeeModuleRequired();
    error Factory_PrincipalTokenNotFound();
    error Factory_InvalidModuleType();
    error Factory_InvalidAddress();
    error Factory_InvalidSuite();
    error Factory_CannotUpdateFeeModule();

    error PoolDeployer_FailedToDeployPool();

    error Zap_LengthMismatch();
    error Zap_TransactionTooOld();
    error Zap_BadTwoCrypto();
    error Zap_BadPrincipalToken();
    error Zap_BadCallback();
    error Zap_InconsistentETHReceived();
    error Zap_InsufficientETH();
    error Zap_InsufficientPrincipalOutput();
    error Zap_InsufficientTokenOutput();
    error Zap_InsufficientUnderlyingOutput();
    error Zap_InsufficientYieldTokenOutput();
    error Zap_InsufficientPrincipalTokenOutput();
    error Zap_DebtExceedsUnderlyingReceived();
    error Zap_PullYieldTokenGreaterThanInput();
    error Zap_InsufficientLiquidity();
    error Zap_BadPoolDeployer();
    error Zap_InsufficientYieldTokenBalance();

    error V4Router_InvalidPayer();
    error V4Router_InvalidRateRange();

    // Resolver errors
    error Resolver_ConversionFailed();
    error Resolver_InvalidDecimals();
    error Resolver_ZeroAddress();
    // VaultConnectorRegistry errors
    error VCRegistry_ConnectorNotFound();

    // ERC4626Connector errors
    error ERC4626Connector_InvalidToken();
    error ERC4626Connector_InvalidETHAmount();
    error ERC4626Connector_UnexpectedETH();

    // WrapperConnector errors
    error WrapperConnector_InvalidETHAmount();
    error WrapperConnector_UnexpectedETH();

    // WrapperFactory errors
    error WrapperFactory_ImplementationNotSet();
    error WrapperFactory_InvalidWrapperImplementation();

    // Quoter errors
    error Quoter_ERC4626FallbackCallFailed();
    error Quoter_ConnectorInvalidToken();
    error Quoter_InsufficientUnderlyingOutput();
    error Quoter_MaximumYtOutputReached();

    // ConversionLib errors
    error ConversionLib_NegativeYtPrice();

    // AggregationRouter errors
    error AggregationRouter_UnsupportedRouter();
    error AggregationRouter_SwapFailed();
    error AggregationRouter_ZeroReturn();
    error AggregationRouter_InvalidMsgValue();

    // DefaultConnectorFactory errors
    error DefaultConnectorFactory_TargetNotERC4626();
    error DefaultConnectorFactory_InvalidToken();

    // Lens errors
    error Lens_LengthMismatch();
    error Lens_PriceFeedNotFound();
    error Lens_BadPriceProvider();

    // ERC4626Wrapper errors
    error ERC4626Wrapper_TokenNotListed();

    error ATokenWrapper_CannotSweepUnderlyingToken();

    error Wrapper_NotFactory();
    error Wrapper_PrincipalTokenAlreadySet();
    error Wrapper_InvalidPrincipalToken();
    error Wrapper_PrincipalTokenNotSet();

    // TokiPoolDeployer errors
    error TokiPoolDeployer_OnlyFactory();
    error TokiPoolDeployer_InvalidHook();
    error TokiPoolDeployer_BadCurrencyOrder();
    error TokiPoolDeployer_InvalidHooklet();
    error TokiPoolDeployer_InvalidLiquidityTokenImplementation();

    error BadTokiPool();

    // Hook errors
    error CustomCurveHook_FeeMustBeZero();
    error CustomCurveHook_LiquidityOnlyViaHook();

    error TokiHook_OnlyPoolDeployer();
    error TokiHook_InvalidScalarRoot();
    error TokiHook_InitialAnchorTooLow();
    error TokiHook_MissingPoolFeeModule();
    error TokiHook_VaultAlreadySet();
    error TokiHook_VaultWithdrawMoreThanReserves();
    error TokiHook_InsufficientAssetsWithdrawn();
    error TokiHook_NoVaultRedeemCapacity();
    error TokiHook_InsufficientInputAmount(address vault);
    error TokiHook_VaultHasAssets();
    error TokiHook_VaultNotSet();
    error TokiHook_NotImplemented();

    // Rehypothecation errors
    error Rehypothecation_InvalidRawTokenRatioBounds();
    error Rehypothecation_VaultAssetMismatch();
    error Rehypothecation_ParamsFrozen();
    error Rehypothecation_VaultFrozen();
    error Rehypothecation_VaultDepositMoreThanRequested();
    error Rehypothecation_VaultRedeemMoreThanRequested();

    //LiquidityAmounts errors
    error LiquidityAmounts_InsufficientInitialLiquidity();
    error LiquidityAmounts_NoLiquidity();
    error LiquidityAmounts_LiquidityExceedsTotalLiquidity();
    error LiquidityAmounts_ZeroAmountInput();

    // Swap Math errors
    error TokiSwap_ZeroLiquidity();
    error TokiSwap_RateScalarZero();
    error TokiSwap_BadRateRange();
    error TokiSwap_ExchangeRateBelowOne(int256 exchangeRate);
    error TokiSwap_ProportionGreaterThanOne();
    error TokiSwap_MarketProportionTooHigh();
    error TokiSwap_ImpliedRateZero();
    error TokiSwap_InsufficientPrincipalsLiquidity();
    error TokiSwap_OnlyExactInSupported();
    error TokiSwap_NoSolutionFound();

    error ApproximationParams_OutOfBounds();
    error ApproximationParams_InvalidGuess();
    error ApproximationParams_InvalidEps();

    error LibApproximation_NoSolutionFound();

    // LiquidityToken errors
    error LiquidityToken_OnlyHook();
    error LiquidityToken_PoolManagerMustBeLocked();

    // LibPauseGuard errors
    error LibPauseGuard_Paused();
}
