// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

// Inherits
import {Ownable} from "solady/src/auth/Ownable.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// Interfaces
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Factory} from "../../Factory.sol";
import {FeeModule} from "../../modules/FeeModule.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {VaultInfoResolver} from "../../modules/resolvers/VaultInfoResolver.sol";

// External
import {Currency, FeedRegistry} from "../external/FeedRegistry.sol";
import {AggregatorV3Interface} from "../external/AggregatorV3Interface.sol";
import {Denominations} from "../external/Denominations.sol";
import {AssetPriceProvider} from "../AssetPriceProvider.sol";

// Internal
import {LibExpiry} from "../../utils/LibExpiry.sol";
import {RewardLensLib} from "../RewardLensLib.sol";
import {VerifierLensLib} from "../VerifierLensLib.sol";
import {ConversionLib} from "./ConversionLib.sol";
import {LibTwoCryptoNG} from "../../utils/LibTwoCryptoNG.sol";
import {ContractValidation} from "../../utils/ContractValidation.sol";
import {LibAccessGuard} from "../../utils/LibAccessGuard.sol";

// Types
import "../../Types.sol";
import "../../Constants.sol" as Constants;
import {Errors} from "../../Errors.sol";

contract Lens is UUPSUpgradeable, Initializable, Ownable {
    using LibTwoCryptoNG for TwoCrypto;

    /// @notice External price feeds fallback if feed registry is not set
    /// @dev Deprecated but never removed since it's required for storage backward compatibility
    mapping(Currency currency => AggregatorV3Interface oracle) public s_priceOracles;

    /// @notice A primary price feed used if available (otherwise, fallback to price oracle)
    /// @dev Deprecated but never removed since it's required for storage backward compatibility
    FeedRegistry public s_feedRegistry;

    /// @notice Deprecated but never removed since it's required for storage backward compatibility
    address public s_WETH;

    address public s_twoCryptoDeployer;

    Factory public s_factory;

    /// @dev Update from v2. We no longer use the price oracle directly.
    /// @dev External price provider.
    AssetPriceProvider public s_priceProvider;

    constructor() {
        _disableInitializers();
    }

    /// @dev WETH and twoCryptoDeployer must match the ones used in the factory
    /// @notice Backward-compatible initializer (no external price provider)
    function initialize(Factory factory, address twoCryptoDeployer, address owner, address priceProvider)
        public
        initializer
    {
        s_factory = factory;
        s_twoCryptoDeployer = twoCryptoDeployer;
        _initializeOwner(owner);
        s_priceProvider = AssetPriceProvider(priceProvider);
    }

    struct TrancheData {
        string name;
        string symbol;
        address factory;
        uint256 expiry;
        address resolver;
        address yt;
        address target;
        address asset;
        uint256 decimals;
        uint256 scale; // 1e(18 + assetDecimals - underlyingDecimals) units
        uint256 ptTotalSupply;
        uint256 ytTotalSupply;
        FeePcts feePcts;
        address[] rewardTokens;
        uint256 protocolFee;
        uint256 curatorFee;
        TokenReward[] curatorFeeRewards;
        TokenReward[] protocolFeeRewards;
        bool isExpired;
        bool isSettled;
        bool paused;
        uint256 depositCapInShare; // type(uint256).max if no limit
        uint256 depositCapInAsset;
        uint256 depositCapInUSD;
        uint256 maxDepositInShare; // type(uint256).max if no limit
        uint256 maxDepositInAsset; // type(uint256).max if no limit
        uint256 maxDepositInUSD; // type(uint256).max if no limit
        uint256 ptTVLInShare;
        uint256 ptTVLInAsset;
        uint256 ptTVLInUSD;
    }

    function getTrancheData(PrincipalToken principalToken)
        public
        view
        checkPrincipalToken(principalToken)
        returns (TrancheData memory data)
    {
        ERC20 yt = principalToken.i_yt();
        ERC20 underlying = ERC20(principalToken.underlying());
        address asset = address(principalToken.i_asset());

        // Reward proxy is optional
        address[] memory rewardTokens = RewardLensLib.getRewardTokens(principalToken);

        data = TrancheData({
            expiry: principalToken.maturity(),
            factory: address(s_factory),
            yt: address(yt),
            resolver: address(principalToken.i_resolver()),
            target: address(underlying),
            asset: asset,
            name: principalToken.name(),
            symbol: principalToken.symbol(),
            decimals: principalToken.decimals(),
            ptTotalSupply: principalToken.totalSupply(),
            ytTotalSupply: yt.totalSupply(),
            scale: principalToken.i_resolver().scale(),
            isExpired: LibExpiry.isExpired(principalToken),
            isSettled: principalToken.isSettled(),
            paused: principalToken.paused(),
            rewardTokens: rewardTokens,
            // Fee module is mandatory
            feePcts: FeeModule(s_factory.moduleFor(address(principalToken), FEE_MODULE_INDEX)).getFeePcts(),
            // Will be filled later
            depositCapInShare: 0,
            depositCapInAsset: 0,
            depositCapInUSD: 0,
            maxDepositInShare: 0,
            maxDepositInAsset: 0,
            maxDepositInUSD: 0,
            protocolFee: 0,
            curatorFee: 0,
            curatorFeeRewards: new TokenReward[](0),
            protocolFeeRewards: new TokenReward[](0),
            ptTVLInShare: 0,
            ptTVLInAsset: 0,
            ptTVLInUSD: 0
        });

        // Fill the remaining data

        (data.curatorFee, data.protocolFee) = principalToken.getFees();
        (data.curatorFeeRewards, data.protocolFeeRewards) = RewardLensLib.getFeeRewards(principalToken);

        data.ptTVLInShare = underlying.balanceOf(address(principalToken));
        data.ptTVLInAsset = ConversionLib.convertSharesToAssets(data.ptTVLInShare, data.scale);
        data.ptTVLInUSD = _convertAssetsToUSD(data.ptTVLInAsset, asset);

        // Global deposit cap
        data.depositCapInShare = VerifierLensLib.getDepositCap(principalToken);
        data.depositCapInAsset = data.depositCapInShare < type(uint256).max
            ? ConversionLib.convertSharesToAssets(data.depositCapInShare, data.scale)
            : type(uint256).max;
        data.depositCapInUSD = data.depositCapInAsset < type(uint256).max
            ? _convertAssetsToUSD(data.depositCapInAsset, asset)
            : type(uint256).max;

        // Max deposit
        data.maxDepositInShare = principalToken.maxSupply(address(0));
        data.maxDepositInAsset = data.maxDepositInShare < type(uint256).max
            ? ConversionLib.convertSharesToAssets(data.maxDepositInShare, data.scale)
            : type(uint256).max;
        data.maxDepositInUSD = data.maxDepositInAsset < type(uint256).max
            ? _convertAssetsToUSD(data.maxDepositInAsset, asset)
            : type(uint256).max;
    }

    struct TwoCryptoData {
        string name;
        string symbol;
        uint256 decimals;
        address coin0;
        address coin1;
        uint256 balance0;
        uint256 balance1;
        uint256 totalSupply;
        uint256 ptPriceInShare;
        uint256 lpPriceInShare;
        uint256 poolValueInShare;
        uint256 poolValueInAsset;
        uint256 poolValueInUSD;
    }

    function getTwoCryptoData(TwoCrypto twoCrypto)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (TwoCryptoData memory data)
    {
        address underlying = twoCrypto.coins(Constants.TARGET_INDEX);
        address pt = twoCrypto.coins(Constants.PT_INDEX);
        address asset = address(PrincipalToken(pt).i_asset());

        data = TwoCryptoData({
            name: twoCrypto.name(),
            symbol: twoCrypto.symbol(),
            decimals: twoCrypto.decimals(),
            coin0: underlying,
            coin1: pt,
            balance0: twoCrypto.balances(Constants.TARGET_INDEX),
            balance1: twoCrypto.balances(Constants.PT_INDEX),
            totalSupply: twoCrypto.totalSupply(),
            // Skip the following data for now (will be filled later)
            ptPriceInShare: 0,
            lpPriceInShare: 0,
            poolValueInShare: 0,
            poolValueInAsset: 0,
            poolValueInUSD: 0
        });

        // Fill the remaining data

        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("lp_price()"));
        data.lpPriceInShare = s ? abi.decode(ret, (uint256)) : 1e18;

        (s, ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("price_oracle()"));
        data.ptPriceInShare = s ? abi.decode(ret, (uint256)) : 1e18;

        data.poolValueInShare = (data.totalSupply * data.lpPriceInShare) / Constants.WAD;
        data.poolValueInAsset =
            ConversionLib.convertSharesToAssets(data.poolValueInShare, PrincipalToken(pt).i_resolver().scale());
        data.poolValueInUSD = _convertAssetsToUSD(data.poolValueInAsset, asset);
    }

    struct UserData {
        uint256 targetBalance;
        uint256 assetBalance;
        uint256 ptBalance;
        uint256 ytBalance;
        uint256 interest;
        TokenReward[] rewards;
        uint256 lpBalanceInWallet;
        uint256 lpBalanceInGauge;
        uint256 portfolioInShare;
        uint256 portfolioInAsset;
        uint256 portfolioInUSD;
    }

    function getAccountData(TwoCrypto twoCrypto, address account)
        public
        view
        checkTwoCrypto(twoCrypto)
        returns (UserData memory data)
    {
        PrincipalToken pt = PrincipalToken(twoCrypto.coins(Constants.PT_INDEX));

        data = UserData({
            ptBalance: pt.balanceOf(account),
            ytBalance: pt.i_yt().balanceOf(account),
            interest: pt.previewCollect(account),
            rewards: RewardLensLib.getTokenRewards(pt, account),
            targetBalance: ERC20(pt.underlying()).balanceOf(account),
            assetBalance: pt.i_asset().balanceOf(account),
            lpBalanceInWallet: twoCrypto.balanceOf(account),
            // Skip the following data for now (will be filled later)
            lpBalanceInGauge: 0,
            portfolioInAsset: 0,
            portfolioInShare: 0,
            portfolioInUSD: 0
        });

        // Fill portfolio data
        PriceData memory priceData = getPriceData(twoCrypto);

        data.portfolioInShare = data.interest // Value of interest
            + (data.ptBalance * priceData.ptPriceInShare) / Constants.WAD // Value of principal token
            + (data.ytBalance * priceData.ytPriceInShare) / Constants.WAD // Value of yield token
            + ((data.lpBalanceInWallet + data.lpBalanceInGauge) * priceData.lpPriceInShare) / Constants.WAD; // Value of liquidity
        data.portfolioInAsset = ConversionLib.convertSharesToAssets(data.portfolioInShare, priceData.scale);
        data.portfolioInUSD =
            ConversionLib.convertAssetsToUSD(data.portfolioInAsset, priceData.assetPriceInUSD, pt.decimals());
    }

    /// @dev All values are in `1e18` units except for `scale` which is in `1e(18 + assetDecimals - underlyingDecimals)` units.
    struct PriceData {
        uint256 scale; // 1 asset = scale * shares / WAD
        uint256 assetPriceInUSD;
        uint256 ptPriceInShare;
        uint256 ytPriceInShare;
        uint256 ptPriceInUSD;
        uint256 ytPriceInUSD;
        uint256 lpPriceInShare;
        uint256 lpPriceInUSD;
        uint256 virtualPrice;
        // If expired, it returns 0
        int256 impliedAPY; // 5% -> 0.05 * Constants.WAD
    }

    /// @dev It can revert if oracle is not set or revert.
    /// @dev It should NOT revert even if expired
    /// @dev It should NOT revert even if LP total supply is 0
    /// @dev It should NOT revert even if PT price is greater than 1 underlying token.
    function getPriceData(TwoCrypto twoCrypto) public view checkTwoCrypto(twoCrypto) returns (PriceData memory data) {
        PrincipalToken principalToken = PrincipalToken(twoCrypto.coins(Constants.PT_INDEX));
        data.assetPriceInUSD = getPriceUSDInWad(address(principalToken.i_asset()));

        VaultInfoResolver resolver = principalToken.i_resolver();
        uint256 scaleUnit = 10 ** (18 + resolver.assetDecimals() - resolver.decimals());

        try resolver.scale() returns (uint256 scale) {
            data.scale = scale;
        } catch {
            data.scale = scaleUnit;
        }

        (bool s, bytes memory ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("lp_price()"));
        if (s) data.lpPriceInShare = abi.decode(ret, (uint256)); // If no liquidity, price is 0

        (s, ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("last_prices()"));

        // If no price, price in underlying should be set so that price in asset is 1
        data.ptPriceInShare = s ? abi.decode(ret, (uint256)) : Constants.WAD * scaleUnit / scaleUnit;

        // 1 Asset Price = 1 PT Price in Asset + 1 YT Price in Asset
        uint256 ptPriceInAsset = data.ptPriceInShare * data.scale / scaleUnit;
        uint256 ytPriceInAsset = Constants.WAD > ptPriceInAsset ? Constants.WAD - ptPriceInAsset : 0;
        data.ytPriceInShare = ytPriceInAsset * scaleUnit / data.scale; // shares = assets / scale

        (s, ret) = twoCrypto.unwrap().staticcall(abi.encodeWithSignature("get_virtual_price()"));
        data.virtualPrice = s ? abi.decode(ret, (uint256)) : 1e18;

        // 1e18 * 10**(18 + bDecimals - uDecimals) / 10**(18 + bDecimals - uDecimals)
        data.ptPriceInUSD = ConversionLib.convertPriceWeiToUSD(ptPriceInAsset, data.assetPriceInUSD);
        data.ytPriceInUSD = ConversionLib.convertPriceWeiToUSD(ytPriceInAsset, data.assetPriceInUSD);
        uint256 lpPriceInAsset = data.lpPriceInShare * data.scale / scaleUnit;
        data.lpPriceInUSD = ConversionLib.convertPriceWeiToUSD(lpPriceInAsset, data.assetPriceInUSD);

        // Spot Implied APY
        data.impliedAPY = ConversionLib.convertToImpliedAPY({pt: address(principalToken), priceInAsset: ptPriceInAsset});
    }

    struct TVLData {
        uint256 ptTVLInShare;
        uint256 ptTVLInAsset;
        uint256 ptTVLInUSD;
        uint256 poolTVLInShare;
        uint256 poolTVLInAsset;
        uint256 poolTVLInUSD;
    }

    function getTVL(TwoCrypto twoCrypto) public view returns (TVLData memory) {
        TrancheData memory trancheData = getTrancheData(PrincipalToken(twoCrypto.coins(Constants.PT_INDEX)));
        TwoCryptoData memory twoCryptoData = getTwoCryptoData(twoCrypto);

        return TVLData({
            ptTVLInShare: trancheData.ptTVLInShare,
            ptTVLInAsset: trancheData.ptTVLInAsset,
            ptTVLInUSD: trancheData.ptTVLInUSD,
            poolTVLInShare: twoCryptoData.poolValueInShare,
            poolTVLInAsset: twoCryptoData.poolValueInAsset,
            poolTVLInUSD: twoCryptoData.poolValueInUSD
        });
    }

    /// @dev Returns the latest price in USD.
    // e.g. ETH/USD -> $3,000 -> 3000 * 10^(18 - 8)
    // USDC/USD -> $0.99 -> 0.99 * 10^(18 - 8)
    /// @dev Returns 0 if the price feed is not available.
    function getPriceUSDInWad(address asset) public view returns (uint256) {
        // If external provider configured, delegate
        AssetPriceProvider priceProvider = s_priceProvider;
        if (ContractValidation.hasCode(address(priceProvider))) {
            (, uint256 p) = priceProvider.tryGetPriceUSDInWad(asset);
            return p;
        }

        // Legacy inline logic for backward compatibility
        Currency currency = Currency.wrap(asset);

        int256 answer;
        uint256 decimals;

        // If price oracle is available, use it. Otherwise, try to use FeedRegistry but it may revert with feed not found.
        AggregatorV3Interface oracle = s_priceOracles[currency];
        if (ContractValidation.hasCode(address(oracle))) {
            try oracle.decimals() returns (uint8 retDecimals) {
                decimals = retDecimals;
            } catch {}

            try oracle.latestRoundData() returns (uint80, int256 retAnswer, uint256, uint256, uint80) {
                answer = retAnswer;
            } catch {}
        }

        // 0 means no price oracle is available
        bool fallbackToFeedRegistry =
            (answer <= 0 || decimals == 0) && ContractValidation.hasCode(address(s_feedRegistry));

        if (fallbackToFeedRegistry) {
            // FeedRegistry may revert with feed not found
            try s_feedRegistry.decimals(currency, Denominations.USD) returns (uint8 retDecimals) {
                decimals = retDecimals;
            } catch {}

            try s_feedRegistry.latestRoundData({base: currency, quote: Denominations.USD}) returns (
                uint80, int256 retAnswer, uint256, uint256, uint80
            ) {
                answer = retAnswer;
            } catch {}
        }

        if (answer <= 0 || decimals == 0) return 0; // Default value means all attempts failed
        return uint256(answer) * 10 ** (18 - decimals);
    }

    function _convertAssetsToUSD(uint256 assets, address asset) internal view returns (uint256) {
        return ConversionLib.convertAssetsToUSD(assets, getPriceUSDInWad(asset), ERC20(asset).decimals());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Permissioned                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Set external price provider. When set, Lens delegates price queries to it.
    function setPriceProvider(address provider) public restricted {
        s_priceProvider = AssetPriceProvider(provider);
    }

    function _authorizeUpgrade(address) internal view override restricted {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             Utils                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    modifier restricted() {
        LibAccessGuard.checkRestricted(s_factory.i_accessManager());
        _;
    }

    modifier checkTwoCrypto(TwoCrypto twoCrypto) {
        ContractValidation.checkTwoCrypto(s_factory, twoCrypto.unwrap(), s_twoCryptoDeployer);
        _;
    }

    modifier checkPrincipalToken(PrincipalToken principalToken) {
        ContractValidation.checkPrincipalToken(s_factory, address(principalToken));
        _;
    }
}
