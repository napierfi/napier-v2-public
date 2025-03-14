// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {CustomConversionResolver} from "../../../src/modules/resolvers/CustomConversionResolver.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626Decimals} from "../../mocks/MockERC4626.sol";
import {Errors} from "../../../src/Errors.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

contract CustomConversionResolverTest is Test {
    CustomConversionResolver public resolver;
    MockERC20 public asset;
    address public vault;
    address public alice = makeAddr("alice");

    uint8 constant ASSET_DECIMALS = 6;
    uint8 constant VAULT_DECIMALS = 18;
    bytes4 constant CONVERT_TO_ASSETS_FN = bytes4(keccak256("convertToAssets(uint256)"));

    function setUp() public {
        asset = new MockERC20(ASSET_DECIMALS);
        vault = makeAddr("vault");
        vm.mockCall(vault, abi.encodeWithSelector(ERC20.decimals.selector), abi.encode(VAULT_DECIMALS));
        resolver = new CustomConversionResolver(address(vault), address(asset), CONVERT_TO_ASSETS_FN);
    }

    function test_Constructor() public view {
        assertEq(resolver.asset(), address(asset));
        assertEq(resolver.target(), address(vault));
        assertEq(resolver.assetDecimals(), ASSET_DECIMALS);
        assertEq(resolver.decimals(), VAULT_DECIMALS);
        assertEq(resolver.label(), "CustomConversionResolver");
    }

    function test_FuzzScaleWithDifferentDecimals(uint8 assetDecimals, uint256 amount, uint8 vaultDecimals) public {
        assetDecimals = uint8(bound(assetDecimals, 6, 18));
        vaultDecimals = uint8(bound(vaultDecimals, 6, 18));
        amount = bound(amount, 1, type(uint256).max / 1e18);

        MockERC20 assetDec = new MockERC20(assetDecimals);
        MockERC4626Decimals vaultDec = new MockERC4626Decimals(assetDec, false, vaultDecimals);

        CustomConversionResolver resolverDec =
            new CustomConversionResolver(address(vaultDec), address(assetDec), CONVERT_TO_ASSETS_FN);
        uint256 scale = resolverDec.scale();

        deal(address(assetDec), alice, amount);

        vm.startPrank(alice);
        assetDec.approve(address(vaultDec), amount);
        vaultDec.deposit(amount, alice);
        vm.stopPrank();

        uint256 calculatedTotalAssets = (scale * vaultDec.totalSupply()) / 1e18;

        assertApproxEqRel(calculatedTotalAssets, vaultDec.totalAssets(), 1e15, "totalAssets mismatch");
    }

    function test_Revert_Scale() public {
        bytes memory revertData = abi.encodeWithSelector(Errors.Resolver_ConversionFailed.selector);
        vm.mockCallRevert(address(vault), abi.encodeWithSelector(CONVERT_TO_ASSETS_FN), revertData);

        vm.expectRevert(Errors.Resolver_ConversionFailed.selector);
        resolver.scale();
    }
}
