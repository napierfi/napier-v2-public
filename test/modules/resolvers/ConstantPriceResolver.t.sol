// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/src/Test.sol";
import {console} from "forge-std/src/console.sol";
import {ConstantPriceResolver} from "../../../src/modules/resolvers/ConstantPriceResolver.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {Errors} from "../../../src/Errors.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

contract ConstantPriceResolverTest is Test {
    ConstantPriceResolver public resolver;
    MockERC4626 public vault;
    MockERC20 public asset;
    address public alice = makeAddr("alice");

    uint8 constant ASSET_DECIMALS = 6;
    uint8 constant VAULT_DECIMALS = 18;

    function setUp() public {
        asset = new MockERC20(ASSET_DECIMALS);
        vault = new MockERC4626(asset, true);
        resolver = new ConstantPriceResolver(address(vault), address(asset));
    }

    function test_Constructor() public view {
        assertEq(resolver.asset(), address(asset));
        assertEq(resolver.target(), address(vault));
        assertEq(resolver.assetDecimals(), ASSET_DECIMALS);
        assertEq(resolver.decimals(), VAULT_DECIMALS);
        assertEq(resolver.label(), "ConstantPriceResolver");
    }

    function test_Revert_Constructor_ZeroVault() public {
        vm.expectRevert(Errors.Resolver_ZeroAddress.selector);
        new ConstantPriceResolver(address(0), address(asset));
    }

    function test_Revert_Constructor_ZeroAsset() public {
        vm.expectRevert(Errors.Resolver_ZeroAddress.selector);
        new ConstantPriceResolver(address(vault), address(0));
    }

    function test_FuzzScaleWithDifferentDecimals(uint8 assetDecimals, uint256 amount) public {
        assetDecimals = uint8(bound(assetDecimals, 6, 18));
        amount = bound(amount, 1, type(uint256).max / 1e18);

        MockERC20 assetDec = new MockERC20(assetDecimals);
        MockERC4626 vaultDec = new MockERC4626(assetDec, true);

        ConstantPriceResolver resolverDec = new ConstantPriceResolver(address(vaultDec), address(assetDec));
        uint256 scale = resolverDec.scale();

        deal(address(assetDec), alice, amount);

        vm.startPrank(alice);
        assetDec.approve(address(vaultDec), amount);
        vaultDec.deposit(amount, alice);
        vm.stopPrank();

        uint256 calculatedTotalAssets = (scale * vaultDec.totalSupply()) / 1e18;

        assertApproxEqRel(calculatedTotalAssets, vaultDec.totalAssets(), 1e15, "totalAssets mismatch");
    }

    function test_Scale() public view {
        assertEq(vault.convertToAssets(1e18), 1e18 * resolver.scale() / 1e18, "convertToAssets mismatch");
    }
}
