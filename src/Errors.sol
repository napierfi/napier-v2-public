// SPDX-License-Identifier: GPL-3.0
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

    // RewardProxy
    error RewardProxy_InconsistentRewardTokens();

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
    error Factory_InvalidDecimals();

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
    error Zap_BadPoolDeployer();

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

    // ERC4626Wrapper errors
    error ERC4626Wrapper_TokenNotListed();
}
