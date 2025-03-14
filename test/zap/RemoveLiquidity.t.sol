// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract RemoveLiquidityTest is TwoCryptoZapAMMTest {
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

        uint256 liquidity = twocrypto.balanceOf(alice) / 100;

        FeePcts newFeePcts = FeePctsLib.pack(3000, 100, 10, 100, 20);
        setFeePcts(newFeePcts);

        vm.warp(expiry - 1);

        _test_Withdraw(alice, bob, liquidity);
    }

    function _test_Withdraw(address caller, address receiver, uint256 liquidity) internal {
        uint256 oldLiquidity = twocrypto.balanceOf(caller);
        (uint256 oldUnderlyingBalnce, uint256 oldPrincipalBalance) =
            (target.balanceOf(receiver), principalToken.balanceOf(receiver));

        liquidity = bound(liquidity, 0, twocrypto.balanceOf(caller));
        _approve(twocrypto.unwrap(), caller, address(zap), liquidity);

        TwoCryptoZap.RemoveLiquidityParams memory params = TwoCryptoZap.RemoveLiquidityParams({
            twoCrypto: twocrypto,
            liquidity: liquidity,
            receiver: receiver,
            minShares: 0,
            minPrincipal: 0,
            deadline: block.timestamp
        });

        vm.prank(caller);
        (uint256 shares, uint256 principal) = zap.removeLiquidity(params);

        (uint256 newUnderlyingBalnce, uint256 newPrincipalBalance) =
            (target.balanceOf(receiver), principalToken.balanceOf(receiver));
        assertEq(twocrypto.balanceOf(caller), oldLiquidity - liquidity, "liquidity balance");
        assertEq(newUnderlyingBalnce, oldUnderlyingBalnce + shares, "underlying balance");
        assertEq(newPrincipalBalance, oldPrincipalBalance + principal, "pt balance");
        assertNoFundLeft();
    }

    function test_RevertWhen_SlippageTooLarge_0() public {
        TwoCryptoZap.RemoveLiquidityParams memory params = toyParams();

        _approve(twocrypto.unwrap(), alice, address(zap), params.liquidity);

        params.minShares = 10000e18;
        vm.expectRevert();
        vm.prank(alice);
        zap.removeLiquidity(params);
    }

    function test_RevertWhen_SlippageTooLarge_1() public {
        TwoCryptoZap.RemoveLiquidityParams memory params = toyParams();

        _approve(twocrypto.unwrap(), alice, address(zap), params.liquidity);

        params.minPrincipal = 10000e18;
        vm.expectRevert();
        vm.prank(alice);
        zap.removeLiquidity(params);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.RemoveLiquidityParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.removeLiquidity(params);
    }

    function toyParams() internal view returns (TwoCryptoZap.RemoveLiquidityParams memory) {
        return TwoCryptoZap.RemoveLiquidityParams({
            twoCrypto: twocrypto,
            liquidity: 1e18,
            receiver: alice,
            minPrincipal: 0,
            minShares: 0,
            deadline: block.timestamp
        });
    }
}
