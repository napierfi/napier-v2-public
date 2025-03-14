// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Base} from "../Base.t.sol";

import "../Property.sol" as Property;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

import "src/Types.sol";
import {YieldMathLib, Snapshot, Yield} from "src/utils/YieldMathLib.sol";
import {Casting} from "src/utils/Casting.sol";
import {Errors} from "src/Errors.sol";
import {Events} from "src/Events.sol";

using Casting for ERC20;

/// @dev EIP5095+
abstract contract EIP5095PropertyPlus is Base {
    using Casting for *;

    uint256 _delta_;

    uint256 constant N = 4;

    struct Init {
        address[N] user;
        uint256[N] share;
        uint256[N] principal;
        int256 yield;
    }

    modifier boundInit(Init memory init) virtual {
        for (uint256 i = 0; i < N; i++) {
            vm.assume(_isEOA(init.user[i]) && init.user[i] != address(0));
            init.share[i] = bound(init.share[i], 0, 1e10 * tOne);
            init.principal[i] = bound(init.principal[i], 0, 1e10 * tOne);
        }
        init.yield = bound(init.yield, type(int80).min, type(int80).max);
        _;
    }

    // TODO ERC4626 with virtualShares doesn't support these setup. Assumption: vault decimals is eq to asset decimals
    // setup initial vault state as follows:
    //
    // vault.totalAssets == sum(init.share) + init.yield
    // vault.totalShares == sum(init.share)
    //
    // init.user[i]'s shares ~ init.principal[i] - fees
    // init.user[i]'s shares == init.share[i]
    function setUpVault(Init memory init) public virtual {
        // setup initial shares and shares for individual users
        for (uint256 i = 0; i < N; i++) {
            address user = init.user[i];
            vm.assume(_isEOA(user));
            vm.label(user, string.concat("user", vm.toString(i)));
            // principals
            uint256 principal = init.principal[i];
            try MockERC20(base.asAddr()).mint(user, principal) {}
            catch {
                vm.assume(false);
            }
            vm.prank(user);
            base.approve(target.asAddr(), principal);
            vm.prank(user);
            try MockERC4626(target.asAddr()).deposit(principal, user) {}
            catch {
                vm.assume(false);
            }
            vm.prank(user);
            target.approve(principalToken.asAddr(), principal);
            vm.prank(user);
            try principalToken.supply(principal, user) {}
            catch {
                vm.assume(false);
            }

            // shares
            uint256 shares = init.share[i];
            try MockERC20(base.asAddr()).mint(user, shares) {}
            catch {
                vm.assume(false);
            }
            vm.prank(user);
            base.approve(target.asAddr(), shares);
            vm.prank(user);
            try MockERC4626(target.asAddr()).deposit(shares, user) {}
            catch {
                vm.assume(false);
            }
        }

        // setup initial yield for vault
        setUpYield(init);
    }

    // setup initial yield
    function setUpYield(Init memory init) public {
        setUpYield(init.yield);
    }

    function setUpYield(int256 yield) public virtual {
        if (yield >= 0) {
            // gain
            uint256 gain = uint256(yield);
            try MockERC20(base.asAddr()).mint(target.asAddr(), gain) {}
            catch {
                vm.assume(false);
            } // this can be replaced by calling yield generating functions if provided by the vault
        } else {
            // loss
            vm.assume(yield > type(int256).min); // avoid overflow in conversion
            uint256 loss = uint256(-1 * yield);
            try MockERC20(base.asAddr()).burn(target.asAddr(), loss) {}
            catch {
                vm.assume(false);
            } // this can be replaced by calling yield generating functions if provided by the vault
        }
    }

    function _isEOA(address account) internal view returns (bool) {
        return account.code.length == 0;
    }

    function prop_previewSupply(address caller, address receiver, address other, uint256 shares) internal {
        vm.prank(other);
        uint256 preview = _pt_previewSupply(shares); // "MAY revert due to other conditions that would also cause deposit to revert."
        if (isExpired()) assertEq(preview, 0, Property.T21_PREVIEW_SUPPLY);
        vm.prank(caller);
        uint256 actual = _pt_supply(shares, receiver);
        assertApproxGeAbs(actual, preview, _delta_, Property.T10_SUPPLY);
    }

    function prop_previewIssue(address caller, address receiver, address other, uint256 principal) internal {
        vm.prank(other);
        uint256 preview = _pt_previewIssue(principal); // "MAY revert due to other conditions that would also cause deposit to revert."
        if (isExpired()) assertEq(preview, 0, Property.T22_PREVIEW_ISSUE);
        vm.prank(caller);
        uint256 actual = _pt_issue(principal, receiver);
        assertApproxLeAbs(actual, preview, _delta_, Property.T11_ISSUE);
    }

    function prop_previewCombine(address caller, address receiver, address other, uint256 principal) internal {
        vm.prank(other);
        uint256 preview = _pt_previewCombine(principal); // "MAY revert due to other conditions that would also cause deposit to revert."
        vm.prank(caller);
        uint256 actual = _pt_combine(principal, receiver);
        assertApproxGeAbs(actual, preview, _delta_, Property.T15_COMBINE);
    }

    function prop_previewUnite(address caller, address receiver, address other, uint256 shares) internal {
        vm.prank(other);
        uint256 preview = _pt_previewUnite(shares); // "MAY revert due to other conditions that would also cause deposit to revert."
        vm.prank(caller);
        uint256 actual = _pt_unite(shares, receiver);
        assertApproxLeAbs(actual, preview, _delta_, Property.T14_UNITE);
    }

    function prop_previewCollect(address caller, address owner, address receiver, address other) internal {
        vm.prank(other);
        uint256 preview = _pt_previewCollect(owner);
        vm.prank(caller);
        (uint256 actual,) = _pt_collect(receiver, owner);
        assertApproxGeAbs(actual, preview, _delta_, Property.T16_COLLECT);
    }

    function prop_previewRedeem(address caller, address receiver, address owner, address other, uint256 principal)
        internal
    {
        vm.prank(other);
        uint256 preview = _pt_previewRedeem(principal); // "MAY revert due to other conditions that would also cause deposit to revert."
        if (!isExpired()) assertEq(preview, 0, Property.T23_PREVIEW_REDEEM);
        vm.prank(caller);
        uint256 actual = _pt_redeem(principal, receiver, owner);
        assertApproxGeAbs(actual, preview, _delta_, Property.T13_REDEEM);
    }

    function prop_previewWithdraw(address caller, address receiver, address other, uint256 shares) internal {
        vm.prank(other);
        uint256 preview = _pt_previewWithdraw(shares); // "MAY revert due to other conditions that would also cause deposit to revert."
        if (!isExpired()) assertEq(preview, 0, Property.T24_PREVIEW_WITHDRAW);
        vm.prank(caller);
        uint256 actual = _pt_withdraw(shares, receiver, other);
        assertApproxLeAbs(actual, preview, _delta_, Property.T12_WITHDRAW);
    }

    function prop_supply(address caller, address receiver, uint256 shares) public virtual {
        uint256 oldCallerShares = target.balanceOf(caller);
        uint256 oldReceiverPrincipal = principalToken.balanceOf(receiver);
        uint256 oldReceiverYt = yt.balanceOf(receiver);
        uint256 oldAllowance = target.allowance(caller, address(principalToken));

        vm.expectEmit(true, true, true, false);
        emit Events.Supply({by: caller, receiver: receiver, shares: shares, principal: 0});

        vm.prank(caller);
        uint256 principal = _pt_supply(shares, receiver);

        uint256 newCallerShare = target.balanceOf(caller);
        uint256 newReceiverPrincipal = principalToken.balanceOf(receiver);
        uint256 newReceiverYt = yt.balanceOf(receiver);
        uint256 newAllowance = target.allowance(caller, address(principalToken));

        assertApproxEqAbs(newCallerShare, oldCallerShares - shares, _delta_, "share"); // NOTE: this may fail if the caller is a contract in which the asset is stored
        assertApproxEqAbs(newReceiverPrincipal, oldReceiverPrincipal + principal, _delta_, "principal");
        assertApproxEqAbs(newReceiverYt, oldReceiverYt + principal, _delta_, "yt");
        if (oldAllowance != type(uint256).max) {
            assertApproxEqAbs(newAllowance, oldAllowance - shares, _delta_, "allowance");
        }
    }

    function prop_issue(address caller, address receiver, uint256 principal) public virtual {
        uint256 oldCallerShares = target.balanceOf(caller);
        uint256 oldReceiverPrincipal = principalToken.balanceOf(receiver);
        uint256 oldAllowance = target.allowance(caller, address(principalToken));

        vm.expectEmit(true, true, true, false);
        emit Events.Supply({by: caller, receiver: receiver, shares: 0, principal: principal});

        vm.prank(caller);
        uint256 shares = _pt_issue(principal, receiver);

        uint256 newCallerShare = target.balanceOf(caller);
        uint256 newReceiverPrincipal = principalToken.balanceOf(receiver);
        uint256 newAllowance = target.allowance(caller, address(principalToken));

        assertApproxEqAbs(newCallerShare, oldCallerShares - shares, _delta_, "share"); // NOTE: this may fail if the caller is a contract in which the asset is stored
        assertApproxEqAbs(newReceiverPrincipal, oldReceiverPrincipal + principal, _delta_, "principal");
        if (oldAllowance != type(uint256).max) {
            assertApproxEqAbs(newAllowance, oldAllowance - shares, _delta_, "allowance");
        }
    }

    function prop_combine(address caller, address receiver, uint256 principal) public virtual {
        uint256 oldCallerPrincipal = principalToken.balanceOf(caller);
        uint256 oldCallerYt = yt.balanceOf(caller);
        uint256 oldReceiverShares = target.balanceOf(receiver);

        vm.expectEmit(true, true, true, false);
        emit Events.Unite({by: caller, receiver: receiver, shares: 0, principal: principal});

        vm.prank(caller);
        uint256 shares = _pt_combine(principal, receiver);

        uint256 newCallerPrincipal = principalToken.balanceOf(caller);
        uint256 newCallerYt = yt.balanceOf(caller);
        uint256 newReceiverShares = target.balanceOf(receiver);

        assertApproxEqAbs(newCallerPrincipal, oldCallerPrincipal - principal, _delta_, "principal");
        assertApproxEqAbs(newCallerYt, oldCallerYt - principal, _delta_, "yt");
        assertApproxEqAbs(newReceiverShares, oldReceiverShares + shares, _delta_, "shares");
    }

    function prop_withdraw(address caller, address receiver, address owner, uint256 shares) public {
        uint256 oldReceiverShares = target.balanceOf(receiver);
        uint256 oldOwnerPrincipal = principalToken.balanceOf(owner);
        uint256 oldAllowance = principalToken.allowance(owner, caller);

        vm.expectEmit(true, true, true, false);
        emit Events.Redeem({by: caller, receiver: receiver, owner: owner, shares: shares, principal: 0});

        vm.prank(caller);
        uint256 principal = _pt_withdraw(shares, receiver, owner);

        uint256 newReceiverShares = target.balanceOf(receiver);
        uint256 newOwnerPrincipal = principalToken.balanceOf(owner);
        uint256 newAllowance = principalToken.allowance(owner, caller);

        assertApproxEqAbs(newOwnerPrincipal, oldOwnerPrincipal - principal, _delta_, "principal");
        assertApproxEqAbs(newReceiverShares, oldReceiverShares + shares, _delta_, "shares"); // NOTE: this may fail if the receiver is a contract in which the asset is stored
        if (caller != owner && oldAllowance != type(uint256).max) {
            assertApproxEqAbs(newAllowance, oldAllowance - principal, _delta_, "allowance");
        }

        assertTrue(caller == owner || oldAllowance != 0 || (principal == 0 && shares == 0), "access control");
    }

    function prop_redeem(address caller, address receiver, address owner, uint256 principal) public {
        uint256 oldReceiverShares = target.balanceOf(receiver);
        uint256 oldOwnerPrincipal = principalToken.balanceOf(owner);
        uint256 oldAllowance = principalToken.allowance(owner, caller);

        vm.expectEmit(true, true, true, false);
        emit Events.Redeem({by: caller, receiver: receiver, owner: owner, shares: 0, principal: principal});

        vm.prank(caller);
        uint256 shares = _pt_redeem(principal, receiver, owner);

        uint256 newReceiverShares = target.balanceOf(receiver);
        uint256 newOwnerPrincipal = principalToken.balanceOf(owner);
        uint256 newAllowance = principalToken.allowance(owner, caller);

        assertApproxEqAbs(newOwnerPrincipal, oldOwnerPrincipal - principal, _delta_, "principal");
        assertApproxEqAbs(newReceiverShares, oldReceiverShares + shares, _delta_, "shares"); // NOTE: this may fail if the receiver is a contract in which the asset is stored
        if (caller != owner && oldAllowance != type(uint256).max) {
            assertApproxEqAbs(newAllowance, oldAllowance - principal, _delta_, "allowance");
        }

        assertTrue(caller == owner || oldAllowance != 0 || (principal == 0 && shares == 0), "access control");
    }

    function prop_unite(address caller, address receiver, uint256 shares) public virtual {
        uint256 oldCallerPrincipal = principalToken.balanceOf(caller);
        uint256 oldCallerYt = yt.balanceOf(caller);
        uint256 oldReceiverShares = target.balanceOf(receiver);

        vm.expectEmit(true, true, true, false);
        emit Events.Unite({by: caller, receiver: receiver, shares: shares, principal: 0});

        vm.prank(caller);
        uint256 principal = _pt_unite(shares, receiver);

        uint256 newCallerPrincipal = principalToken.balanceOf(caller);
        uint256 newCallerYt = yt.balanceOf(caller);
        uint256 newReceiverShares = target.balanceOf(receiver);

        assertApproxEqAbs(newCallerPrincipal, oldCallerPrincipal - principal, _delta_, "principal");
        assertApproxEqAbs(newCallerYt, oldCallerYt - principal, _delta_, "yt");
        assertApproxEqAbs(newReceiverShares, oldReceiverShares + shares, _delta_, "shares");
    }

    function prop_collect(address caller, address receiver, address owner) public {
        uint256 oldOwnerYt = yt.balanceOf(owner);
        uint256 oldReceiverShares = target.balanceOf(receiver);
        bool oldIsApproved = principalToken.isApprovedCollector(owner, caller);
        uint256[] memory oldReceiverRewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            oldReceiverRewards[i] = ERC20(rewardTokens[i]).balanceOf(receiver);
        }
        vm.prank(caller);
        (uint256 shares, TokenReward[] memory rewardsCollected) = _pt_collect(receiver, owner);

        uint256 newOwnerYt = yt.balanceOf(owner);
        uint256 newReceiverShares = target.balanceOf(receiver);
        bool newIsApproved = principalToken.isApprovedCollector(owner, caller);

        assertEq(newOwnerYt, oldOwnerYt, "YT balance should not change");
        assertEq(newReceiverShares, oldReceiverShares + shares, "shares");
        assertEq(newIsApproved, oldIsApproved, "approval status should not change");
        assertTrue(caller == owner || oldIsApproved, "access control");
        // Optional assertions
        if (rewardTokens.length == rewardsCollected.length) {
            for (uint256 i = 0; i < rewardTokens.length; i++) {
                uint256 newReceiverReward = ERC20(rewardTokens[i]).balanceOf(receiver);
                assertEq(newReceiverReward, oldReceiverRewards[i] + rewardsCollected[i].amount, "rewards");
                // Check that the pending rewards are zeroed out after collection
                assertEq(principalToken.getUserReward(rewardTokens[i], owner).accrued, 0, "Rewards zeroed out");
            }
        }
    }

    function prop_yt_transfer(address owner, address receiver, uint256 value) public {
        uint256 oldOwnerYt = yt.balanceOf(owner);
        uint256 oldReceiverYt = yt.balanceOf(receiver);

        vm.prank(owner);
        _pt_yt_transfer(receiver, value);

        uint256 newOwnerYt = yt.balanceOf(owner);
        uint256 newReceiverYt = yt.balanceOf(receiver);

        if (owner == receiver) {
            assertEq(newOwnerYt, oldOwnerYt, "owner == receiver");
        } else {
            assertEq(newOwnerYt, oldOwnerYt - value, "owner");
            assertEq(newReceiverYt, oldReceiverYt + value, "receiver");
        }
    }

    function prop_yt_transferFrom(address caller, address owner, address receiver, uint256 value) public {
        uint256 oldOwnerYt = yt.balanceOf(owner);
        uint256 oldReceiverYt = yt.balanceOf(receiver);
        uint256 oldAllowance = yt.allowance(owner, caller);

        vm.prank(caller);
        _pt_yt_transferFrom(owner, receiver, value);

        uint256 newOwnerYt = yt.balanceOf(owner);
        uint256 newReceiverYt = yt.balanceOf(receiver);
        uint256 newAllowance = yt.allowance(owner, caller);

        if (owner == receiver) {
            assertEq(newOwnerYt, oldOwnerYt, "owner == receiver");
        } else {
            assertEq(newOwnerYt, oldOwnerYt - value, "owner");
            assertEq(newReceiverYt, oldReceiverYt + value, "receiver");
        }
        assertEq(newAllowance, oldAllowance - value, "allowance");
    }

    function prop_max_redeem(address caller, address owner) public {
        vm.prank(caller);
        if (isExpired()) {
            principalToken.maxRedeem(owner); // MUST NOT revert
        } else {
            assertEq(principalToken.maxRedeem(owner), 0, Property.T17_MAX_REDEEM);
        }
    }

    function prop_max_withdraw(address caller, address owner) public {
        vm.prank(caller);
        if (isExpired()) {
            // NOTE: some implementations failed due to arithmetic overflow
            principalToken.maxWithdraw(owner); // MUST NOT revert
        } else {
            assertEq(principalToken.maxWithdraw(owner), 0, Property.T18_MAX_WITHDRAW);
        }
    }

    /// @dev Utility function as a workaround for handling underflow or overflow in the yield calculation
    function math_calcYield(uint256 prev, uint256 cscale, uint256 ytBalance) external pure returns (uint256) {
        return YieldMathLib.calcYield(prev, cscale, ytBalance);
    }

    /// @dev Fuzzing helper function. Skip underflow/overflow errors
    function calcYield(uint256 prev, uint256 cscale, uint256 ytBalance) public view returns (uint256) {
        (bool success, bytes memory retdata) =
            address(this).staticcall(abi.encodeCall(this.math_calcYield, (prev, cscale, ytBalance)));
        vm.assume(success);
        return abi.decode(retdata, (uint256));
    }

    struct State {
        Snapshot snapshot;
        uint256 accrued; // getUserYield(context.src).accrued
        uint256 userIndex; // getUserYield(context.src).userIndex
        uint256 ytBalance; // yt.balanceOf(context.src)
        uint256 ytSupply;
        uint256 totalShares; // target.balanceof(principalToken)
        uint256 shareSupply; // target.totalSupply()
        uint256 curatorFee;
        uint256 protocolFee;
        bool isSettled;
        bool isExpired;
    }

    struct Context {
        address[N] users; // Init.user
        address src; // Target of the accrual operation and assertion target
        uint256 profit;
        int256 yield;
        uint256 seed;
        State prestate;
        State poststate;
    }

    function prop_accrue(
        Context memory context,
        function (Context memory) internal execute_accrue,
        function (Context memory) internal assert_accrue
    ) internal {
        require(context.src != address(0), "EIP5095PropTest: src not set");
        context.seed = uint256(keccak256(abi.encodePacked(context.src, context.yield, context.seed)));

        uint256 prev = resolver.scale();
        setUpYield(context.yield); // Setup yield for the vault (loss or gain)
        uint256 cscale = resolver.scale();

        // Note This test assumes `prev` is a scale at the last time of the user `src`'s YT balanace update.
        uint256 oldYtBalance = yt.balanceOf(context.src);
        context.profit = calcYield(prev, cscale, oldYtBalance); // Accrued yield by a user
        {
            (uint256 oldCuratorFee, uint256 oldProtocolFee) = principalToken.getFees();
            bool isSettled = principalToken.isSettled();
            Snapshot memory s = principalToken.getSnapshot();
            Yield memory oldUserYield = principalToken.getUserYield(context.src);

            context.prestate = State({
                snapshot: s,
                accrued: oldUserYield.accrued,
                userIndex: oldUserYield.userIndex.unwrap(),
                ytBalance: oldYtBalance,
                ytSupply: yt.totalSupply(),
                totalShares: target.balanceOf(address(principalToken)),
                shareSupply: target.totalSupply(),
                curatorFee: oldCuratorFee,
                protocolFee: oldProtocolFee,
                isSettled: isSettled,
                isExpired: isExpired()
            });
        }
        execute_accrue(context); // Operation that will accrue yield
        {
            uint256 newYtBalance = yt.balanceOf(context.src);
            (uint256 newCuratorFee, uint256 newProtocolFee) = principalToken.getFees();
            Snapshot memory s = principalToken.getSnapshot();
            Yield memory newUserYield = principalToken.getUserYield(context.src);

            context.poststate = State({
                snapshot: s,
                accrued: newUserYield.accrued,
                userIndex: newUserYield.userIndex.unwrap(),
                ytBalance: newYtBalance,
                ytSupply: yt.totalSupply(),
                totalShares: target.balanceOf(address(principalToken)),
                shareSupply: target.totalSupply(),
                curatorFee: newCuratorFee,
                protocolFee: newProtocolFee,
                isSettled: principalToken.isSettled(),
                isExpired: isExpired()
            });
        }
        assert_accrue(context);
    }

    function _max_supply(address from) internal virtual returns (uint256) {
        return target.balanceOf(from);
    }

    function _max_issue(address from) internal virtual returns (uint256) {
        return _pt_convertToPrincipal(target.balanceOf(from));
    }

    function _max_withdraw(address from) internal virtual returns (uint256) {
        return _pt_convertToUnderlying(principalToken.balanceOf(from));
    }

    function _max_combine(address from) internal virtual returns (uint256) {
        return FixedPointMathLib.min(principalToken.balanceOf(from), yt.balanceOf(from));
    }

    function _max_unite(address from) internal virtual returns (uint256) {
        return _pt_convertToUnderlying(_max_combine(from));
    }

    function _max_redeem(address from) internal virtual returns (uint256) {
        return principalToken.balanceOf(from);
    }

    function _pt_supply(uint256 shares, address receiver) internal virtual returns (uint256) {
        return _call_pt(abi.encodeWithSignature("supply(uint256,address)", shares, receiver));
    }

    function _pt_issue(uint256 principal, address receiver) internal virtual returns (uint256) {
        return _call_pt(abi.encodeWithSignature("issue(uint256,address)", principal, receiver));
    }

    function _pt_collect(address receiver, address owner) internal virtual returns (uint256, TokenReward[] memory) {
        (bool success, bytes memory retdata) =
            address(principalToken).call(abi.encodeWithSignature("collect(address,address)", receiver, owner));
        if (success) return abi.decode(retdata, (uint256, TokenReward[]));
        vm.assume(false); // if reverted, discard the current fuzz inputs, and let the fuzzer to start a new fuzz run
        return (0, new TokenReward[](0)); // silence warning
    }

    function _pt_yt_transfer(address receiver, uint256 value) internal virtual returns (bool) {
        (bool s, bytes memory retdata) =
            address(yt).call(abi.encodeWithSignature("transfer(address,uint256)", receiver, value));
        if (s) return abi.decode(retdata, (bool));
        vm.assume(false);
        return false;
    }

    function _pt_yt_transferFrom(address owner, address receiver, uint256 value) internal virtual returns (bool) {
        (bool s, bytes memory retdata) =
            address(yt).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", owner, receiver, value));
        if (s) return abi.decode(retdata, (bool));
        vm.assume(false);
        return false;
    }

    function _pt_combine(uint256 principal, address receiver) internal virtual returns (uint256) {
        return _call_pt(abi.encodeWithSignature("combine(uint256,address)", principal, receiver));
    }

    function _pt_unite(uint256 shares, address receiver) internal virtual returns (uint256) {
        return _call_pt(abi.encodeWithSignature("unite(uint256,address)", shares, receiver));
    }

    function _pt_redeem(uint256 principal, address receiver, address owner) internal virtual returns (uint256) {
        (bool success, bytes memory retdata) =
            address(principalToken).call(abi.encodeCall(principalToken.redeem, (principal, receiver, owner)));
        if (success) return abi.decode(retdata, (uint256));
        vm.assume(false); // if reverted, discard the current fuzz inputs, and let the fuzzer to start a new fuzz run
        return 0; // silence warning
    }

    function _pt_withdraw(uint256 shares, address receiver, address owner) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.withdraw, (shares, receiver, owner)));
    }

    function _pt_previewSupply(uint256 shares) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewSupply, (shares)));
    }

    function _pt_previewIssue(uint256 principal) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewIssue, (principal)));
    }

    function _pt_previewCombine(uint256 principal) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewCombine, (principal)));
    }

    function _pt_previewUnite(uint256 shares) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewUnite, (shares)));
    }

    function _pt_previewRedeem(uint256 principal) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewRedeem, (principal)));
    }

    function _pt_previewWithdraw(uint256 shares) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewWithdraw, (shares)));
    }

    function _pt_previewCollect(address owner) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.previewCollect, (owner)));
    }

    function _pt_convertToPrincipal(uint256 shares) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.convertToPrincipal, (shares)));
    }

    function _pt_convertToUnderlying(uint256 principal) internal virtual returns (uint256) {
        return _call_pt(abi.encodeCall(principalToken.convertToUnderlying, (principal)));
    }

    function _call_pt(bytes memory data) internal returns (uint256) {
        (bool success, bytes memory retdata) = address(principalToken).call(data);
        if (success) return abi.decode(retdata, (uint256));
        vm.assume(false); // if reverted, discard the current fuzz inputs, and let the fuzzer to start a new fuzz run
        return 0; // silence warning
    }

    function isExpired() internal view returns (bool) {
        return block.timestamp >= expiry;
    }

    function expectRevert_Expired() internal {
        vm.warp(expiry + 1);
        vm.expectRevert(Errors.Expired.selector);
    }

    function expectRevert_NotExpired() internal {
        vm.warp(expiry - 1);
        vm.expectRevert(Errors.NotExpired.selector);
    }

    function assertApproxGeAbs(uint256 a, uint256 b, uint256 maxDelta, string memory err) internal pure {
        if (!(a >= b)) {
            assertApproxEqAbs(a, b, maxDelta, err);
        }
    }

    function assertApproxGeAbs(uint256 a, uint256 b, uint256 maxDelta) internal pure {
        assertApproxGeAbs(a, b, maxDelta, "");
    }

    function assertApproxLeAbs(uint256 a, uint256 b, uint256 maxDelta, string memory err) internal pure {
        if (!(a <= b)) {
            assertApproxEqAbs(a, b, maxDelta, err);
        }
    }

    function assertApproxLeAbs(uint256 a, uint256 b, uint256 maxDelta) internal pure {
        assertApproxGeAbs(a, b, maxDelta, "");
    }
}
