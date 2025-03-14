// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {ERC4626WrapperConnector} from "src/modules/connectors/ERC4626WrapperConnector.sol";
import {MockWrapper} from "../../mocks/MockWrapper.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

function into(ERC20 token) pure returns (Token result) {
    result = Token.wrap(address(token));
}

using {into} for MockERC20;
using {into} for MockWETH;
using {into} for MockERC4626;

abstract contract ERC4626WrapperConnectorTest is Test {
    uint256 constant INITIAL_BALANCE = 100 ether;
    Token constant NATIVE_ETH = Token.wrap(Constants.NATIVE_ETH);

    address alice = makeAddr("alice");

    address s_wrapperConnectorImplementation;
    address s_wrapperImplementation;
    ERC4626WrapperConnector s_connector;
    MockWrapper s_wrapper;
    MockERC4626 s_vault;
    MockERC20 s_asset;

    function setUp() public {
        s_wrapperConnectorImplementation = address(new ERC4626WrapperConnector());
        s_wrapperImplementation = address(new MockWrapper());
        (s_asset, s_vault, s_wrapper, s_connector) = deploy();

        vm.startPrank(alice);

        vm.deal(alice, INITIAL_BALANCE);
        // mint assets
        s_asset.mint(alice, INITIAL_BALANCE);
        // mint vault shares
        s_asset.mint(alice, INITIAL_BALANCE);
        s_asset.approve(address(s_vault), type(uint256).max);
        s_vault.deposit(INITIAL_BALANCE, alice);

        vm.label(address(s_asset), "asset");
        vm.label(address(s_vault), "vault");
        vm.label(address(s_connector), "connector");
        vm.label(address(s_wrapper), "wrapper");
    }

    /// @dev This function is meant to be overridden by the derived test contracts
    function deploy()
        internal
        virtual
        returns (MockERC20 asset, MockERC4626 vault, MockWrapper wrapper, ERC4626WrapperConnector connector);

    function test_DepositAsset() public {
        uint256 totalSupply = s_vault.totalSupply();
        uint256 assets = 32898909309023;

        s_asset.approve(address(s_connector), assets);
        uint256 shares = s_connector.deposit(s_asset.into(), assets, alice);

        assertEq(s_vault.totalSupply(), totalSupply + s_vault.previewDeposit(assets), "totalSupply");
        assertEq(s_asset.balanceOf(alice), INITIAL_BALANCE - assets, "asset");
        assertEq(s_wrapper.balanceOf(alice), shares, "vault");
    }

    function test_DepositVault() public {
        uint256 underlyings = 10 ether;

        s_vault.approve(address(s_connector), underlyings);
        uint256 shares = s_connector.deposit(s_vault.into(), underlyings, alice);

        assertEq(shares, underlyings, "shares");
        assertEq(s_wrapper.balanceOf(alice), shares, "shares balance");
    }

    function test_RedeemVault() public {
        uint256 underlyingsIn = 456456578;

        s_vault.approve(address(s_connector), type(uint256).max);
        uint256 shares = s_connector.deposit(s_vault.into(), underlyingsIn, alice);

        uint256 redeemShares = shares / 4;
        s_wrapper.approve(address(s_connector), shares);
        uint256 underlyingsOut = s_connector.redeem(s_vault.into(), redeemShares, alice);

        assertEq(s_vault.balanceOf(alice), INITIAL_BALANCE - underlyingsIn + underlyingsOut, "vault balance");
        assertEq(s_wrapper.balanceOf(alice), shares - redeemShares, "shares balance");
    }

    function test_RedeemAsset() public {
        uint256 underlyingsIn = 90953464565;

        s_vault.approve(address(s_connector), type(uint256).max);
        uint256 shares = s_connector.deposit(s_vault.into(), underlyingsIn, alice);

        uint256 redeemShares = shares / 4;
        s_wrapper.approve(address(s_connector), shares);
        uint256 assetsOut = s_connector.redeem(s_asset.into(), redeemShares, alice);

        assertEq(s_asset.balanceOf(alice), INITIAL_BALANCE + assetsOut, "asset balance");
        assertEq(s_wrapper.balanceOf(alice), shares - redeemShares, "shares balance");
    }

    function test_RevertWhen_InvalidETHAmount() public {
        vm.expectRevert(Errors.WrapperConnector_InvalidETHAmount.selector);
        s_connector.deposit{value: 1 ether}(NATIVE_ETH, 2 ether, alice);
    }

    function test_RevertWhen_UnexpectedETH() public {
        vm.expectRevert(Errors.WrapperConnector_UnexpectedETH.selector);
        s_connector.deposit{value: 1 ether}(s_asset.into(), 1 ether, alice);
    }

    function testFuzz_PreviewDeposit(uint256 index, uint256 amount) public view {
        Token[] memory tokens = s_wrapper.getTokenInList();
        Token token = tokens[index % tokens.length];
        uint256 preview = s_connector.previewDeposit(token, amount);
        uint256 expected = s_wrapper.previewDeposit(token, amount);
        assertEq(preview, expected);
    }

    function testFuzz_PreviewRedeem(uint256 index, uint256 amount) public view {
        Token[] memory tokens = s_wrapper.getTokenInList();
        Token token = tokens[index % tokens.length];
        uint256 preview = s_connector.previewRedeem(token, amount);
        uint256 expected = s_wrapper.previewRedeem(token, amount);
        assertEq(preview, expected);
    }

    function test_getTokenInList() public view {
        Token[] memory tokens = s_connector.getTokenInList();
        Token[] memory expected = s_wrapper.getTokenInList();
        assertEq(abi.encode(tokens), abi.encode(expected));
    }

    function test_getTokenOutList() public view {
        Token[] memory tokens = s_connector.getTokenOutList();
        Token[] memory expected = s_wrapper.getTokenOutList();
        assertEq(abi.encode(tokens), abi.encode(expected));
    }
}

contract ERC4626WrapperConnectorERC20Test is ERC4626WrapperConnectorTest {
    function deploy()
        internal
        override
        returns (MockERC20 asset, MockERC4626 vault, MockWrapper wrapper, ERC4626WrapperConnector connector)
    {
        asset = new MockERC20(18);
        vault = new MockERC4626(ERC20(address(asset)), false);
        bytes memory args0 = abi.encode(vault, Constants.WETH_ETHEREUM_MAINNET);
        wrapper = MockWrapper(payable(LibClone.clone(s_wrapperImplementation, args0)));
        wrapper.initialize();

        bytes memory args1 = abi.encode(wrapper, Constants.WETH_ETHEREUM_MAINNET);
        connector = ERC4626WrapperConnector(LibClone.clone(s_wrapperConnectorImplementation, args1));
    }
}

contract ERC4626WrapperConnectorNativeETHTest is ERC4626WrapperConnectorTest {
    function deploy()
        internal
        override
        returns (MockERC20 asset, MockERC4626 vault, MockWrapper wrapper, ERC4626WrapperConnector connector)
    {
        vm.etch(Constants.WETH_ETHEREUM_MAINNET, address(new MockWETH()).code);
        asset = MockERC20(payable(Constants.WETH_ETHEREUM_MAINNET));
        vault = new MockERC4626(ERC20(address(asset)), false);
        bytes memory args0 = abi.encode(vault, Constants.WETH_ETHEREUM_MAINNET);
        wrapper = MockWrapper(payable(LibClone.clone(s_wrapperImplementation, args0)));
        wrapper.initialize();

        bytes memory args1 = abi.encode(wrapper, Constants.WETH_ETHEREUM_MAINNET);
        connector = ERC4626WrapperConnector(LibClone.clone(s_wrapperConnectorImplementation, args1));
    }

    function test_DepositNativeETH() public {
        uint256 value = 10 ether;

        uint256 totalSupply = s_vault.totalSupply();
        uint256 shares = s_connector.deposit{value: value}(NATIVE_ETH, value, alice);

        assertEq(s_vault.totalSupply(), totalSupply + s_vault.previewDeposit(value), "totalSupply");
        assertEq(s_wrapper.balanceOf(alice), shares, "shares balance");
    }

    function test_RedeemNativeETH() public {
        uint256 valueIn = 3 ether;

        uint256 shares = s_connector.deposit{value: valueIn}(NATIVE_ETH, valueIn, alice);

        uint256 redeemAmount = shares / 2;
        s_wrapper.approve(address(s_connector), shares);
        uint256 valueOut = s_connector.redeem(NATIVE_ETH, redeemAmount, alice);

        assertEq(alice.balance, INITIAL_BALANCE - valueIn + valueOut, "ETH balance");
        assertEq(s_wrapper.balanceOf(alice), shares - redeemAmount, "shares balance");
    }

    function test_RedeemWETH() public {
        uint256 assetsIn = 3 ether;
        uint256 balanceBefore = s_asset.balanceOf(alice);

        s_asset.approve(address(s_connector), assetsIn);
        uint256 shares = s_connector.deposit(s_asset.into(), assetsIn, alice);

        uint256 redeemAmount = shares / 79;
        s_wrapper.approve(address(s_connector), shares);
        uint256 assetsOut = s_connector.redeem(s_asset.into(), redeemAmount, alice);

        assertEq(s_asset.balanceOf(alice), balanceBefore - assetsIn + assetsOut, "weth balance");
        assertEq(s_wrapper.balanceOf(alice), shares - redeemAmount, "shares balance");
    }
}
