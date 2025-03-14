// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import "../Property.sol" as Property;
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken, Snapshot} from "src/tokens/PrincipalToken.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract RedeemTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 2;
    }

    function test_Redeem(uint48 timeJump) public {
        uint256 shares = 10 * tOne;
        uint256 principal = 10 * bOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [principal, 0, 0, 0],
            yield: int256(bOne)
        });

        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 100, BASIS_POINTS); // 1% redemption fee
        setFeePcts(newFeePcts);

        (uint256 oldCuratorFee, uint256 oldProtocolFee) = principalToken.getFees();

        _test_Redeem(init, principal, timeJump);

        (uint256 newCuratorFee, uint256 newProtocolFee) = principalToken.getFees();

        uint256 fee = (newCuratorFee + newProtocolFee) - (oldCuratorFee + oldProtocolFee);
        uint256 sharesRedeemed = target.balanceOf(init.user[1]) - init.share[1];

        Snapshot memory s = principalToken.getSnapshot();
        uint256 expectPrincipal = (sharesRedeemed + fee) * s.maxscale / 1e18;
        assertApproxEqAbs(principal, expectPrincipal, _delta_, "Principal should be calculated correctly");
    }

    function testFuzz_Redeem(Init memory init, uint256 principal, FeePcts newFeePcts, uint48 timeJump)
        public
        boundInit(init)
    {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Redeem(init, principal, timeJump);
    }

    function _test_Redeem(Init memory init, uint256 principal, uint256 timeJump) internal {
        setUpVault(init);

        address owner = init.user[0];
        address receiver = init.user[1];
        address caller = init.user[2];

        vm.warp(expiry + timeJump);

        uint256 oldAccrued = principalToken.getUserYield(owner).accrued;

        principal = bound(principal, 0, _max_redeem(owner));
        _approve(principalToken, owner, caller, principal);
        prop_redeem(caller, receiver, owner, principal);

        uint256 newAccrued = principalToken.getUserYield(owner).accrued;
        assertEq(newAccrued, oldAccrued, "Redeem should not accrue yield");
    }

    function test_RevertWhen_NotExpired() public {
        vm.expectRevert(Errors.NotExpired.selector);
        vm.warp(expiry - 1);
        principalToken.redeem(100, alice, alice);
    }

    error InsufficientAllowance(); // Solady ERC20 error

    function test_RevertWhen_NotApproved() public {
        _approve(principalToken, alice, bob, 99);
        vm.warp(expiry);

        vm.expectRevert(InsufficientAllowance.selector);
        vm.prank(alice);
        principalToken.redeem(100, alice, bob);
    }
}

abstract contract RedeemAccruralTest is PrincipalTokenTest {
    function _test_Accrue(uint256 shares, int256 yield, bool settle) internal {
        _delta_ = 5;
        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, 0); // For the sake of simplicity, zero fee
        setFeePcts(newFeePcts);

        // Note Too small amount results in precision loss in interest calculation,
        // which makes test useless. So, yield and YT balance should be large enough to check the interest calculation.
        shares = bound(shares, tOne, 1e9 * tOne);

        Init memory init = Init({
            user: [alice, bob, makeAddr("abc"), makeAddr("cdf")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(100 * bOne)
        });

        Context memory context;
        context.users = init.user;
        context.src = init.user[0];

        // Refactor: optionally doesn't set up yield
        setUpVault(init);

        vm.warp(expiry);

        if (settle) {
            prop_combine(context.src, context.src, 0); // Settle & claim the user's performance fee
        }

        context.yield = bound(yield, int256(target.totalAssets() / 1_000), type(int80).max); // Large enough to avoid precision loss
        prop_accrue(context, execute_accrue, assert_accrue);
    }

    function execute_accrue(Context memory context) internal virtual;

    function assert_accrue(Context memory context) internal view virtual {
        State memory prestate = context.prestate;
        State memory poststate = context.poststate;

        uint256 performanceFeePct = prestate.isSettled
            ? getPostSettlementFeePctBps(feeModule.getFeePcts())
            : getPerformanceFeePctBps(feeModule.getFeePcts());

        uint256 perfFeeUser = context.profit * performanceFeePct / BASIS_POINTS;
        assertGe(
            poststate.snapshot.globalIndex.unwrap(), prestate.snapshot.globalIndex.unwrap(), Property.T04_YIELD_INDEX
        );
        assertEq(poststate.accrued, prestate.accrued, Property.T13_REDEEM_ACCURAL);
        assertApproxEqAbs(
            perfFeeUser,
            poststate.curatorFee + poststate.protocolFee - (prestate.curatorFee + prestate.protocolFee),
            _delta_,
            "Performance fee should be calculated correctly"
        );
    }
}

contract RedeemPreSettlementAccruralTest is RedeemAccruralTest {
    function test_Accrue(uint256 shares, int256 yield) public {
        _test_Accrue(shares, yield, false);
    }

    function execute_accrue(Context memory context) internal override {
        uint256 principal = bound(context.seed, 0, _max_redeem(context.src));
        _approve(principalToken, context.src, context.users[2], principal);
        prop_redeem(context.users[2], context.users[1], context.src, principal);
    }
}

/// @dev Test redeeming after settlement
contract RedeemPostSettlementAccruralTest is RedeemAccruralTest {
    function test_Accrue(uint256 shares, int256 yield) public {
        _test_Accrue(shares, yield, true);
    }

    function execute_accrue(Context memory context) internal override {
        require(context.prestate.isSettled, "Setup: Pre-state should be settled");
        uint256 principal = bound(context.seed, 0, _max_redeem(context.src));
        _approve(principalToken, context.src, context.users[2], principal);
        prop_redeem(context.users[2], context.users[1], context.src, principal);
    }

    function assert_accrue(Context memory context) internal view override {
        super.assert_accrue(context);
    }
}

/// @dev Test redeeming after settlement with maximum performance fee setting (100%)
contract RedeemPostSettlement_MaximumPerformanceFee_AccruralTest is PrincipalTokenTest {
    function execute_accrue(Context memory context) internal {
        require(context.prestate.isSettled, "Setup: Pre-state should be settled");
        uint256 principal = bound(context.seed, 0, _max_redeem(context.src));
        _approve(principalToken, context.src, context.users[2], principal);
        prop_redeem(context.users[2], context.users[1], context.src, principal);
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
        prop_redeem(context.src, context.src, context.src, 0); // Settle

        for (uint256 i = 0; i < N; i++) {
            context.yield = bound(yields[i], type(int80).min, type(int80).max);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }
}

contract PreviewRedeemTest is PrincipalTokenTest {
    function testFuzz_Preview(Init memory init, uint256 principal, uint64 timeJump, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        address owner = init.user[2];
        address other = init.user[3];
        principal = bound(principal, 0, _max_redeem(owner));
        _approve(principalToken, owner, caller, type(uint256).max);

        skip(expiry + timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        prop_previewRedeem(caller, receiver, owner, other, principal);
    }

    function test_WhenNotExpired() public view {
        assertEq(principalToken.previewRedeem(100), 0, "Should return 0 when not expired");
    }

    function testFuzz_MaxRedeem(Init memory init) public boundInit(init) {
        setUpVault(init);
        prop_max_redeem(init.user[0], init.user[1]);
    }
}
