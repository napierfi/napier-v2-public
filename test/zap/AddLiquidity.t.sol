// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract AddLiquidityTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public virtual override {
        super.setUp();
        _label();

        // Principal Token should be discounted against underlying token
        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        deal(twocrypto.unwrap(), alice, twocrypto.totalSupply() / 2); // 50% of total supply
    }

    function test_Withdraw() public {
        setUpYield(int256(target.totalSupply() / 2));

        FeePcts newFeePcts = FeePctsLib.pack(99, 22190, 1319, 100, 20);
        setFeePcts(newFeePcts);

        uint256 shares = 100 * tOne;
        uint256 principal = 200 * tOne;

        deal(address(target), alice, shares);
        deal(address(principalToken), alice, principal);

        vm.warp(expiry - 1);

        _test_Deposit(alice, bob, shares, principal);
    }

    function _test_Deposit(address caller, address receiver, uint256 shares, uint256 principal) internal {
        uint256 oldLiquidity = twocrypto.balanceOf(receiver);

        shares = bound(shares, 0, target.balanceOf(caller));
        principal = bound(principal, 0, principalToken.balanceOf(caller));

        _approve(target, caller, address(zap), shares);
        _approve(principalToken, caller, address(zap), principal);

        TwoCryptoZap.AddLiquidityParams memory params = TwoCryptoZap.AddLiquidityParams({
            twoCrypto: twocrypto,
            shares: shares,
            principal: principal,
            receiver: receiver,
            minLiquidity: 0,
            deadline: block.timestamp
        });

        vm.prank(caller);
        uint256 liquidity = zap.addLiquidity(params);

        assertEq(twocrypto.balanceOf(receiver), oldLiquidity + liquidity, "liquidity balance");
        assertNoFundLeft();
    }

    function test_RevertWhen_SlippageTooLarge() public {
        TwoCryptoZap.AddLiquidityParams memory params = toyParams();

        _approve(target, alice, address(zap), type(uint256).max);
        _approve(principalToken, alice, address(zap), type(uint256).max);

        params.minLiquidity = type(uint128).max;
        vm.expectRevert();
        vm.prank(alice);
        zap.addLiquidity(params);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.AddLiquidityParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.addLiquidity(params);
    }

    function toyParams() internal view returns (TwoCryptoZap.AddLiquidityParams memory) {
        return TwoCryptoZap.AddLiquidityParams({
            twoCrypto: twocrypto,
            principal: 100000,
            shares: 10000,
            receiver: alice,
            minLiquidity: 0,
            deadline: block.timestamp
        });
    }
}
