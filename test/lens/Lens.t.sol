// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {Ownable} from "solady/src/auth/Ownable.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {AggregatorV3Interface} from "src/lens/external/AggregatorV3Interface.sol";
import {FeedRegistry} from "src/lens/external/FeedRegistry.sol";

import {Lens, Currency} from "src/lens/Lens.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract Dummy {}

abstract contract LensTest is TwoCryptoZapAMMTest {
    address mockPriceOracle;
    address mockFeedRegistry;
    Lens lens;

    function mockCallPriceOracle(address oracle, uint256 decimals, int256 answer) public {
        vm.mockCall(oracle, abi.encodeWithSelector(AggregatorV3Interface.decimals.selector), abi.encode(decimals));
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(0, answer, 0, 0, 0)
        );
    }

    function mockCallFeedRegistry(address feedRegistry, uint256 decimals, int256 answer) public {
        vm.mockCall(feedRegistry, abi.encodeWithSelector(FeedRegistry.decimals.selector), abi.encode(decimals));
        vm.mockCall(
            feedRegistry, abi.encodeWithSelector(FeedRegistry.latestRoundData.selector), abi.encode(0, answer, 0, 0, 0)
        );
    }

    function setUp() public virtual override {
        super.setUp();

        mockPriceOracle = address(new Dummy());
        mockFeedRegistry = address(new Dummy());

        // https://etherscan.io/address/0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419
        // answer: 308958804930
        mockCallFeedRegistry(mockFeedRegistry, 8, 308958804930); // ETH/USD price

        Lens implementation = new Lens();
        lens = Lens(LibClone.deployERC1967(address(implementation)));
        lens.initialize(factory, mockFeedRegistry, address(twocryptoDeployer), address(weth), admin);

        _label();
        vm.label(address(lens), "Lens");
        vm.label(address(mockFeedRegistry), "MockFeedRegistry");
        vm.label(address(mockPriceOracle), "MockPriceOracle");

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: 30009218913
        });
        setUpVault(init);
    }
}

contract LensSetterTest is LensTest {
    function test_SetPriceOracle() public {
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));

        address[] memory oracles = new address[](1);
        oracles[0] = makeAddr("oracle");

        vm.prank(admin);
        lens.setPriceOracle(currencies, oracles);
        assertEq(address(lens.s_priceOracles(currencies[0])), oracles[0], "Price oracle address mismatch");
    }

    function test_SetPriceOracle_RevertWhen_NotOwner() public {
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));

        address[] memory oracles = new address[](1);
        oracles[0] = makeAddr("oracle");

        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        lens.setPriceOracle(currencies, oracles);
    }

    function test_SetFeed() public {
        address newFeed = makeAddr("newFeed");
        vm.prank(admin);
        lens.setFeedRegistry(newFeed);
        assertEq(address(lens.s_feedRegistry()), newFeed, "Feed registry address mismatch");
    }

    function test_SetFeed_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        lens.setFeedRegistry(makeAddr("newFeed"));
    }

    function test_SetFeed_RevertWhen_LengthMismatch() public {
        Currency[] memory currencies = new Currency[](2);
        currencies[0] = Currency.wrap(address(base));
        currencies[1] = Currency.wrap(address(target));

        address[] memory oracles = new address[](1);
        oracles[0] = makeAddr("oracle");

        vm.prank(admin);
        vm.expectRevert(Errors.Lens_LengthMismatch.selector);
        lens.setPriceOracle(currencies, oracles);
    }

    function test_Upgrade_RevertWhen_NotOwner() public {
        vm.prank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        lens.upgradeToAndCall(makeAddr("newImpl"), "");
    }
}

contract LensOracleTest is LensTest {
    function test_ReturnZero_When_OracleIsNotSet() public {
        // Remove both feed registry and price oracle
        vm.prank(admin);
        lens.setFeedRegistry(address(0));

        // Remove price oracle
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = address(0);

        vm.prank(admin);
        lens.setPriceOracle(currencies, oracles);

        assertEq(lens.getPriceUSDInWad(address(base)), 0, "price should be 0");
    }

    function test_ReturnZero_When_InvalidPrice_1() public {
        mockCallFeedRegistry(mockFeedRegistry, 8, -1); // Negative price
        assertEq(lens.getPriceUSDInWad(address(base)), 0, "price should be 0");
    }

    function test_ReturnZero_When_InvalidPrice_2() public {
        // Remove feed registry
        vm.prank(admin);
        lens.setFeedRegistry(address(0));

        // Set price oracle
        Currency[] memory currencies = new Currency[](1);
        currencies[0] = Currency.wrap(address(base));
        address[] memory oracles = new address[](1);
        oracles[0] = address(mockPriceOracle);

        vm.prank(admin);
        lens.setPriceOracle(currencies, oracles);

        mockCallPriceOracle(mockPriceOracle, 8, -1); // Negative price
        assertEq(lens.getPriceUSDInWad(address(base)), 0, "price should be 0");
    }
}

contract LensPriceDataTest is LensTest {
    /// @dev It should NOT revert even if expired
    function test_NotRevert_WhenExpired() public {
        assertEq(address(lens.s_feedRegistry()), address(mockFeedRegistry), "feed registry should be set");

        vm.warp(expiry + 1);
        lens.getPriceData(twocrypto);
    }

    function test_WhenNotExpired() public {
        assertEq(address(lens.s_feedRegistry()), address(mockFeedRegistry), "feed registry should be set");

        // Example
        // - PT expires in 3 months=1/4 years
        // - PT price in share is 0.972
        // - 1 Underlying token is 1 asset
        uint256 scale = 1e18;
        uint256 ptPriceInShare = 0.972e18;
        vm.warp(expiry - (365 days / 4));
        vm.mockCall(address(resolver), abi.encodeWithSelector(resolver.scale.selector), abi.encode(scale));
        vm.mockCall(twocrypto.unwrap(), abi.encodeWithSignature("price_oracle()"), abi.encode(ptPriceInShare));

        Lens.PriceData memory data = lens.getPriceData(twocrypto);
        assertApproxEqRel(data.impliedAPY, 0.1203e18, 0.0001e18, "implied rate should be 12.03%");
    }

    function test_WhenExpired() public {
        vm.warp(expiry);

        Lens.PriceData memory data = lens.getPriceData(twocrypto);
        assertEq(data.impliedAPY, 0);
    }
}
