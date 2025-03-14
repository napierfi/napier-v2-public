// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.13;

import "forge-std/src/Test.sol";
import "../Property.sol" as Property;

import {Base} from "../Base.t.sol";
import {BaseHandler} from "./handler/BaseHandler.sol";
import {PrincipalTokenHandler} from "./handler/PrincipalTokenHandler.sol";
import {Ghost} from "./Ghost.sol";
import {HookActor} from "./handler/HookActor.sol";

import {MockFeeModule} from "../mocks/MockFeeModule.sol";

import "src/Types.sol";
import {Casting} from "src/utils/Casting.sol";
import {LibExpiry} from "src/utils/LibExpiry.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import {IRewardProxy} from "src/interfaces/IRewardProxy.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";

/// @dev Known error on invariant testing:
/// 1. `ValueIsZeroSentinel()` on YT receivers ghost variable update because Solady's `EnumerableSetLib` does not allow special value `_ZERO_SENTINEL` as a member.
/// 2. Hook actor fails to make a call on hook
contract InvariantTest is Base {
    uint256 constant N_HOOK_ACTORS = 8;
    Ghost s_ghost;
    PrincipalTokenHandler s_principalTokenHandler;
    HookActor[] s_hookActors;

    function setUp() public override {
        super.setUp();

        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        for (uint256 i = 0; i < N_HOOK_ACTORS; i++) {
            s_hookActors.push(new HookActor(principalToken));
        }

        _label();

        s_ghost = new Ghost(s_hookActors);
        s_principalTokenHandler = new PrincipalTokenHandler(s_ghost, principalToken);

        bytes4[] memory selectors = new bytes4[](15);
        selectors[0] = PrincipalTokenHandler.supply.selector;
        selectors[1] = PrincipalTokenHandler.issue.selector;
        selectors[2] = PrincipalTokenHandler.combine.selector;
        selectors[3] = PrincipalTokenHandler.unite.selector;
        selectors[4] = PrincipalTokenHandler.supplyWithHook.selector;
        selectors[5] = PrincipalTokenHandler.issueWithHook.selector;
        selectors[6] = PrincipalTokenHandler.combineWithHook.selector;
        selectors[7] = PrincipalTokenHandler.uniteWithHook.selector;
        selectors[8] = PrincipalTokenHandler.withdraw.selector;
        selectors[9] = PrincipalTokenHandler.redeem.selector;
        selectors[10] = PrincipalTokenHandler.collect.selector;
        selectors[11] = PrincipalTokenHandler.yt_transfer.selector;
        selectors[12] = PrincipalTokenHandler.updateFeeParams.selector;
        selectors[13] = PrincipalTokenHandler.collectCuratorFees.selector;
        selectors[14] = PrincipalTokenHandler.collectProtocolFees.selector;
        FuzzSelector memory p = FuzzSelector({addr: address(s_principalTokenHandler), selectors: selectors});
        targetSelector(p);

        // Overwrite fee module to use MockFeeModule
        FeePcts v = FeePctsLib.pack(5_000, 15, 100, 10, 9000);
        deployCodeTo("MockFeeModule", address(feeModule));
        setMockFeePcts(address(feeModule), v);

        // Target only the handlers for invariant testing (to avoid getting reverts).
        targetContract(address(s_principalTokenHandler));

        // Prevent these contracts from being fuzzed as `msg.sender`.
        excludeSender(address(principalToken));
        excludeSender(address(resolver));
        excludeSender(address(yt));
        excludeSender(address(target));
        excludeSender(address(base));
        excludeSender(address(s_ghost));

        // Initialize vault
        uint256 initialVaultBalance = 100 * bOne;
        vm.startPrank(alice);
        deal(address(base), alice, initialVaultBalance, true);
        base.approve(address(target), type(uint256).max);
        target.deposit(initialVaultBalance, alice);
        vm.stopPrank();
    }

    function invariant_Solvency_0() public {
        // For simplicity, we want to make an assumption that `future_accrued_curator_fees` and `future_accrued_protocol_fees` are 0.
        // So, set the fees percentage to 0.
        address feeModule = principalToken.i_factory().moduleFor(address(principalToken), FEE_MODULE_INDEX);
        FeePcts v = boundFeePcts(FeePcts.wrap(0));
        setMockFeePcts(feeModule, v);

        if (LibExpiry.isNotExpired(principalToken)) {
            vm.warp(principalToken.maturity());
        }

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        uint256 sumPendingFees = curatorFee + protocolFee;

        address[] memory users = s_ghost.receivers();

        console2.log("============================================");
        console2.log("Num of PT/YT holders :>>", users.length);
        console2.log("Current scale :>>", principalToken.i_resolver().scale());

        uint256 sumPendingYields = 0;
        uint256 sumRedeemedShares = 0;
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            sumPendingYields += principalToken.previewCollect(user);
            sumRedeemedShares += principalToken.previewRedeem(principalToken.balanceOf(user));
        }
        console2.log("sumPendingFees :>>", sumPendingFees);
        console2.log("sumPendingYields :>>", sumPendingYields);
        console2.log("sumRedeemedShares :>>", sumRedeemedShares);
        assertLe(
            sumPendingFees + sumPendingYields + sumRedeemedShares,
            target.balanceOf(address(principalToken)),
            Property.T05_SOLVENCY
        );
    }

    function invariant_Solvency_1() public {
        address[] memory users = s_ghost.receivers(); // All PT/YT holders.

        if (LibExpiry.isNotExpired(principalToken)) {
            vm.warp(principalToken.maturity());
        }

        console2.log("============================================");
        console2.log("Num of PT/YT holders :>>", users.length);
        console2.log("Current scale :>>", principalToken.i_resolver().scale());

        // Redeem all PTs and YTs
        for (uint256 i = 0; i != users.length; i++) {
            address user = users[i];
            vm.startPrank(user);

            console2.log("Balance before `redeem` :>>", target.balanceOf(address(principalToken)));

            uint256 ptBalance = principalToken.balanceOf(user);
            principalToken.redeem({principal: ptBalance, owner: user, receiver: user});

            console2.log("Balance after `redeem`:>>", target.balanceOf(address(principalToken)));

            principalToken.collect(user, user);
            vm.stopPrank();
        }
        assertEq(principalToken.totalSupply(), 0, "PT total supply should be 0");
        assertGe(target.balanceOf(address(principalToken)), 0, Property.T05_SOLVENCY);
    }

    function invariant_Solvency_2() public {
        address[] memory users = s_ghost.receivers();

        if (LibExpiry.isNotExpired(principalToken)) {
            vm.warp(principalToken.maturity());
        }

        console2.log("============================================");
        console2.log("Num of PT/YT holders :>>", users.length);
        console2.log("Current scale :>>", principalToken.i_resolver().scale());

        for (uint256 i = 0; i != users.length; i++) {
            address user = users[i];

            uint256 ptBalance = principalToken.balanceOf(user);
            uint256 ytBalance = yt.balanceOf(user);

            vm.startPrank(user);

            // Burn all PT and YT. If the user has both PT and YT, burn them together.
            if (ptBalance >= ytBalance) {
                // Combine as much as possible
                console2.log("A1. Balance before `combine`:>>", target.balanceOf(address(principalToken)));
                principalToken.combine({principal: ytBalance, receiver: user});

                // Redeem the remaining principal
                console2.log("A2. Balance before `redeem`:>>", target.balanceOf(address(principalToken)));
                principalToken.redeem({principal: ptBalance - ytBalance, owner: user, receiver: user});
            } else {
                console2.log("B1. Balance before `combine`:>>", target.balanceOf(address(principalToken)));
                principalToken.combine({principal: ptBalance, receiver: user});
            }

            console2.log("Balance after `collect`:>>", target.balanceOf(address(principalToken)));
            principalToken.collect(user, user);

            vm.stopPrank();
        }
        assertEq(principalToken.totalSupply(), 0, "PT total supply should be 0");
        assertGe(target.balanceOf(address(principalToken)), 0, Property.T05_SOLVENCY);
    }

    function invariant_TotalSupply() public view {
        if (LibExpiry.isNotExpired(principalToken)) {
            assertEq(principalToken.totalSupply(), yt.totalSupply(), Property.T06_PT_YT_SUPPLY_EQ);
        }
    }

    function invariant_callSummary() public view {
        console2.log("Call summary:");
        console2.log("-------------------");
        console.log(LibExpiry.isNotExpired(principalToken) ? "before maturity" : "after maturity");
        address[] memory targets = targetContracts();
        for (uint256 i = 0; i < targets.length; i++) {
            BaseHandler(targets[i]).callSummary();
        }
    }
}
