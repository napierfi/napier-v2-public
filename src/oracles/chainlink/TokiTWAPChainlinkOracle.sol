// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IChainlinkCompatibleAggregatorV3} from "./IChainlinkCompatibleAggregatorV3.sol";
import {Factory} from "../../Factory.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {TokiPoolToken} from "../../tokens/TokiPoolToken.sol";
import {TokiOracle} from "../TokiOracle.sol";

import {TWAPPrice} from "../TWAPPrice.sol";

/// @dev Ensure pool has enough liquidity to resist manipulation.
/// @dev Assumptions: token is less than or equal to 18 decimals
contract TokiTWAPChainlinkOracle is IChainlinkCompatibleAggregatorV3, Initializable {
    using SafeCastLib for *;

    /// @dev The minimum length of the TWAP window.
    uint32 constant MIN_TWAP_WINDOW = 5 minutes;

    /// @dev Immutable across all instances of the oracle.
    Factory public immutable i_factory;
    TokiOracle public immutable i_tokiOracle;

    error TWAPChainlinkOracle_BadPool();
    error TWAPChainlinkOracle_InvalidConfiguration();

    constructor(TokiOracle tokiOracle) {
        i_tokiOracle = tokiOracle;
        i_factory = Factory(TokiOracle(address(tokiOracle)).i_factory());
        _disableInitializers();
    }

    function initialize(bytes calldata /*data*/ ) external initializer {
        (address liquidityToken, address base, address quote, uint32 twapWindow) = parseImmutableArgs();

        if (i_factory.s_pools(liquidityToken) == address(0)) {
            revert TWAPChainlinkOracle_BadPool();
        }

        // Verify that the TWAP window is sufficiently long.
        if (twapWindow < MIN_TWAP_WINDOW) {
            revert TWAPChainlinkOracle_InvalidConfiguration();
        }

        // Verify that the observations buffer is adequately sized and populated.
        //
        (bool increaseCardinalityRequired,, bool oldestObservationSatisfied) =
            i_tokiOracle.checkTwapReadiness(liquidityToken, twapWindow);

        if (increaseCardinalityRequired || !oldestObservationSatisfied) {
            revert TWAPChainlinkOracle_InvalidConfiguration();
        }

        PoolKey memory poolKey = TokiPoolToken(liquidityToken).i_poolKey();

        if (base != Currency.unwrap(poolKey.currency1) && base != liquidityToken) {
            revert TWAPChainlinkOracle_InvalidConfiguration();
        }

        if (
            quote != Currency.unwrap(poolKey.currency0)
                && quote != address(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset())
        ) {
            revert TWAPChainlinkOracle_InvalidConfiguration();
        }
    }

    /// @return answer {PT, LP} price in terms of {asset, underlying} token in 18 decimals
    function latestRoundData()
        public
        view
        virtual
        returns (
            uint80, /* roundId */
            int256 answer,
            uint256, /* startedAt */
            uint256 updatedAt,
            uint80 /* answeredInRound */
        )
    {
        (address liquidityToken, address base, address quote, uint32 twapWindow) = parseImmutableArgs();

        PoolKey memory poolKey = TokiPoolToken(liquidityToken).i_poolKey();

        // convert{PT, LP}To{Underlying, Assets} function pointer
        function(address, uint32, uint256) internal view returns (uint256) convertFn;

        if (base == Currency.unwrap(poolKey.currency1)) {
            if (quote == Currency.unwrap(poolKey.currency0)) {
                convertFn = TWAPPrice.convertPtToUnderlying;
            } else {
                convertFn = TWAPPrice.convertPtToAssets;
            }
        } else if (base == liquidityToken) {
            if (quote == Currency.unwrap(poolKey.currency0)) {
                convertFn = TWAPPrice.convertLpToUnderlying;
            } else {
                convertFn = TWAPPrice.convertLpToAssets;
            }
        } else {
            // This should never happen. Since we check the pool key in initialization.
            revert TWAPChainlinkOracle_InvalidConfiguration();
        }

        // Use 1 whole base unit (respecting base token decimals) for conversion
        uint256 value = convertFn(liquidityToken, twapWindow, 10 ** ERC20(base).decimals());

        // Normalize the quote amount to 18 decimals safely
        value *= 10 ** (18 - ERC20(quote).decimals());

        answer = value.toInt256();
        updatedAt = block.timestamp;
        return (0, answer, 0, updatedAt, 0);
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function description() external pure returns (string memory) {
        return "Napier V2 TokiPool TWAP Chainlink Oracle";
    }

    function label() external view returns (bytes32) {
        return "TokiTWAPChainlinkOracle";
    }

    function parseImmutableArgs()
        public
        view
        returns (address liquidityToken, address base, address quote, uint32 twapWindow)
    {
        (liquidityToken, base, quote, twapWindow) =
            abi.decode(LibClone.argsOnClone(address(this)), (address, address, address, uint32));
    }
}
