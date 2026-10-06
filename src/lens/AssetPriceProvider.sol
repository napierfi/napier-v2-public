// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Inherits
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";
import {AccessManaged, AccessManager} from "../modules/AccessManager.sol";

// Interfaces
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Factory} from "../Factory.sol";

// External
import {Currency, FeedRegistry} from "./external/FeedRegistry.sol";
import {AggregatorV3Interface} from "./external/AggregatorV3Interface.sol";
import {Denominations} from "./external/Denominations.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";

import "../Types.sol";
import "../Errors.sol";
import "../Constants.sol" as Constants;

/// @dev Chainlink Feed Registry is only deployed on Ethereum Mainnet. On other networks, we add a fallback oracle for each currency.
/// @dev ERC1967I Immutable args: abi.encode(factory, weth)
contract AssetPriceProvider is UUPSUpgradeable, Initializable, AccessManaged {
    /// @notice Storage slot for the currency price provider: `cast index-erc7201 napier-v2.asset-price-provider.storage`
    bytes32 constant CURRENCY_PRICE_PROVIDER_NAMESPACE_STORAGE_LOCATION =
        0x8271388a6ab7a51ce2d29b04b3487d6fefa7ae21e33f39dc1c8ca6d2301d6400;

    /// @param s_priceOracles: Price oracles for each currency.
    /// @param s_feedRegistry: Feed registry for Ethereum Mainnet. Chainlink feed registry is not deployed on other networks.
    struct AssetPriceProviderNamespace {
        mapping(Currency currency => AggregatorV3Interface oracle) s_priceOracles;
        FeedRegistry s_feedRegistry;
    }

    constructor() {
        _disableInitializers();
    }

    function _getStorage() internal pure returns (AssetPriceProviderNamespace storage $) {
        assembly {
            $.slot := CURRENCY_PRICE_PROVIDER_NAMESPACE_STORAGE_LOCATION
        }
    }

    function initialize(address feed) public initializer {
        AssetPriceProviderNamespace storage $ = _getStorage();
        $.s_feedRegistry = FeedRegistry(feed);
    }

    /// @dev Returns the latest price in USD.
    // e.g. ETH/USD -> $3,000 -> 3000 * 10^(18 - 8)
    // USDC/USD -> $0.99 -> 0.99 * 10^(18 - 8)
    /// @dev It can return 0 if the price feed is not available.
    /// @dev Standardize WETH to ETH on Ethereum Mainnet.
    function getPriceUSDInWad(address asset) public view returns (uint256) {
        (bool ok, uint256 price) = tryGetPriceUSDInWad(asset);
        if (!ok) revert Errors.Lens_PriceFeedNotFound();
        return price;
    }

    /// @notice Try to get the latest price in USD (wad). Returns (ok, price).
    /// @dev Mirrors `getPriceUSDInWad` logic but provides a success flag instead of relying on 0.
    function tryGetPriceUSDInWad(address asset) public view returns (bool, uint256) {
        // Note: Standardize WETH to native ETH on Ethereum Mainnet.
        if (block.chainid == 1 && asset == Constants.WETH_ETHEREUM_MAINNET) {
            asset = Denominations.ETH.unwrap();
        }

        AssetPriceProviderNamespace storage $ = _getStorage();

        Currency currency = Currency.wrap(asset);
        FeedRegistry feed = $.s_feedRegistry;

        int256 answer;
        uint256 decimals;

        // If price oracle is available, use it. Otherwise, try to use FeedRegistry but it may revert with feed not found.
        AggregatorV3Interface oracle = $.s_priceOracles[currency];
        if (_hasCode(address(oracle))) {
            try oracle.decimals() returns (uint8 retDecimals) {
                decimals = retDecimals;
            } catch {}

            try oracle.latestRoundData() returns (uint80, int256 retAnswer, uint256, uint256, uint80) {
                answer = retAnswer;
            } catch {}
        }

        // 0 means no price oracle is available
        bool fallbackToFeedRegistry = (answer <= 0 || decimals == 0) && _hasCode(address(feed));

        if (fallbackToFeedRegistry) {
            // FeedRegistry may revert with feed not found
            try feed.decimals(currency, Denominations.USD) returns (uint8 retDecimals) {
                decimals = retDecimals;
            } catch {}

            try feed.latestRoundData({base: currency, quote: Denominations.USD}) returns (
                uint80, int256 retAnswer, uint256, uint256, uint80
            ) {
                answer = retAnswer;
            } catch {}
        }

        if (answer <= 0 || decimals == 0) return (false, 0); // Default value means all attempts failed
        return (true, uint256(answer) * 10 ** (18 - decimals));
    }

    /// @dev Convert assets to USD in wad.
    function convertToUSDWadOrZero(uint256 assets, address asset) external view returns (uint256) {
        (bool ok, uint256 priceWad) = tryGetPriceUSDInWad(asset);
        if (!ok) return 0;
        return assets * priceWad / 10 ** ERC20(asset).decimals();
    }

    function priceOracle(Currency currency) public view returns (AggregatorV3Interface) {
        AssetPriceProviderNamespace storage $ = _getStorage();
        return $.s_priceOracles[currency];
    }

    function feedRegistry() public view returns (FeedRegistry) {
        AssetPriceProviderNamespace storage $ = _getStorage();
        return $.s_feedRegistry;
    }

    function i_factory() public view returns (Factory factory) {
        factory = abi.decode(LibClone.argsOnERC1967I(address(this)), (Factory));
    }

    function i_accessManager() public view override returns (AccessManager) {
        return i_factory().i_accessManager();
    }

    function _hasCode(address account) internal view returns (bool) {
        return account.code.length > 0;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Permissioned                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setFeedRegistry(address feed) public restricted {
        AssetPriceProviderNamespace storage $ = _getStorage();
        $.s_feedRegistry = FeedRegistry(feed);
    }

    /// @dev Set the price oracle for a currency.
    /// @dev Chainlink have unique identifiers for non canonical assets like BTC and USD.
    function setPriceOracle(Currency[] calldata currencies, address[] calldata oracles) public restricted {
        AssetPriceProviderNamespace storage $ = _getStorage();

        if (currencies.length != oracles.length) revert Errors.Lens_LengthMismatch();
        for (uint256 i = 0; i < currencies.length; i++) {
            Currency currency = currencies[i];
            $.s_priceOracles[currency] = AggregatorV3Interface(oracles[i]);
        }
    }

    function _authorizeUpgrade(address) internal view override restricted {}
}
