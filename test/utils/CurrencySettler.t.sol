// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {CurrencySettler} from "src/utils/CurrencySettler.sol";

contract CurrencySettlerTest is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;

    IPoolManager poolManager;
    MockERC20 token0;
    Currency currency0;
    Currency nativeCurrency;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    bytes callbackData;

    receive() external payable {}

    function setUp() public {
        poolManager = new PoolManager(address(this));
        token0 = new MockERC20(18);
        currency0 = Currency.wrap(address(token0));
        nativeCurrency = CurrencyLibrary.ADDRESS_ZERO;

        // Give alice and bob some tokens and ETH
        token0.mint(alice, 1000e18);
        token0.mint(bob, 1000e18);
        token0.mint(address(this), 1000e18);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(address(this), 100 ether);

        // Set up PM
        poolManager.unlock(abi.encode("setUp"));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager), "Only pool manager");
        callbackData = data;

        string memory action = abi.decode(data, (string));

        if (keccak256(bytes(action)) == keccak256("cashOut")) {
            (, Currency currency, uint256 amount, address recipient) =
                abi.decode(data, (string, Currency, uint256, address));
            CurrencySettler.cashOut(poolManager, currency, amount, recipient);
        } else if (keccak256(bytes(action)) == keccak256("cashInFromPayer")) {
            (, Currency currency, address payer, uint256 amount) =
                abi.decode(data, (string, Currency, address, uint256));
            CurrencySettler.cashIn(poolManager, currency, payer, amount);
        } else if (keccak256(bytes(action)) == keccak256("cashInFromSelf")) {
            (, Currency currency, uint256 amount) = abi.decode(data, (string, Currency, uint256));
            CurrencySettler.cashIn(poolManager, currency, amount);
        } else if (keccak256(bytes(action)) == keccak256("cashInFromPayerNative")) {
            (, Currency currency,, uint256 amount) = abi.decode(data, (string, Currency, address, uint256));
            // For native currency from payer, we assume the value is sent with the unlock call
            // and we use CurrencySettler.cashIn with the contract as the payer
            CurrencySettler.cashIn(poolManager, currency, amount);
        } else if (keccak256(bytes(action)) == keccak256("setUp")) {
            poolManager.sync(nativeCurrency);
            poolManager.settle{value: 100 ether}();
            poolManager.mint(address(this), nativeCurrency.toId(), 100 ether);

            poolManager.sync(currency0);
            token0.mint(address(poolManager), 1000e18);
            poolManager.settle();
            poolManager.mint(address(this), currency0.toId(), 1000e18);
        }

        return "";
    }

    function _testCashOut(Currency currency, uint256 amount, address recipient) internal {
        poolManager.unlock(abi.encode("cashOut", currency, amount, recipient));
    }

    function _testCashInFromPayer(Currency currency, address payer, uint256 amount) internal {
        poolManager.unlock(abi.encode("cashInFromPayer", currency, payer, amount));
    }

    function _testCashInFromSelf(Currency currency, uint256 amount) internal {
        poolManager.unlock(abi.encode("cashInFromSelf", currency, amount));
    }

    function _testCashInFromPayerNative(Currency currency, address payer, uint256 amount) internal {
        // For testing purposes, we'll simulate tokenization by directly calling the
        // cashInFromSelf version which works with native currency
        poolManager.unlock(abi.encode("cashInFromPayerNative", currency, payer, amount));
    }

    function test_CashOut_ERC20() public {
        uint256 amount = 9102912;
        testFuzz_CashOut_ERC20(amount);
    }

    function test_CashOut_Native() public {
        uint256 amount = 9102912;
        testFuzz_CashOut_Native(amount);
    }

    function testFuzz_CashOut_ERC20(uint256 amount) public {
        amount = bound(amount, 0, poolManager.balanceOf(address(this), currency0.toId()));

        uint256 bobBalanceBefore = token0.balanceOf(bob);

        _testCashOut(currency0, amount, bob);

        assertEq(token0.balanceOf(bob), bobBalanceBefore + amount);
    }

    function testFuzz_CashOut_Native(uint256 amount) public {
        amount = bound(amount, 0, poolManager.balanceOf(address(this), nativeCurrency.toId()));

        uint256 claimBalanceBefore = poolManager.balanceOf(address(this), nativeCurrency.toId());
        uint256 poolBalanceBefore = address(poolManager).balance;
        uint256 aliceBalanceBefore = alice.balance;

        _testCashOut(nativeCurrency, amount, alice);

        assertEq(address(poolManager).balance, poolBalanceBefore - amount);
        assertEq(poolManager.balanceOf(address(this), nativeCurrency.toId()), claimBalanceBefore - amount);
        assertEq(alice.balance, aliceBalanceBefore + amount);
    }

    function test_CashInFromPayer_ERC20() public {
        uint256 amount = 100e18;
        uint256 dust = 212;
        testFuzz_CashInFromPayer_ERC20(amount, dust);
    }

    function test_CashInFromSelf_ERC20() public {
        uint256 amount = 100e18;
        uint256 dust = 13;
        testFuzz_CashInFromSelf_ERC20(amount, dust);
    }

    function testFuzz_CashInFromPayer_ERC20(uint256 amount, uint256 dust) public {
        amount = bound(amount, 0, token0.balanceOf(alice));
        dust = bound(dust, 0, amount);

        token0.mint(address(poolManager), dust);

        vm.startPrank(alice);
        token0.approve(address(this), amount);
        vm.stopPrank();

        uint256 aliceBalanceBefore = token0.balanceOf(alice);
        uint256 poolBalanceBefore = token0.balanceOf(address(poolManager));
        uint256 claimBalanceBefore = poolManager.balanceOf(address(this), currency0.toId());

        _testCashInFromPayer(currency0, alice, amount);

        assertEq(token0.balanceOf(alice), aliceBalanceBefore - amount, "alice");
        assertEq(token0.balanceOf(address(poolManager)), poolBalanceBefore + amount, "pool");
        assertEq(poolManager.balanceOf(address(this), currency0.toId()), claimBalanceBefore + amount, "claim");
    }

    function testFuzz_CashInFromSelf_ERC20(uint256 amount, uint256 dust) public {
        amount = bound(amount, 0, token0.balanceOf(address(this)));
        dust = bound(dust, 0, amount);

        token0.mint(address(poolManager), dust);

        uint256 selfBalanceBefore = token0.balanceOf(address(this));
        uint256 poolBalanceBefore = token0.balanceOf(address(poolManager));
        uint256 claimBalanceBefore = poolManager.balanceOf(address(this), currency0.toId());

        _testCashInFromSelf(currency0, amount);

        assertEq(token0.balanceOf(address(this)), selfBalanceBefore - amount, "self");
        assertEq(token0.balanceOf(address(poolManager)), poolBalanceBefore + amount, "pool");
        assertEq(poolManager.balanceOf(address(this), currency0.toId()), claimBalanceBefore + amount, "claim");
    }

    function testFuzz_CashIn_Native(uint256 amount, uint256 dust) public {
        amount = bound(amount, 0, address(this).balance);
        dust = bound(dust, 0, 212212);

        vm.deal(address(poolManager), address(poolManager).balance + dust);

        uint256 selfBalanceBefore = address(this).balance;
        uint256 poolBalanceBefore = address(poolManager).balance;
        uint256 claimBalanceBefore = poolManager.balanceOf(address(this), nativeCurrency.toId());

        _testCashInFromPayerNative(nativeCurrency, address(this), amount);

        assertEq(address(this).balance, selfBalanceBefore - amount);
        assertEq(address(poolManager).balance, poolBalanceBefore + amount);
        assertEq(poolManager.balanceOf(address(this), nativeCurrency.toId()), claimBalanceBefore + amount);
    }

    function testFuzz_RoundTrip_ERC20(uint256 amount) public {
        amount = bound(amount, 0, token0.balanceOf(alice));

        // CashIn
        vm.startPrank(alice);
        token0.approve(address(this), amount);
        vm.stopPrank();

        uint256 aliceBalanceBefore = token0.balanceOf(alice);
        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency0.toId());

        // CashIn
        _testCashInFromPayer(currency0, alice, amount);

        // Cash out
        _testCashOut(currency0, amount, alice);

        // Verify full round trip
        assertEq(token0.balanceOf(alice), aliceBalanceBefore);
        assertEq(poolManager.balanceOf(address(this), currency0.toId()), poolBalanceBefore);
    }
}
