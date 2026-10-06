// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";

import {ChainlinkResolver} from "../../../src/modules/resolvers/ChainlinkResolver.sol";

import {AggregatorV3Interface} from "../../../src/lens/external/AggregatorV3Interface.sol";
import {Errors} from "../../../src/Errors.sol";

contract ChainlinkResolverTest is Test {
    ChainlinkResolver public resolver;
    address public vault;
    MockERC20 public asset;
    address public priceFeed;
    address public alice = makeAddr("alice");

    uint8 constant ASSET_DECIMALS = 6;
    uint8 constant VAULT_DECIMALS = 18;

    function setUp() public {
        asset = new MockERC20(ASSET_DECIMALS);
        vault = makeAddr("vault");
        vm.mockCall(vault, abi.encodeWithSelector(ERC20.decimals.selector), abi.encode(VAULT_DECIMALS));
        priceFeed = makeAddr("priceFeed");
        resolver = new ChainlinkResolver(address(vault), address(asset), address(priceFeed));
    }

    function test_Constructor() public view {
        assertEq(resolver.asset(), address(asset));
        assertEq(resolver.target(), address(vault));
        assertEq(resolver.assetDecimals(), ASSET_DECIMALS);
        assertEq(resolver.decimals(), VAULT_DECIMALS);
        assertEq(resolver.label(), "ChainlinkResolver");
    }

    function test_Revert_Constructor_ZeroVault() public {
        vm.expectRevert(Errors.Resolver_ZeroAddress.selector);
        new ChainlinkResolver(address(0), address(asset), address(priceFeed));
    }

    function test_Revert_Constructor_ZeroAsset() public {
        vm.expectRevert(Errors.Resolver_ZeroAddress.selector);
        new ChainlinkResolver(address(vault), address(0), address(priceFeed));
    }

    function test_Revert_Constructor_ZeroPriceFeed() public {
        vm.expectRevert(Errors.Resolver_ZeroAddress.selector);
        new ChainlinkResolver(address(vault), address(asset), address(0));
    }

    function test_Scale_MockPriceFeed_1() public {
        uint8 mockDecimals = 8;
        int256 mockPrice = 1e8;

        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
            abi.encode(mockDecimals)
        );

        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, mockPrice, 0, 0, 0)
        );

        // For USDC with 6 decimals and price feed with 8 decimals
        // We expect: price * i_offset / 10^(8-6)
        // = 100000000 * 1 / 100 = 1000000 (which is $1 with 6 decimals)
        uint256 expectedScale = 1000000;
        assertEq(resolver.scale(), expectedScale, "Scale should be $1 with 6 decimals");
    }

    function test_Scale_MockPriceFeed_2() public {
        asset = new MockERC20(15);
        vault = address(new MockERC20(15));
        resolver = new ChainlinkResolver(address(vault), address(asset), address(priceFeed));

        uint8 mockDecimals = 6;
        int256 mockPrice = 1.1e6;

        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
            abi.encode(mockDecimals)
        );

        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, mockPrice, 0, 0, 0)
        );

        // For asset with 15 decimals and price feed with 6 decimals
        // We expect: price * i_offset * 10^(15-6)
        // = 1.1e6 * 10**3 * 10^9 = 1.1e18 (which is $1.1 with 18 decimals)
        uint256 expectedScale = 1.1e18;
        assertEq(resolver.scale(), expectedScale, "Scale should be $1.1 with 18 decimals");
        assertApproxEqAbs(resolver.scale() * 1e15 / 1e18, 1.1e15, 10, "shares * scale / 1e18 ~= assets");
    }

    function test_Revert_Scale_NegativePrice() public {
        vm.mockCall(address(priceFeed), abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(8));

        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, -1, 0, 0, 0)
        );

        vm.expectRevert(Errors.Resolver_ConversionFailed.selector);
        resolver.scale();
    }

    function test_Revert_Scale_ZeroPrice() public {
        vm.mockCall(address(priceFeed), abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(8));

        vm.mockCall(
            address(priceFeed),
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, 0, 0, 0, 0)
        );

        vm.expectRevert(Errors.Resolver_ConversionFailed.selector);
        resolver.scale();
    }

    function test_FuzzScaleWithDifferentDecimals(uint8 assetDecimals, uint8 vaultDecimals) public {
        assetDecimals = uint8(bound(assetDecimals, 6, 18));
        vaultDecimals = uint8(bound(vaultDecimals, 6, 18));

        uint8 priceFeedDecimals = 8;
        uint256 price = 1e8;

        MockERC20 assetDec = new MockERC20(assetDecimals);

        MockERC4626 vaultDec = new MockERC4626(assetDec, false);

        address priceFeedDec = makeAddr("priceFeedDec");

        vm.mockCall(
            priceFeedDec, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(priceFeedDecimals)
        );

        vm.mockCall(
            priceFeedDec,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, int256(price), 0, 0, 0)
        );

        ChainlinkResolver resolverDec = new ChainlinkResolver(address(vaultDec), address(assetDec), priceFeedDec);

        uint256 scale = resolverDec.scale();

        uint256 depositAmount = 10 ** assetDecimals;
        deal(address(assetDec), alice, depositAmount);

        vm.startPrank(alice);
        assetDec.approve(address(vaultDec), depositAmount);
        vaultDec.deposit(depositAmount, alice);
        vm.stopPrank();

        uint256 calculatedTotalAssets = (scale * vaultDec.totalSupply()) / 1e18;

        assertApproxEqAbs(calculatedTotalAssets, vaultDec.totalAssets(), 100, "totalAssets mismatch");
    }
}
