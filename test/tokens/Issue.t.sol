// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import "src/Constants.sol" as Constants;
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {ISupplyHook} from "src/interfaces/IHook.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract IssueTest is PrincipalTokenTest {
    function test_Issue() public {
        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(418338988), 76843, 53423, 31287], // I randomly smashed my keyboard
            principal: [uint256(1234567), 8791077, 751446, 777],
            yield: 2e18
        });
        uint256 principal = 68164;
        uint256 allowance = type(uint256).max;
        _test_Issue(init, principal, allowance);
    }

    function testFuzz_Issue(Init memory init, uint256 principal, uint256 allowance, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Issue(init, principal, allowance);
    }

    /// @notice Test `issue` function
    function _test_Issue(Init memory init, uint256 principal, uint256 allowance) internal {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        principal = bound(principal, 0, _max_issue(caller));
        _approve(target, caller, address(principalToken), allowance);
        prop_issue(caller, receiver, principal);
    }

    function test_RevertWhen_Expired() public {
        expectRevert_Expired();
        principalToken.issue(22, alice);
    }

    function test_RevertWhen_Paused() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = principalToken.pause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        // Prepare - Pause the principalToken
        vm.prank(dev);
        principalToken.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        principalToken.issue(100, alice);
    }

    function test_RevertWhen_CollectRewardFailed() public {
        vm.skip(true);
    }

    function test_RevertWhen_BadRewardProxy() public {
        setUpVault(
            Init({
                user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
                share: [uint256(1e18), 90331, 381039, 0],
                principal: [uint256(2192092), 189310, 0, 0],
                yield: 31093213131
            })
        );

        setBadRewardProxy();

        deal(address(target), alice, 10000);
        _approve(target, alice, address(principalToken), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.PrincipalToken_UnderlyingTokenBalanceChanged.selector);
        principalToken.issue(88888, alice);
    }
}

// TODO
// contract IssueAccrualTest is PrincipalTokenTest {
// }

contract MockSupplyCallbacker is ISupplyHook {
    function onSupply(uint256 shares, uint256, /* principal */ bytes calldata data) external override {
        bool expectInsufficientSharesError = abi.decode(data, (bool));
        if (expectInsufficientSharesError) shares -= 1;
        ERC20(PrincipalToken(msg.sender).underlying()).transfer(msg.sender, shares);
    }
}

contract IssueWithCallback is IssueTest {
    bool s_expectInsufficientSharesError;

    function prop_issue(address caller, address receiver, uint256 principal) public override {
        assumeNotPrecompile(caller);
        vm.etch(caller, type(MockSupplyCallbacker).runtimeCode);

        uint256 oldCallerShares = target.balanceOf(caller);
        uint256 oldReceiverPrincipal = principalToken.balanceOf(receiver);

        vm.prank(caller);
        uint256 shares = _pt_issue(principal, receiver);

        uint256 newCallerShare = target.balanceOf(caller);
        uint256 newReceiverPrincipal = principalToken.balanceOf(receiver);

        assertApproxEqAbs(newCallerShare, oldCallerShares - shares, _delta_, "share"); // NOTE: this may fail if the caller is a contract in which the asset is stored
        assertApproxEqAbs(newReceiverPrincipal, oldReceiverPrincipal + principal, _delta_, "principal");
    }

    function _pt_issue(uint256 principal, address receiver) internal override returns (uint256) {
        return _call_pt(
            abi.encodeWithSignature(
                "issue(uint256,address,bytes)", principal, receiver, abi.encode(s_expectInsufficientSharesError)
            )
        );
    }

    function test_RevertWhen_InsufficientShares() public {
        s_expectInsufficientSharesError = true;
        vm.etch(alice, type(MockSupplyCallbacker).runtimeCode);
        deal(address(target), alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(Errors.PrincipalToken_InsufficientSharesReceived.selector);
        principalToken.issue(88888, alice, abi.encode(s_expectInsufficientSharesError));
    }
}

contract PreviewIssueTest is PrincipalTokenTest {
    /// @notice Test `previewIssue` function
    function testFuzz_Preview(Init memory init, uint256 principal, uint64 timeJump, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        address other = init.user[2];
        principal = bound(principal, 0, _max_issue(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);

        skip(timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);
        prop_previewIssue(caller, receiver, other, principal);
    }

    function test_WhenExpired() public {
        vm.warp(expiry);
        assertEq(principalToken.previewIssue(2424413), 0, "Should return 0 when expired");
    }

    function test_WhenPaused(Init memory init) public boundInit(init) {
        setUpVault(init);

        // Prepare - Pause the principalToken
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});
        vm.prank(dev);
        principalToken.pause();

        assertEq(principalToken.previewIssue(12121), 0, "Preview should return 0 when paused");
    }
}
