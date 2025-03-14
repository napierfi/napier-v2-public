// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

contract RoundTripConversionTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 0;
    }

    function test_RT_principal_underlying(Init memory init, uint256 shares, uint96 timeJump) public boundInit(init) {
        setUpVault(init);
        skip(timeJump);

        uint256 principal = _pt_convertToPrincipal(shares);
        uint256 shares2 = _pt_convertToUnderlying(principal);
        assertLe(shares2, shares, "convertToUnderlying(convertToPrincipal(s)) <= s");
    }
}

contract RoundTripSupplyTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 0;
    }

    function test_RT_supply_combine(Init memory init, uint256 shares, uint96 timestamp) public boundInit(init) {
        setUpVault(init);
        address caller = init.user[0];
        shares = bound(shares, 0, _max_supply(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_supply_combine(caller, shares, timestamp);
    }

    // combine(supply(s)) <= s
    function prop_RT_supply_combine(address caller, uint256 shares, uint256 timestamp) public {
        vm.assume(target.totalSupply() > 0);
        vm.prank(caller);
        uint256 principal = _pt_supply(shares, caller);
        vm.warp(timestamp);
        vm.prank(caller);
        uint256 shares2 = _pt_combine(principal, caller);
        assertApproxLeAbs(shares2, shares, _delta_, Property.RT_SUPPLY_COMBINE);
    }

    function test_RT_supply_unite(Init memory init, uint256 shares) public boundInit(init) {
        setUpVault(init);
        address caller = init.user[0];
        shares = bound(shares, 0, _max_supply(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_supply_unite(caller, shares);
    }

    // p = supply(s)
    // p' = unite(s)
    // p' >= p
    function prop_RT_supply_unite(address caller, uint256 shares) public {
        vm.assume(target.totalSupply() > 0);
        vm.prank(caller);
        uint256 principal = _pt_supply(shares, caller);
        vm.prank(caller);
        uint256 principal2 = _pt_unite(shares, caller);
        assertApproxLeAbs(principal, principal2, _delta_, Property.RT_SUPPLY_UNITE);
    }

    function test_RT_supply_redeem(Init memory init, uint256 shares) public boundInit(init) {
        setUpVault(init);
        address caller = init.user[0];
        shares = bound(shares, 0, _max_supply(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_supply_redeem(caller, shares);
    }

    // redeem(supply(s)) <= s
    function prop_RT_supply_redeem(address caller, uint256 shares) public {
        vm.assume(target.totalSupply() > 0);
        vm.prank(caller);
        uint256 principal = _pt_supply(shares, caller);
        vm.warp(expiry); // expire the principalToken
        vm.prank(caller);
        uint256 shares2 = _pt_redeem(principal, caller, caller);
        assertApproxLeAbs(shares2, shares, _delta_, Property.RT_SUPPLY_REDEEM);
    }

    function prop_RT_supply_withdraw(address caller, uint256 shares) public {
        vm.assume(target.totalSupply() > 0);
        vm.prank(caller);
        uint256 principal = _pt_supply(shares, caller);
        vm.warp(expiry);
        vm.prank(caller);
        uint256 principal2 = _pt_withdraw(shares, caller, caller);
        assertApproxGeAbs(principal2, principal, _delta_, Property.RT_SUPPLY_WITHDRAW);
    }

    // p = supply(s)
    // p' = withdraw(s)
    // p' >= p
    function test_RT_supply_withdraw(Init memory init, uint256 shares) public boundInit(init) {
        setUpVault(init);
        address caller = init.user[0];
        shares = bound(shares, 0, _max_supply(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_supply_withdraw(caller, shares);
    }
}

contract RoundTripCombineTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 0;
    }

    function test_RT_combine_supply(Init memory init, uint256 principal) public virtual {
        setUpVault(init);
        address caller = init.user[0];
        principal = bound(principal, 0, _max_combine(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_combine_supply(caller, principal);
    }

    // supply(combine(p)) <= p
    function prop_RT_combine_supply(address caller, uint256 principal) public {
        vm.prank(caller);
        uint256 shares = _pt_combine(principal, caller);
        vm.assume(target.totalSupply() > 0);
        vm.prank(caller);
        uint256 principal2 = _pt_supply(shares, caller);
        assertApproxLeAbs(principal2, principal, _delta_, Property.RT_COMBINE_SUPPLY);
    }

    function test_RT_issue_combine(Init memory init, uint256 principal) public virtual {
        setUpVault(init);
        address caller = init.user[0];
        principal = bound(principal, 0, _max_issue(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_issue_combine(caller, principal);
    }

    // combine(issue(p)) <= p
    function prop_RT_issue_combine(address caller, uint256 principal) public {
        vm.prank(caller);
        uint256 shares = _pt_issue(principal, caller);
        vm.prank(caller);
        uint256 principal2 = _pt_combine(shares, caller);
        assertApproxLeAbs(principal2, principal, _delta_, Property.RT_ISSUE_COMBINE);
    }
}

contract RoundTripUniteTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 0;
    }

    function test_RT_unite_supply(Init memory init, uint256 shares) public virtual {
        setUpVault(init);
        address caller = init.user[0];
        shares = bound(shares, 0, _max_unite(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_unite_supply(caller, shares);
    }

    function prop_RT_unite_supply(address caller, uint256 shares) public {
        vm.prank(caller);
        uint256 principal = _pt_unite(shares, caller);
        vm.assume(target.totalSupply() > 0);
        vm.prank(caller);
        uint256 principal2 = _pt_supply(shares, caller);
        assertApproxLeAbs(principal2, principal, _delta_, Property.RT_COMBINE_SUPPLY);
    }

    function test_RT_issue_unite(Init memory init, uint256 principal) public virtual {
        setUpVault(init);
        address caller = init.user[0];
        principal = bound(principal, 0, _max_issue(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_RT_issue_unite(caller, principal);
    }

    // combine(issue(p)) <= p
    function prop_RT_issue_unite(address caller, uint256 principal) public {
        vm.prank(caller);
        uint256 shares = _pt_issue(principal, caller);
        vm.prank(caller);
        uint256 principal2 = _pt_combine(shares, caller);
        assertApproxLeAbs(principal2, principal, _delta_, Property.RT_ISSUE_COMBINE);
    }
}
