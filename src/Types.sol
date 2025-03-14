// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "./types/Token.sol" as TokenType;
import "./types/FeePcts.sol" as FeePctsType;
import "./types/ApproxValue.sol" as ApproxValueType;
import "./types/TwoCrypto.sol" as TwoCryptoType;
import "./types/ModuleIndex.sol" as ModuleIndexType;

/// The `FeePcts` type is 256 bits long, and packs the following:
///
/// ```
///   | [uint176]: reserved for future use
///   |                                           | [uint16]: postSettlementFeePct
///   |                                           ↓   | [uint16]: redemptionFeePct
///   |                                           ↓   ↓   | [uint16]: performanceFeePct
///   |                                           ↓   ↓   ↓   | [uint16]: issuanceFeePct
///   |                                           ↓   ↓   ↓   ↓   ↓ [uint16]: splitPctBps
/// 0x00000000000000000000000000000000000000000000AAAABBBBCCCCDDDDEEEE
/// ```
type FeePcts is uint256;

using {FeePctsType.unwrap} for FeePcts global;

/// The `ApproxValue` type represents an approximate value from off-chain sources or `Quoter` contract.
type ApproxValue is uint256;

using {ApproxValueType.unwrap} for ApproxValue global;

/// The `Token` type represents an ERC20 token address or the native token address (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE).
/// Zap contracts use this type to represent tokens in the system.
/// It's main purpose is to provide a type-safe way to represent tokens in the system.
/// ```
/// function supply(address token, address receiver) public payable {
///     SafeTransferLib.safeTransferFromAll(token, receiver); // ❌ Compiler can't find bug.
/// }
///
/// function supply(Token token, address receiver) public payable {
///     SafeTransferLib.safeTransferFromAll(token, receiver); // 👌 Compiler can notice something wrong.
/// }
/// ```
type Token is address;

using {TokenType.unwrap} for Token global;
using {TokenType.erc20} for Token global;
using {TokenType.isNative} for Token global;
using {TokenType.isNotNative} for Token global;
using {TokenType.eq} for Token global;

/// The `TwoCrypto` type represents a Curve finance twocrypto-ng pool (LP token) address not old twocrypto implementation.
type TwoCrypto is address;

using {TwoCryptoType.unwrap} for TwoCrypto global;

struct TwoCryptoNGParams {
    uint256 A;
    uint256 gamma;
    uint256 mid_fee;
    uint256 out_fee;
    uint256 fee_gamma;
    uint256 allowed_extra_profit;
    uint256 adjustment_step;
    uint256 ma_time;
    uint256 initial_price;
}

/// @dev Do not change the order of the enum
// Do not prepend new fee parameters to the enum, as it will break the compatibility with the existing deployments
enum FeeParameters {
    FEE_SPLIT_RATIO, // The fee % going to curator. The rest goes to Napier treasury
    ISSUANCE_FEE, // The fee % charged on issuance of PT/YT
    PERFORMANCE_FEE, // The fee % charged on the interest made by YT
    REDEMPTION_FEE, // The fee % charged on redemption of PT/YT
    POST_SETTLEMENT_FEE // The fee % charged on performance fee after settlement

}

/// @notice The `TokenReward` struct represents a additional reward token like COMP, AAVE, etc and the amount of reward.
struct TokenReward {
    address token;
    uint256 amount;
}

using {ModuleIndexType.unwrap} for ModuleIndex global;
using {ModuleIndexType.isSupportedByFactory} for ModuleIndex global;
using {ModuleIndexType.eq as ==} for ModuleIndex global;

/// The `ModuleIndex` type represents a unique index for each module in the system.
type ModuleIndex is uint256;

ModuleIndex constant FEE_MODULE_INDEX = ModuleIndex.wrap(0);
ModuleIndex constant REWARD_PROXY_MODULE_INDEX = ModuleIndex.wrap(1);
ModuleIndex constant VERIFIER_MODULE_INDEX = ModuleIndex.wrap(2);
uint256 constant MAX_MODULES = 3;

/// @dev Do not change the order of the enum
/// @dev Verification status codes in the system for the `VerifierModule`.
enum VerificationStatus {
    InvalidArguments, // Unexpected error
    Success,
    SupplyMoreThanMax,
    Restricted,
    InvalidSelector
}
