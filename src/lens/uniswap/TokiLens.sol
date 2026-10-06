// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

import {PoolKey, Currency} from "@uniswap/v4-core/src/types/PoolKey.sol";

import "../../Types.sol";
import "../../Errors.sol";
import "../../Constants.sol" as Constants;
import {VerifierLensLib} from "../VerifierLensLib.sol";
import {ContractValidation} from "../../utils/ContractValidation.sol";

import {Factory} from "../../Factory.sol";
import {FeeModule} from "../../modules/FeeModule.sol";
import {PoolFeeModule} from "../../modules/PoolFeeModule.sol";
import {VaultInfoResolver} from "../../modules/resolvers/VaultInfoResolver.sol";
import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {TokiPoolToken} from "../../tokens/TokiPoolToken.sol";
import {AssetPriceProvider} from "../AssetPriceProvider.sol";
import {TokiQuoter} from "./TokiQuoter.sol";

import {AccessManaged, AccessManager} from "../../modules/AccessManager.sol";

/// @notice ERC1967I Immutable args: abi.encode(factory)
contract TokiLens is UUPSUpgradeable, Initializable, AccessManaged {
    /// @notice Storage slot for the lens: `cast index-erc7201 napier-v2.toki-lens.storage`
    bytes32 constant TOKI_LENS_STORAGE_SLOT = 0x5ed0bf5bcb70a48c08b08a4c70eb0fe8f1b66df414dd52336479d42fe9f27400;

    struct TokiLensNamespace {
        AssetPriceProvider s_priceProvider;
        TokiQuoter s_tokiQuoter;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address priceProvider, address tokiQuoter) public initializer {
        TokiLensNamespace storage $ = _getStorage();
        $.s_priceProvider = AssetPriceProvider(priceProvider);
        $.s_tokiQuoter = TokiQuoter(tokiQuoter);
    }

    struct TrancheData {
        address target;
        address asset;
        uint256 ptTotalSupply;
        uint256 ytTotalSupply;
        FeePcts feePcts;
        FeePctsPool poolFeeModule;
        uint256 depositCapInShare; // type(uint256).max if no limit
        uint256 depositCapInAsset; // type(uint256).max if no limit
        uint256 depositCapInUSD; // type(uint256).max if no limit
    }

    function getTrancheData(PrincipalToken principalToken)
        public
        view
        checkPrincipalToken(principalToken)
        returns (TrancheData memory data)
    {
        TokiLensNamespace storage $ = _getStorage();
        AssetPriceProvider priceProvider = $.s_priceProvider;

        address asset = address(principalToken.i_asset());

        uint256 depositCapInShare = VerifierLensLib.getDepositCap(principalToken);
        uint256 depositCapInAsset = depositCapInShare < type(uint256).max
            ? _convertSharesToAssets(depositCapInShare, principalToken.i_resolver().scale())
            : type(uint256).max;
        uint256 depositCapInUSD = depositCapInAsset < type(uint256).max
            ? _convertAssetsToUSD(priceProvider, depositCapInAsset, asset)
            : type(uint256).max;

        data = TrancheData({
            target: address(principalToken.underlying()),
            asset: asset,
            ptTotalSupply: principalToken.totalSupply(),
            ytTotalSupply: principalToken.i_yt().totalSupply(),
            feePcts: FeeModule(i_factory().moduleFor(address(principalToken), FEE_MODULE_INDEX)).getFeePcts(),
            poolFeeModule: PoolFeeModule(i_factory().moduleFor(address(principalToken), POOL_FEE_MODULE_INDEX)).getFeePcts(),
            depositCapInShare: depositCapInShare,
            depositCapInAsset: depositCapInAsset,
            depositCapInUSD: depositCapInUSD
        });
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
        int256 impliedAPY; // 5% -> 0.05e18
    }

    /// @dev It can revert if oracle is not set or revert.
    /// @dev It should NOT revert even if expired
    /// @dev It should NOT revert even if LP total supply is 0
    /// @dev It should NOT revert even if PT price is greater than 1 underlying token.
    function getPriceData(TokiPoolToken pool) public view checkPool(pool) returns (PriceData memory data) {
        TokiLensNamespace storage $ = _getStorage();
        TokiQuoter quoter = $.s_tokiQuoter;
        AssetPriceProvider priceProvider = $.s_priceProvider;
        PoolKey memory poolKey = pool.i_poolKey();

        PrincipalToken principalToken = PrincipalToken(Currency.unwrap(poolKey.currency1));
        address asset = address(principalToken.i_asset());

        // Scale
        VaultInfoResolver resolver = principalToken.i_resolver();

        try resolver.scale() returns (uint256 scale) {
            data.scale = scale;
        } catch {
            // Default unit
            data.scale = 10 ** (18 + resolver.assetDecimals() - resolver.decimals());
        }

        // Asset USD price
        try priceProvider.getPriceUSDInWad(asset) returns (uint256 p) {
            data.assetPriceInUSD = p;
        } catch {}

        uint256 underlyingDecimals = ERC20(Currency.unwrap(poolKey.currency0)).decimals();

        // LP price
        uint256 lpUnit = 10 ** ERC20(address(pool)).decimals();
        try quoter.convertLpToUnderlying(poolKey, lpUnit) returns (uint256 p) {
            // Normalize the quote amount to 18 decimals.
            // Safe assumption: underlying decimals is <= 18
            data.lpPriceInShare = _toWad(p, underlyingDecimals);
        } catch {}

        try quoter.convertLpToAssets(poolKey, lpUnit) returns (uint256 p) {
            data.lpPriceInUSD = _convertAssetsToUSD(priceProvider, p, asset);
        } catch {}

        // PT price
        uint256 ptUnit = 10 ** principalToken.decimals();
        try quoter.convertPtToUnderlying(poolKey, ptUnit) returns (uint256 p) {
            data.ptPriceInShare = _toWad(p, underlyingDecimals);
        } catch {}

        try quoter.convertPtToAssets(poolKey, ptUnit) returns (uint256 p) {
            data.ptPriceInUSD = _convertAssetsToUSD(priceProvider, p, asset);
        } catch {}

        // YT price
        try quoter.convertYtToUnderlying(poolKey, ptUnit) returns (uint256 p) {
            data.ytPriceInShare = _toWad(p, underlyingDecimals);
        } catch {}

        try quoter.convertYtToAssets(poolKey, ptUnit) returns (uint256 p) {
            data.ytPriceInUSD = _convertAssetsToUSD(priceProvider, p, asset);
        } catch {}

        // Spot Implied APY
        try quoter.getImpliedRateWad(poolKey) returns (int256 ir) {
            data.impliedAPY = ir;
        } catch {}
    }

    struct TVLData {
        uint256 ptTVLInShare;
        uint256 ptTVLInAsset;
        uint256 ptTVLInUSD;
        uint256 poolTVLInShare;
        uint256 poolTVLInAsset;
        uint256 poolTVLInUSD;
    }

    function getTVL(TokiPoolToken pool) public view checkPool(pool) returns (TVLData memory tvl) {
        TokiLensNamespace storage $ = _getStorage();
        AssetPriceProvider priceProvider = $.s_priceProvider;
        TokiQuoter quoter = $.s_tokiQuoter;

        PoolKey memory poolKey = pool.i_poolKey();
        PrincipalToken pt = PrincipalToken(Currency.unwrap(poolKey.currency1));

        uint256 scale = pt.i_resolver().scale();
        address asset = address(pt.i_asset());

        // PT TVL
        {
            uint256 ptTVLInShare = poolKey.currency0.balanceOf(address(pt));
            uint256 ptTVLInAsset = _convertSharesToAssets(ptTVLInShare, scale);
            uint256 ptTVLInUSD = _convertAssetsToUSD(priceProvider, ptTVLInAsset, asset);

            tvl.ptTVLInShare = ptTVLInShare;
            tvl.ptTVLInAsset = ptTVLInAsset;
            tvl.ptTVLInUSD = ptTVLInUSD;
        }

        // Pool TVL
        {
            uint256 poolTVLInShare;
            try quoter.convertLpToUnderlying(poolKey, pool.totalSupply()) returns (uint256 p) {
                poolTVLInShare = p;
            } catch {}
            uint256 poolTVLInAsset = _convertSharesToAssets(poolTVLInShare, scale);
            uint256 poolTVLInUSD = _convertAssetsToUSD(priceProvider, poolTVLInAsset, asset);

            tvl.poolTVLInShare = poolTVLInShare;
            tvl.poolTVLInAsset = poolTVLInAsset;
            tvl.poolTVLInUSD = poolTVLInUSD;
        }
    }

    function i_accessManager() public view override returns (AccessManager) {
        return i_factory().i_accessManager();
    }

    function i_factory() public view returns (Factory) {
        return abi.decode(LibClone.argsOnERC1967I(address(this)), (Factory));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Permissioned                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setPriceProvider(address provider) public restricted {
        TokiLensNamespace storage $ = _getStorage();
        $.s_priceProvider = AssetPriceProvider(provider);
    }

    function setTokiQuoter(address tokiQuoter) public restricted {
        TokiLensNamespace storage $ = _getStorage();
        $.s_tokiQuoter = TokiQuoter(tokiQuoter);
    }

    function _authorizeUpgrade(address) internal view override restricted {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Conversion                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _convertSharesToAssets(uint256 shares, uint256 scale) internal pure returns (uint256) {
        return (shares * scale) / Constants.WAD;
    }

    function _convertAssetsToUSD(AssetPriceProvider priceProvider, uint256 assets, address asset)
        internal
        view
        returns (uint256)
    {
        return priceProvider.convertToUSDWadOrZero(assets, asset);
    }

    /// @dev Normalize the quote amount to 18 decimals.
    /// @dev Assumption: decimals is <= 18
    function _toWad(uint256 value, uint256 decimals) internal pure returns (uint256) {
        return value * 10 ** (18 - decimals);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             Utils                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getStorage() internal pure returns (TokiLensNamespace storage $) {
        assembly {
            $.slot := TOKI_LENS_STORAGE_SLOT
        }
    }

    /// @dev The check doesn't assert the pool is TokiPool
    modifier checkPool(TokiPoolToken pool) {
        if (i_factory().s_pools(address(pool)) == address(0)) {
            revert Errors.BadTokiPool();
        }
        _;
    }

    modifier checkPrincipalToken(PrincipalToken principalToken) {
        ContractValidation.checkPrincipalToken(i_factory(), address(principalToken));
        _;
    }
}
