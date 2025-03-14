// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";

import {ERC4626Connector} from "src/modules/connectors/ERC4626Connector.sol";
import "src/Constants.sol" as Constants;
import {Errors} from "src/Errors.sol";

import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

function into(ERC20 token) pure returns (Token result) {
    result = Token.wrap(address(token));
}

using {into} for MockERC20;
using {into} for MockWETH;

contract ERC4626ConnectorTest is Test {
    ERC4626Connector public s_connector;
    MockERC4626 public s_vault;
    MockERC20 public token;
    MockWETH public weth;
    address public alice = makeAddr("alice");
    uint256 public constant INITIAL_BALANCE = 100 ether;
    Token constant NATIVE_ETH = Token.wrap(Constants.NATIVE_ETH);

    function setUp() public {
        token = new MockERC20(18);
        s_vault = new MockERC4626(ERC20(address(token)), false);
        s_connector = new ERC4626Connector(address(s_vault), Constants.WETH_ETHEREUM_MAINNET);

        vm.etch(Constants.WETH_ETHEREUM_MAINNET, address(new MockWETH()).code);
        weth = MockWETH(payable(Constants.WETH_ETHEREUM_MAINNET));

        vm.deal(alice, INITIAL_BALANCE);
        token.mint(alice, INITIAL_BALANCE);
        weth.mint(alice, INITIAL_BALANCE);

        vm.label(address(token), "Mock Token");
        vm.label(address(s_vault), "Mock Vault");
        vm.label(address(s_connector), "ERC4626Connector");
    }

    function test_DepositERC20() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        token.approve(address(s_connector), depositAmount);
        uint256 shares = s_connector.deposit(token.into(), depositAmount, alice);
        vm.stopPrank();

        assertEq(shares, depositAmount, "Incorrect shares received");
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - depositAmount, "Incorrect token balance after deposit");
        assertEq(s_vault.balanceOf(alice), shares, "Incorrect vault token balance");
    }

    function test_DepositETH() public {
        uint256 depositAmount = 10 ether;
        MockERC4626 vault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector connector = new ERC4626Connector(address(vault), Constants.WETH_ETHEREUM_MAINNET);
        vm.startPrank(alice);
        uint256 shares = connector.deposit{value: depositAmount}(NATIVE_ETH, depositAmount, alice);
        vm.stopPrank();

        assertEq(shares, depositAmount, "Incorrect shares received");
        assertEq(vault.balanceOf(alice), shares, "Incorrect vault token balance");
    }

    function test_RedeemERC20() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        token.approve(address(s_connector), depositAmount);
        uint256 shares = s_connector.deposit(token.into(), depositAmount, alice);

        uint256 redeemAmount = shares / 2;
        s_vault.approve(address(s_connector), shares);
        uint256 assets = s_connector.redeem(token.into(), redeemAmount, alice);
        vm.stopPrank();

        assertEq(assets, redeemAmount, "Incorrect assets received");
        assertEq(
            token.balanceOf(alice), INITIAL_BALANCE - depositAmount + assets, "Incorrect token balance after redeem"
        );
        assertEq(s_vault.balanceOf(alice), shares - redeemAmount, "Incorrect vault token balance");
    }

    function test_RedeemETH() public {
        uint256 depositAmount = 10 ether;
        MockERC4626 vault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector connector = new ERC4626Connector(address(vault), Constants.WETH_ETHEREUM_MAINNET);
        vm.startPrank(alice);
        uint256 shares = connector.deposit{value: depositAmount}(NATIVE_ETH, depositAmount, alice);

        uint256 redeemAmount = shares / 2;
        vault.approve(address(connector), shares);
        uint256 assets = connector.redeem(NATIVE_ETH, redeemAmount, alice);
        vm.stopPrank();

        assertEq(assets, redeemAmount, "Incorrect assets received");
        assertEq(alice.balance, INITIAL_BALANCE - depositAmount + assets, "Incorrect ETH balance after redeem");
        assertEq(vault.balanceOf(alice), shares - redeemAmount, "Incorrect vault token balance");
    }

    function test_RedeemWETH() public {
        uint256 depositAmount = 10 ether;
        MockERC4626 vault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector connector = new ERC4626Connector(address(vault), Constants.WETH_ETHEREUM_MAINNET);
        uint256 balanceBefore = weth.balanceOf(alice);
        vm.startPrank(alice);
        weth.approve(address(connector), depositAmount);
        uint256 shares = connector.deposit(weth.into(), depositAmount, alice);

        uint256 redeemAmount = shares / 2;
        vault.approve(address(connector), shares);
        uint256 assets = connector.redeem(weth.into(), redeemAmount, alice);
        vm.stopPrank();
        uint256 afterBalance = weth.balanceOf(alice);
        assertEq(assets, redeemAmount, "Incorrect assets received");
        assertEq(afterBalance, balanceBefore - depositAmount + assets, "Incorrect ETH balance after redeem");
        assertEq(vault.balanceOf(alice), shares - redeemAmount, "Incorrect vault token balance");
    }

    function test_RevertWhen_InvalidToken() public {
        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        s_connector.deposit(Token.wrap(address(0xcafe)), 100, alice);
    }

    function test_RevertWhen_WETHNotSupported() public {
        MockERC20 usdc = new MockERC20(6);
        MockERC4626 usdcVault = new MockERC4626(ERC20(address(usdc)), false);
        ERC4626Connector usdcConnector = new ERC4626Connector(address(usdcVault), Constants.WETH_ETHEREUM_MAINNET);

        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        usdcConnector.deposit(weth.into(), 100, alice);
    }

    function test_RevertWhen_InvalidETHAmount() public {
        MockERC4626 wethVault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector wethConnector = new ERC4626Connector(address(wethVault), Constants.WETH_ETHEREUM_MAINNET);

        vm.expectRevert(Errors.ERC4626Connector_InvalidETHAmount.selector);
        wethConnector.deposit{value: 1 ether}(NATIVE_ETH, 2 ether, alice);
    }

    function test_RevertWhen_UnexpectedETH() public {
        MockERC4626 wethVault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector wethConnector = new ERC4626Connector(address(wethVault), Constants.WETH_ETHEREUM_MAINNET);

        vm.expectRevert(Errors.ERC4626Connector_UnexpectedETH.selector);
        wethConnector.deposit{value: 1 ether}(weth.into(), 1 ether, alice);
    }

    function test_PreviewDeposit() public {
        uint256 depositAmount = 10 ether;
        uint256 expectedShares = s_connector.previewDeposit(token.into(), depositAmount);

        vm.startPrank(alice);
        token.approve(address(s_connector), depositAmount);
        uint256 actualShares = s_connector.deposit(token.into(), depositAmount, alice);
        vm.stopPrank();

        assertEq(actualShares, expectedShares, "Preview deposit mismatch");
    }

    function test_PreviewRedeem() public {
        uint256 depositAmount = 10 ether;

        vm.startPrank(alice);
        token.approve(address(s_connector), depositAmount);
        uint256 shares = s_connector.deposit(token.into(), depositAmount, alice);

        uint256 redeemAmount = shares / 2;
        uint256 expectedAssets = s_connector.previewRedeem(token.into(), redeemAmount);

        s_vault.approve(address(s_connector), shares);
        uint256 actualAssets = s_connector.redeem(token.into(), redeemAmount, alice);
        vm.stopPrank();

        assertEq(actualAssets, expectedAssets, "Preview redeem mismatch");
    }

    function test_PreviewDepositNativeETH() public {
        uint256 depositAmount = 10 ether;
        MockERC4626 vault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector connector = new ERC4626Connector(address(vault), Constants.WETH_ETHEREUM_MAINNET);

        uint256 expectedShares = connector.previewDeposit(NATIVE_ETH, depositAmount);

        vm.startPrank(alice);
        uint256 actualShares = connector.deposit{value: depositAmount}(NATIVE_ETH, depositAmount, alice);
        vm.stopPrank();

        assertEq(actualShares, expectedShares, "Preview deposit mismatch for Native ETH");
    }

    function test_PreviewRedeemNativeETH() public {
        uint256 depositAmount = 10 ether;
        MockERC4626 vault = new MockERC4626(ERC20(address(weth)), false);
        ERC4626Connector connector = new ERC4626Connector(address(vault), Constants.WETH_ETHEREUM_MAINNET);

        vm.startPrank(alice);
        uint256 shares = connector.deposit{value: depositAmount}(NATIVE_ETH, depositAmount, alice);

        uint256 redeemAmount = shares / 2;
        uint256 expectedAssets = connector.previewRedeem(NATIVE_ETH, redeemAmount);

        vault.approve(address(connector), shares);
        uint256 actualAssets = connector.redeem(NATIVE_ETH, redeemAmount, alice);
        vm.stopPrank();

        assertEq(actualAssets, expectedAssets, "Preview redeem mismatch for Native ETH");
    }

    function test_getTokenInList() public view {
        Token[] memory tokens = s_connector.getTokenInList();

        checkTokenInList(tokens, address(s_vault));
        checkTokenInList(tokens, address(token));
    }

    function test_getTokenInList_WETH() public {
        s_vault = new MockERC4626(ERC20(Constants.WETH_ETHEREUM_MAINNET), false);
        s_connector = new ERC4626Connector(address(s_vault), Constants.WETH_ETHEREUM_MAINNET);
        Token[] memory tokens = s_connector.getTokenInList();

        checkTokenInList(tokens, address(s_vault));
        checkTokenInList(tokens, Constants.WETH_ETHEREUM_MAINNET);
        checkTokenInList(tokens, Constants.NATIVE_ETH);
    }

    function test_getTokenOutList() public view {
        Token[] memory tokens = s_connector.getTokenOutList();

        checkTokenInList(tokens, address(s_vault));
    }

    function checkTokenInList(Token[] memory tokens, address _token) internal pure {
        uint256[] memory tokenAddresses = toUint256Array(tokens);
        assertTrue(DynamicArrayLib.contains(tokenAddresses, uint256(uint160(_token))), "Token not in list");
    }

    function toUint256Array(Token[] memory a) internal pure returns (uint256[] memory result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := a
        }
    }
}
