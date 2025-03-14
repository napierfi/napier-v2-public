// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import {RedeemAccruralTest} from "./Redeem.t.sol";

import "../Property.sol" as Property;
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken, Snapshot} from "src/tokens/PrincipalToken.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract WithdrawTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 2;
    }

    function test_Withdraw(uint48 timeJump) public {
        uint256 shares = 10 * tOne;
        uint256 principal = 10 * bOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [principal, 0, 0, 0],
            yield: int256(bOne)
        });

        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 100, 0); // 1% withdrawal fee
        setFeePcts(newFeePcts);

        _test_Withdraw(init, shares, timeJump);
    }

    function testFuzz_Withdraw(Init memory init, uint256 shares, FeePcts newFeePcts, uint48 timeJump)
        public
        boundInit(init)
    {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Withdraw(init, shares, timeJump);
    }

    function _test_Withdraw(Init memory init, uint256 shares, uint256 timeJump) internal {
        setUpVault(init);

        address owner = init.user[0];
        address receiver = init.user[1];
        address caller = init.user[2];

        vm.warp(expiry + timeJump);

        uint256 oldAccrued = principalToken.getUserYield(owner).accrued;

        shares = bound(shares, 0, _max_withdraw(owner));
        _approve(principalToken, owner, caller, type(uint256).max);
        prop_withdraw(caller, receiver, owner, shares);

        uint256 newAccrued = principalToken.getUserYield(owner).accrued;
        assertEq(newAccrued, oldAccrued, "Withdraw should not accrue yield");
    }

    function test_RevertWhen_NotExpired() public {
        vm.expectRevert(Errors.NotExpired.selector);
        vm.warp(expiry - 1);
        principalToken.withdraw(100, alice, alice);
    }

    error InsufficientAllowance(); // Solady ERC20 error

    function test_RevertWhen_NotApproved() public {
        _approve(principalToken, alice, bob, 99);
        vm.warp(expiry);

        vm.expectRevert(InsufficientAllowance.selector);
        vm.prank(alice);
        principalToken.withdraw(100, alice, bob);
    }
}

abstract contract WithdrawAccruralTest is RedeemAccruralTest {
    function execute_accrue(Context memory context) internal virtual override {
        uint256 shares = bound(context.seed, 0, _max_withdraw(context.src));
        _approve(principalToken, context.src, context.users[2], type(uint256).max);
        prop_withdraw(context.users[2], context.users[1], context.src, shares);
    }

    function assert_accrue(Context memory context) internal view override {
        super.assert_accrue(context);
    }
}

contract WithdrawPreSettlementAccruralTest is WithdrawAccruralTest {
    function test_Accrue(uint256 shares, int256 yield) public {
        _test_Accrue(shares, yield, false);
    }
}

/// @dev Test withdrawing after settlement
contract WithdrawPostSettlementAccruralTest is WithdrawAccruralTest {
    function test_Accrue(uint256 shares, int256 yield) public {
        _test_Accrue(shares, yield, true);
    }

    function execute_accrue(Context memory context) internal override {
        require(context.prestate.isSettled, "Setup: Pre-state should be settled");
        super.execute_accrue(context);
    }
}

contract WithdrawPostSettlement_MaximumPerformanceFee_AccruralTest is PrincipalTokenTest {
    function execute_accrue(Context memory context) internal {
        require(context.prestate.isSettled, "Setup: Pre-state should be settled");
        uint256 shares = bound(context.seed, 0, _max_withdraw(context.src));
        _approve(principalToken, context.src, context.users[2], type(uint256).max);
        prop_withdraw(context.users[2], context.users[1], context.src, shares);
    }

    function assert_accrue(Context memory context) internal pure {
        State memory prestate = context.prestate;
        State memory poststate = context.poststate;

        assertEq(
            poststate.snapshot.globalIndex.unwrap(),
            prestate.snapshot.globalIndex.unwrap(),
            "Redemption doesn't update global index because of maximum performance fee setting"
        );
        assertEq(poststate.userIndex, prestate.userIndex, Property.T13_REDEEM_ACCURAL);
        assertEq(poststate.accrued, prestate.accrued, Property.T13_REDEEM_ACCURAL);
    }

    function testFuzz_Accrue_1(Init memory init, int80[N] memory yields) public boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[0];

        setUpVault(init);

        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // After settlement, all interest goes to performance fee
        setFeePcts(newFeePcts);

        vm.warp(expiry);
        prop_withdraw(context.src, context.src, context.src, 0); // Settle

        for (uint256 i = 0; i < N; i++) {
            context.yield = bound(yields[i], type(int80).min, type(int80).max);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }
}

contract PreviewWithdrawTest is PrincipalTokenTest {
    function testFuzz_Preview(Init memory init, uint256 shares, uint64 timeJump, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        address owner = init.user[2];
        address other = init.user[3];
        shares = bound(shares, 0, _max_withdraw(owner));
        _approve(principalToken, owner, caller, type(uint256).max);

        skip(expiry + timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        prop_previewWithdraw(caller, receiver, other, shares);
    }

    function test_WhenNotExpired() public view {
        assertEq(principalToken.previewWithdraw(100), 0, "Should return 0 when not expired");
    }

    function testFuzz_MaxWithdraw(Init memory init) public boundInit(init) {
        setUpVault(init);
        prop_max_withdraw(init.user[0], init.user[1]);
    }
}
