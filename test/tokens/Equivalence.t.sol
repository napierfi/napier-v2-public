// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import {FeePcts} from "src/Types.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

/// @dev Test the equivalence of the supply/issue, unite/combine, and redeem/withdraw functions.
contract EquivalenceTest is PrincipalTokenTest {
    /// @dev Toy parameters to test the equivalence of the functions.
    FeePcts toyFeePcts = FeePctsLib.pack(5_000, 100, 333, 100, 210);
    Init init = Init({
        user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
        share: [uint256(3194194190381), 768143, 9009323, 493099072],
        principal: [uint256(4379538980), 586112852, 4058900, 137425],
        yield: 1289033283018
    });

    function setUp() public override {
        super.setUp();
        _delta_ = 1;
    }

    function setUpVault() internal {
        uint256 lscale = resolver.scale();
        setUpVault(init);
        require(resolver.scale() > lscale, "TEST: Scale must be greater than initial scale");
        console2.log("resolver.scale()  :>>", resolver.scale());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Supply/Issue                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_EQ_Supply() public {
        setUpVault();
        address caller = init.user[0];
        uint256 shares = 1131313;
        setFeePcts(toyFeePcts);

        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_EQ_Supply(caller, shares, block.timestamp);
    }

    // p = supply(s)
    // s' = issue(p)
    // s' ~= s
    // Note Actually in some cases where input is small or fee pct is high, the difference can be significant due to rounding.
    // But in general, the difference should be within a small range.
    // Same applies to other functions.
    function prop_EQ_Supply(address caller, uint256 shares, uint256 timestamp) public {
        vm.assume(target.totalSupply() > 0);
        vm.warp(timestamp);

        uint256 snapshot = vm.snapshot();

        vm.prank(caller);
        uint256 principal = _pt_supply(shares, caller);
        vm.revertTo(snapshot);

        vm.prank(caller);
        uint256 shares2 = _pt_issue(principal, caller);
        assertApproxEqAbs(shares2, shares, _delta_, "Equivalence:supply_issue");
    }

    function test_EQ_PreviewSupply() public {
        setUpVault();

        address caller = init.user[0];
        uint256 shares = 131087;
        uint256 timestamp = block.timestamp + 10 days;
        setFeePcts(toyFeePcts);

        _approve(target, caller, address(principalToken), type(uint256).max);
        prop_EQ_PreviewSupply(caller, shares, timestamp);
    }

    // p = previewSupply(s)
    // s' = previewIssue(p)
    // s' ~= s
    function prop_EQ_PreviewSupply(address caller, uint256 shares, uint256 timestamp) public {
        vm.assume(target.totalSupply() > 0);
        vm.warp(timestamp);

        vm.prank(caller);
        uint256 principal = _pt_previewSupply(shares);

        vm.prank(caller);
        uint256 shares2 = _pt_previewIssue(principal);
        assertApproxEqAbs(shares2, shares, _delta_, "Equivalence:previewSupply_previewIssue");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        Unite/Combine                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_EQ_Unite() public {
        setUpVault();
        address caller = init.user[0];
        uint256 shares = 32834801;
        setFeePcts(toyFeePcts);

        prop_EQ_Unite(caller, shares, block.timestamp);
    }

    // p = unite(s)
    // s = combine(p)
    // s' ~= s
    function prop_EQ_Unite(address caller, uint256 shares, uint256 timestamp) public {
        vm.assume(target.totalSupply() > 0);
        vm.warp(timestamp);

        uint256 snapshot = vm.snapshot();

        vm.prank(caller);
        uint256 principal = _pt_unite(shares, caller);
        vm.revertTo(snapshot);

        vm.prank(caller);
        uint256 shares2 = _pt_combine(principal, caller);
        assertApproxEqAbs(shares2, shares, _delta_, "Equivalence:unite_combine");
    }

    function test_EQ_PreviewUnite(uint96 timeJump) public {
        setUpVault();
        address caller = init.user[0];
        uint256 shares = 13138980134;
        setFeePcts(toyFeePcts);

        prop_EQ_PreviewUnite(caller, shares, timeJump);
    }

    // p = previewUnite(s)
    // s = previewCombine(p)
    // s' ~= s
    function prop_EQ_PreviewUnite(address caller, uint256 shares, uint256 timeJump) public {
        vm.assume(target.totalSupply() > 0);
        skip(timeJump);

        vm.prank(caller);
        uint256 principal = _pt_previewUnite(shares);

        vm.prank(caller);
        uint256 shares2 = _pt_previewCombine(principal);
        assertApproxEqAbs(shares2, shares, _delta_, "Equivalence:previewUnite_previewCombine");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      Withdraw/Redeem                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_EQ_Redeem() public {
        setUpVault();
        address caller = init.user[0];
        uint256 shares = 136131;
        setFeePcts(toyFeePcts);

        prop_EQ_Redeem(caller, shares);
    }

    // p = withdraw(s)
    // s' = redeem(p)
    // s' ~= s
    function prop_EQ_Redeem(address caller, uint256 shares) public {
        vm.assume(target.totalSupply() > 0);
        vm.warp(expiry);
        uint256 snapshot = vm.snapshot();

        vm.prank(caller);
        uint256 principal = _pt_withdraw(shares, caller, caller);
        vm.revertTo(snapshot);

        vm.prank(caller);
        uint256 shares2 = _pt_redeem(principal, caller, caller);
        assertApproxEqAbs(shares2, shares, _delta_, "Equivalence:withdraw_redeem");
    }

    function test_EQ_PreviewRedeem() public {
        setUpVault();
        address caller = init.user[0];
        uint256 shares = 390801;
        setFeePcts(toyFeePcts);

        prop_EQ_PreviewRedeem(caller, shares);
    }

    // If expred,
    // p = previewWithdraw(s)
    // s' = previewRedeem(p)
    // s' ~= s
    // If not expired, both functions should always return 0 no matter what the input is.
    function prop_EQ_PreviewRedeem(address caller, uint256 shares) public {
        vm.assume(target.totalSupply() > 0);
        vm.warp(expiry);

        vm.prank(caller);
        uint256 principal = _pt_previewWithdraw(shares);

        vm.prank(caller);
        uint256 shares2 = _pt_previewRedeem(principal);
        assertApproxEqAbs(shares2, shares, _delta_, "Equivalence:previewWithdraw_previewRedeem");
    }
}
