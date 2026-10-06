// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {UniswapV4Base} from "test/UniswapV4Base.t.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {AggregatorV3Interface} from "src/lens/external/AggregatorV3Interface.sol";
import {FeedRegistry, Currency} from "src/lens/external/FeedRegistry.sol";

import {AssetPriceProvider} from "src/lens/AssetPriceProvider.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

// Dummy contract to get a non-zero code length address for vm.mockCall targets
contract Dummy {}

// Phase 1: Foundation Tests
// - Basic setup and simple behavior checks following Lens.t.sol patterns
abstract contract AssetPriceProviderTest is UniswapV4Base {
    address mockPriceOracle;
    address mockFeedRegistry;
    AssetPriceProvider provider;

    // Sample price fixtures (Chainlink-style: 8 decimals)
    uint256 constant USD_1E8 = 1e8; // $1.00 in 8 decimals
    uint256 constant USD_3000E8 = 3_000e8; // $3,000 in 8 decimals

    function setUp() public virtual override {
        super.setUp();

        mockPriceOracle = address(new Dummy());
        mockFeedRegistry = address(new Dummy());

        // Deploy provider proxy with immutable args (factory, weth). WETH is unused in provider.
        address impl = address(new AssetPriceProvider());
        provider = AssetPriceProvider(LibClone.deployERC1967I(impl, abi.encode(factory)));
        provider.initialize(address(0));

        // Label for clarity in traces
        vm.label(address(provider), "AssetPriceProvider");
        vm.label(address(mockFeedRegistry), "MockFeedRegistry");
        vm.label(address(mockPriceOracle), "MockPriceOracle");
    }

    // Helpers: mock aggregator and feed registry calls
    function mockCallPriceOracle(address oracle, uint256 decimals, int256 answer) internal {
        vm.mockCall(oracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(decimals));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(0), answer, uint256(0), uint256(0), uint80(0))
        );
    }

    function mockCallFeedRegistry(address registry, uint256 decimals, int256 answer) internal {
        // Intentionally mocking with only selector prefix, matching Lens.t.sol style
        vm.mockCall(registry, abi.encodeWithSelector(FeedRegistry.decimals.selector), abi.encode(decimals));
        vm.mockCall(
            registry,
            abi.encodeWithSelector(FeedRegistry.latestRoundData.selector),
            abi.encode(uint80(0), answer, uint256(0), uint256(0), uint80(0))
        );
    }

    function grantProviderAdminPermissions() internal {
        // Grant admin DEV_ROLE and allow calling provider setters via AccessManager
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = provider.setPriceOracle.selector;
        selectors[1] = provider.setFeedRegistry.selector;
        _grantRoles(napierAccessManager, admin, admin, address(provider), selectors, Constants.DEV_ROLE);
    }
}

// Setter behavior and access control
contract AssetPriceProviderSetterTest is AssetPriceProviderTest {
    function test_SetPriceOracle() public {
        // Arrange
        grantProviderAdminPermissions();
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;

        // Use oracle price of $1.00 and ensure FeedRegistry is not used
        mockCallPriceOracle(mockPriceOracle, 8, int256(uint256(USD_1E8)));

        // Act
        vm.prank(admin);
        provider.setPriceOracle(currencies, oracles);
        assertEq(address(provider.priceOracle(currencies[0])), oracles[0], "Price oracle address mismatch");

        uint256 price = provider.getPriceUSDInWad(address(base));

        // Assert
        assertEq(price, 1e18, "Price should be $1.00 in WAD");
    }

    function test_SetPriceOracle_RevertWhen_NotAuthorized() public {
        // Arrange
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;

        // Act + Assert
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        provider.setPriceOracle(currencies, oracles);
    }

    function test_SetPriceOracle_RevertWhen_LengthMismatch() public {
        // Arrange
        grantProviderAdminPermissions();
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = Currency.wrap(address(base));
        currencies[1] = Currency.wrap(address(target));

        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;

        // Act + Assert
        vm.prank(admin);
        vm.expectRevert(Errors.Lens_LengthMismatch.selector);
        provider.setPriceOracle(currencies, oracles);
    }

    function test_SetFeedRegistry() public {
        // Arrange
        grantProviderAdminPermissions();
        vm.prank(admin);
        provider.setFeedRegistry(mockFeedRegistry);
        assertEq(address(provider.feedRegistry()), mockFeedRegistry, "Feed registry address mismatch");
    }

    function test_SetFeedRegistry_RevertWhen_NotAuthorized() public {
        // Act + Assert
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        provider.setFeedRegistry(mockFeedRegistry);
    }

    function test_Upgrade_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        provider.upgradeToAndCall(makeAddr("newImpl"), "");
    }

    function test_Initialize_RevertWhen_Reinitialized() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        provider.initialize(mockFeedRegistry);
    }
}

// Oracle lookup and conversion behavior
contract AssetPriceProviderOracleTest is AssetPriceProviderTest {
    function test_When_OracleSet() public {
        // Arrange
        grantProviderAdminPermissions();
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;
        mockCallPriceOracle(mockPriceOracle, 8, int256(uint256(USD_1E8))); // $1.00
        vm.prank(admin);
        provider.setPriceOracle(currencies, oracles);

        // Act
        (bool ok, uint256 price) = provider.tryGetPriceUSDInWad(address(base));

        // Assert
        assertTrue(ok, "ok must be true when oracle set and valid");
        assertEq(price, 1e18, "price should be $1.00 in WAD via oracle");
    }

    function test_When_RegistrySet() public {
        // Arrange
        grantProviderAdminPermissions();
        vm.prank(admin);
        provider.setFeedRegistry(mockFeedRegistry);
        mockCallFeedRegistry(mockFeedRegistry, 8, int256(uint256(USD_3000E8))); // $3,000

        // Act
        (bool ok, uint256 price) = provider.tryGetPriceUSDInWad(address(base));

        // Assert
        assertTrue(ok, "ok must be true when registry provides a price");
        assertEq(price, 3000e18, "price should be $3,000 in WAD via registry");
    }

    function test_FallbackToFeedRegistry_When_OracleUnset() public {
        // Arrange
        grantProviderAdminPermissions();
        vm.prank(admin);
        provider.setFeedRegistry(mockFeedRegistry);
        mockCallFeedRegistry(mockFeedRegistry, 8, int256(uint256(USD_3000E8))); // $3,000

        // The oracle misbehaves, but the feed registry is still available
        grantProviderAdminPermissions();
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;
        mockCallPriceOracle(mockPriceOracle, 8, -1); // negative price
        vm.prank(admin);
        provider.setPriceOracle(currencies, oracles);

        // Act
        uint256 price = provider.getPriceUSDInWad(address(base));

        // Assert
        assertEq(price, 3000e18, "Price should be $3,000 in WAD via FeedRegistry");
    }

    function test_ConvertToUSDOrZero() public {
        // Arrange
        grantProviderAdminPermissions();
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;
        mockCallPriceOracle(mockPriceOracle, 8, int256(uint256(USD_1E8))); // $1.00
        vm.prank(admin);
        provider.setPriceOracle(currencies, oracles);

        // Act: base has 6 decimals; 3e6 units should be $3,000 => 3e18 WAD
        uint256 usd = provider.convertToUSDWadOrZero(3e6, address(base));

        // Assert
        assertEq(usd, 3e18, "3 units of base (6dp) should equal $3,000 in WAD");
    }

    function test_RevertWhen_OracleAndFeedNotSet() public {
        // Arrange: provider defaults to no oracle and no feed registry
        vm.expectRevert(Errors.Lens_PriceFeedNotFound.selector);
        provider.getPriceUSDInWad(address(base));

        (bool ok, uint256 price) = provider.tryGetPriceUSDInWad(address(base));
        assertFalse(ok, "ok must be false when no feeds available");
        assertEq(price, 0, "price must be zero");
    }

    function test_RevertWhen_NegativePrice() public {
        // Case 1: FeedRegistry negative answer should revert
        grantProviderAdminPermissions();
        vm.prank(admin);
        provider.setFeedRegistry(mockFeedRegistry);
        mockCallFeedRegistry(mockFeedRegistry, 8, -1);
        vm.expectRevert(Errors.Lens_PriceFeedNotFound.selector);
        provider.getPriceUSDInWad(address(base));

        (bool ok, uint256 price) = provider.tryGetPriceUSDInWad(address(base));
        assertFalse(ok, "ok must be false when no feeds available");
        assertEq(price, 0, "price must be zero");

        // Case 2: No feed, oracle negative answer should revert
        vm.prank(admin);
        provider.setFeedRegistry(address(0));
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = mockPriceOracle;
        vm.prank(admin);
        provider.setPriceOracle(currencies, oracles);
        mockCallPriceOracle(mockPriceOracle, 8, -1);
        vm.expectRevert(Errors.Lens_PriceFeedNotFound.selector);
        provider.getPriceUSDInWad(address(base));

        (ok, price) = provider.tryGetPriceUSDInWad(address(base));
        assertFalse(ok, "ok must be false when no feeds available");
        assertEq(price, 0, "price must be zero");
    }
}
