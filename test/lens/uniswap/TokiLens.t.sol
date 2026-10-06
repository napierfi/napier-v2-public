// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Currency as OracleCurrency} from "src/lens/external/FeedRegistry.sol";

import {TokiQuoterTest} from "./TokiQuoter.t.sol";

import {ConversionLib} from "src/lens/twocrypo/ConversionLib.sol";

import {AggregatorV3Interface} from "src/lens/external/AggregatorV3Interface.sol";
import {AssetPriceProvider} from "src/lens/AssetPriceProvider.sol";
import {TokiLens} from "src/lens/uniswap/TokiLens.sol";
import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TokiPoolToken} from "src/tokens/TokiPoolToken.sol";
import {FeeModule} from "src/modules/FeeModule.sol";
import {PoolFeeModule} from "src/modules/PoolFeeModule.sol";
import {FeePcts, FeePctsPool} from "src/Types.sol";
import "src/Types.sol"; // bring module index constants into scope
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

// Dummy contract to produce a code-bearing address for vm.mockCall
contract Dummy {}

// Base test suite wiring up provider + lens on top of the existing quoter + pool setup
contract TokiLensTest is TokiQuoterTest {
    AssetPriceProvider provider;
    TokiLens lens;

    // Simple USD feed
    uint256 constant USD_3000E8 = 3_000e8; // $3,000 in 8 decimals
    address mockOracle;

    function setUp() public virtual override {
        super.setUp();

        // Deploy AssetPriceProvider proxy with immutable args (factory)
        address priceProviderImplementation = address(new AssetPriceProvider());
        provider = AssetPriceProvider(LibClone.deployERC1967I(priceProviderImplementation, abi.encode(factory)));
        provider.initialize(address(0));

        // Deploy TokiLens proxy and initialize
        address lensImplementation = address(new TokiLens());
        lens = TokiLens(LibClone.deployERC1967I(lensImplementation, abi.encode(factory)));
        lens.initialize(address(provider), address(quoter));

        // Mock price oracle to return $3,000
        mockOracle = address(new Dummy());
        _grantProviderAdminPermissions();
        _setOracleFor(address(base), mockOracle, /*decimals=*/ 8, int256(uint256(USD_3000E8)));

        // Labels for cleaner traces
        vm.label(address(provider), "AssetPriceProvider");
        vm.label(address(lens), "TokiLens");
        vm.label(mockOracle, "MockOracle");
    }

    function _grantProviderAdminPermissions() internal {
        // Allow admin to call provider setters through AccessManager
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = provider.setPriceOracle.selector;
        selectors[1] = provider.setFeedRegistry.selector;
        _grantRoles(napierAccessManager, admin, admin, address(provider), selectors, Constants.DEV_ROLE);
    }

    function _setOracleFor(address asset, address oracle, uint256 decimals, int256 answer) internal {
        // Mock Chainlink Aggregator interface
        vm.mockCall(oracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(decimals));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), answer, uint256(0), uint256(0), uint80(0))
        );

        // Register the oracle in provider
        address[] memory oracles = new address[](1);
        oracles[0] = oracle;
        OracleCurrency[] memory currencies = new OracleCurrency[](1);
        currencies[0] = OracleCurrency.wrap(asset);
        vm.prank(admin);
        provider.setPriceOracle(currencies, oracles);
    }

    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    /*                            Tests                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_GetTrancheData() public view {
        // Act
        TokiLens.TrancheData memory data = lens.getTrancheData(principalToken);

        // Assert — addresses
        assertEq(data.target, address(target), "target mismatch");
        assertEq(data.asset, address(base), "asset mismatch");

        // Assert — supplies
        assertEq(data.ptTotalSupply, principalToken.totalSupply(), "PT totalSupply mismatch");
        assertEq(data.ytTotalSupply, principalToken.i_yt().totalSupply(), "YT totalSupply mismatch");

        // Assert — fees match module getters exactly
        FeePcts expectedFees = FeeModule(factory.moduleFor(address(principalToken), FEE_MODULE_INDEX)).getFeePcts();
        FeePctsPool expectedPoolFees =
            PoolFeeModule(factory.moduleFor(address(principalToken), POOL_FEE_MODULE_INDEX)).getFeePcts();
        assertEq(FeePcts.unwrap(data.feePcts), FeePcts.unwrap(expectedFees), "feePcts mismatch");
        assertEq(FeePctsPool.unwrap(data.poolFeeModule), FeePctsPool.unwrap(expectedPoolFees), "pool fee pct mismatch");

        // Assert — deposit caps default to max (no cap configured in this setup)
        assertEq(data.depositCapInShare, type(uint256).max, "share cap should be max");
        assertEq(data.depositCapInAsset, type(uint256).max, "asset cap should be max");
        assertEq(data.depositCapInUSD, type(uint256).max, "USD cap should be max");
    }

    function test_GetTrancheData_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        lens.getTrancheData(PrincipalToken(address(randomToken)));
    }

    function test_GetTVL() public {
        // Arrange 1: zero-liquidity
        TokiLens.TVLData memory zeroTvl = lens.getTVL(TokiPoolToken(pool));
        assertEq(zeroTvl.poolTVLInShare, 0, "pool TVL share should start at zero");
        assertEq(zeroTvl.poolTVLInAsset, 0, "pool TVL asset should start at zero");
        assertEq(zeroTvl.poolTVLInUSD, 0, "pool TVL USD should start at zero");

        // Arrange 2: add initial liquidity using helper
        _addInitialLiquidity(chika, chika);

        TokiLens.TVLData memory tvl = lens.getTVL(TokiPoolToken(pool));
        // Assert — pool values should be positive and internally consistent
        assertGt(tvl.poolTVLInShare, 0, "pool TVL share should be > 0 after liquidity");
        uint256 scale = principalToken.i_resolver().scale();
        uint256 expectedAssets = tvl.poolTVLInShare * scale / 1e18;
        assertEq(tvl.poolTVLInAsset, expectedAssets, "pool share->asset conversion mismatch");
        uint256 expectedUSD = expectedAssets * 1e18 / 10 ** base.decimals() * USD_3000E8 / 1e8;
        assertEq(tvl.poolTVLInUSD, expectedUSD, "USD conversion mismatch");
    }

    function test_GetTVL_RevertWhen_BadPool() public {
        vm.expectRevert(Errors.BadTokiPool.selector);
        lens.getTVL(TokiPoolToken(address(randomToken)));
    }

    function test_GetPriceData_1() public view {
        TokiLens.PriceData memory data = lens.getPriceData(TokiPoolToken(pool));
        // scale from resolver and $3,000 USD price mocked
        assertEq(data.scale, principalToken.i_resolver().scale(), "scale mismatch");
        assertEq(data.assetPriceInUSD, USD_3000E8 * 1e10, "asset price USD");
    }

    function test_GetPriceData_2() public {
        _addInitialLiquidity(chika, chika);

        TokiLens.PriceData memory data = lens.getPriceData(TokiPoolToken(pool));

        assertGt(data.ptPriceInShare, 0, "pt share price");
        assertGt(data.ytPriceInShare, 0, "yt share price");
        assertGt(data.lpPriceInShare, 0, "lp share price");

        // PT + YT ~= 1 asset (in shares) using inverse scale with decimals normalization
        uint8 assetDecimals = base.decimals();
        uint256 assetPriceInShareWad = target.convertToShares(10 ** assetDecimals) * 10 ** (18 - target.decimals());
        assertApproxEqRel(
            data.ptPriceInShare + data.ytPriceInShare,
            assetPriceInShareWad,
            0.0001e18,
            "pt+yt ~= asset price in share units"
        );

        // USD prices match quoter conversions * provider price
        uint256 unit = 10 ** principalToken.decimals();
        uint256 ptAssets = quoter.convertPtToAssets(poolKey, unit);
        uint256 ytAssets = quoter.convertYtToAssets(poolKey, unit);
        uint256 expectedPtUSD = provider.convertToUSDWadOrZero(ptAssets, address(base));
        uint256 expectedYtUSD = provider.convertToUSDWadOrZero(ytAssets, address(base));
        assertEq(data.ptPriceInUSD, expectedPtUSD, "pt USD mismatch");
        assertEq(data.ytPriceInUSD, expectedYtUSD, "yt USD mismatch");

        // Implied APY
        uint256 ptPriceInAssetWad =
            target.convertToAssets(data.ptPriceInShare * 10 ** target.decimals() / 1e18) * 10 ** (18 - base.decimals());
        assertApproxEqRel(
            data.impliedAPY,
            ConversionLib.convertToImpliedAPY({
                priceInAsset: ptPriceInAssetWad,
                timeToExpiry: principalToken.maturity() - block.timestamp
            }),
            0.0001e18,
            "implied APY mismatch"
        );
    }

    function test_GetPriceData_RevertWhen_BadPool() public {
        vm.expectRevert(Errors.BadTokiPool.selector);
        lens.getPriceData(TokiPoolToken(address(randomToken)));
    }

    function test_Setters() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = lens.setPriceProvider.selector;
        selectors[1] = lens.setTokiQuoter.selector;
        _grantRoles(napierAccessManager, admin, admin, address(lens), selectors, Constants.DEV_ROLE);

        vm.startPrank(admin);
        lens.setPriceProvider(address(0xaaa));
        lens.setTokiQuoter(address(0xcafe));
        vm.stopPrank();
    }

    function test_Setters_RevertWhen_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        lens.setPriceProvider(makeAddr("x"));

        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        lens.setTokiQuoter(makeAddr("y"));
    }
}
