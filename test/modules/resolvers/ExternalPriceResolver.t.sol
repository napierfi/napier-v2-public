// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/src/Test.sol";
import {ExternalPriceResolver} from "../../../src/modules/resolvers/ExternalPriceResolver.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Errors} from "../../../src/Errors.sol";

contract ExternalPriceResolverTest is Test {
    ExternalPriceResolver public resolver;
    address public vault;
    MockERC20 public asset;
    address public priceFeed;

    uint8 constant ASSET_DECIMALS = 6;
    uint8 constant VAULT_DECIMALS = 18;
    bytes4 constant GET_PRICE_FN = bytes4(keccak256("getPrice()"));

    function setUp() public {
        asset = new MockERC20(ASSET_DECIMALS);
        vault = makeAddr("vault");
        vm.mockCall(vault, abi.encodeWithSelector(ERC20.decimals.selector), abi.encode(VAULT_DECIMALS));
        priceFeed = makeAddr("priceFeed");
        resolver = new ExternalPriceResolver(address(vault), address(asset), address(priceFeed), GET_PRICE_FN);
    }

    function test_Constructor() public view {
        assertEq(resolver.asset(), address(asset));
        assertEq(resolver.target(), address(vault));
        assertEq(resolver.assetDecimals(), ASSET_DECIMALS);
        assertEq(resolver.decimals(), VAULT_DECIMALS);
        assertEq(resolver.label(), "ExternalPriceResolver");
    }

    function test_Scale() public {
        vm.mockCall(address(priceFeed), abi.encodeWithSelector(GET_PRICE_FN), abi.encode(1.5e18));

        uint256 expectedScale = 1.5e18; // 1.5 * 10^(18 + 6 - 18)
        assertEq(resolver.scale(), expectedScale);
    }

    function testFuzz_ScaleWithDifferentDecimals(uint256 price, uint8 decimals) public {
        decimals = uint8(bound(decimals, 6, 18));
        price = bound(price, 0, type(uint256).max / 1e18);
        address vaultDec = makeAddr("vaultDec");
        vm.mockCall(vaultDec, abi.encodeWithSelector(ERC20.decimals.selector), abi.encode(decimals));
        ExternalPriceResolver resolverDec =
            new ExternalPriceResolver(address(vaultDec), address(asset), address(priceFeed), GET_PRICE_FN);
        vm.mockCall(address(priceFeed), abi.encodeWithSelector(GET_PRICE_FN), abi.encode(price));

        uint256 expectedScale = price * 10 ** (18 - decimals);
        assertEq(resolverDec.scale(), expectedScale);
    }

    function test_Revert_Scale() public {
        bytes memory revertData = abi.encodeWithSelector(Errors.Resolver_ConversionFailed.selector);
        vm.mockCallRevert(address(priceFeed), abi.encodeWithSelector(GET_PRICE_FN), revertData);

        vm.expectRevert(Errors.Resolver_ConversionFailed.selector);
        resolver.scale();
    }
}
