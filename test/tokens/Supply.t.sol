// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockBadRewardProxyModule} from "../mocks/MockRewardProxy.sol";

import "src/Constants.sol" as Constants;
import {ISupplyHook} from "src/interfaces/IHook.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import {Events} from "src/Events.sol";

contract SupplyTest is PrincipalTokenTest {
    function test_Supply() public {
        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287], // I randomly smashed my keyboard
            principal: [uint256(0), 0, 0, 0],
            yield: 0
        });

        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, BASIS_POINTS); // 30% split fee
        setFeePcts(newFeePcts);

        uint256 shares = 10 ** target.decimals();
        uint256 assets = 10 ** base.decimals();
        uint256 allowance = type(uint256).max;
        _test_Supply(init, shares, allowance);

        // Check the principal
        address receiver = init.user[1];
        assertEq(principalToken.balanceOf(receiver), assets, "PT mismatch");
        assertEq(yt.balanceOf(receiver), assets, "YT mismatch");
    }

    function testFuzz_Supply(Init memory init, uint256 shares, uint256 allowance, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Supply(init, shares, allowance);
    }

    /// @notice Test `supply` function
    function _test_Supply(Init memory init, uint256 shares, uint256 allowance) internal {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        shares = bound(shares, 0, _max_supply(caller));
        _approve(target, caller, address(principalToken), allowance);
        prop_supply(caller, receiver, shares);
    }

    function test_RevertWhen_Expired() public {
        expectRevert_Expired();
        principalToken.supply(22, alice);
    }

    function test_RevertWhen_Paused() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: dev, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        // Prepare - Pause the principalToken
        vm.prank(dev);
        principalToken.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        principalToken.supply(100, alice);
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

        deal(address(target), alice, 10);
        _approve(target, alice, address(principalToken), type(uint256).max);

        vm.prank(alice);
        vm.expectRevert(Errors.PrincipalToken_UnderlyingTokenBalanceChanged.selector);
        principalToken.supply(10, alice);
    }
}

contract SupplyAccrualTest is PrincipalTokenTest {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();

        // For the sake of simplicity, issuance fee is zero.
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 100, 0, BASIS_POINTS); // 30% split fee, 1% perf fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    /// @dev See YieldMathLib.sol natspec
    function test_Accrue_1() public {
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, BASIS_POINTS); // 30% split fee
        setFeePcts(newFeePcts);

        Init memory init = Init({
            user: [bob, alice, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(0), 0, 0, 0],
            principal: [uint256(10e6), 10e6, 0, 0],
            yield: 60e6
        });
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[1]; // receiver

        // 1th update
        init.yield = 0;
        setUpVault(init);

        // 2nd update
        uint256 prev = resolver.scale();
        prop_accrue(context, execute_accrue, assert_accrue);
        assertApproxEqAbs(resolver.scale(), 4 * prev, 1, "4x previous scale");
        assertApproxEqAbs(context.poststate.accrued, tOne * 75 / 10, 1, "Alice accrued 7.5 shares equivalent interest");

        // 3rd update
        context.yield = 80e6;
        prop_accrue(context, execute_accrue, assert_accrue);
        assertApproxEqAbs(
            context.poststate.accrued - context.prestate.accrued,
            tOne * 125 / 100,
            1,
            "Alice accrued 1.25 shares equivalent interest"
        );

        // 4th update
        context.yield = 0;
        context.users = [bob, bob, init.user[2], init.user[3]];
        _approve(target, context.users[0], address(principalToken), type(uint256).max);
        prop_supply(context.users[0], context.users[1], 0);
        assertApproxEqAbs(
            principalToken.getUserYield(context.users[1]).accrued,
            tOne * 875 / 100,
            1,
            "Bob accrued 8.75 shares equivalent interest"
        );
    }

    /// @dev Conditions:
    /// - Single user accrues yield
    function testFuzz_Accrue_0(Init memory init) public boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[1]; // receiver

        // TODO Refactor: optionally doesn't set up yield
        init.yield = 0;
        setUpVault(init);

        prop_accrue(context, execute_accrue, assert_accrue);

        uint256 expectFee;
        if (context.yield > 0) {
            // Calculate interest accrued by YTs and performance fee
            uint256 totalAssetsAccrued = uint256(context.yield);
            uint256 expectTotalAccrued =
                target.convertToShares(totalAssetsAccrued) * context.prestate.totalShares / context.prestate.shareSupply;
            expectFee = expectTotalAccrued.mulDivUp(getPerformanceFeePctBps(feeModule.getFeePcts()), BASIS_POINTS);
        }
        assertApproxLeAbs(
            context.poststate.curatorFee + context.poststate.protocolFee,
            expectFee + context.prestate.curatorFee + context.prestate.protocolFee,
            _delta_,
            "Fee is distributed to Curator and Napier"
        );
    }

    /// @dev Conditions:
    /// - Single user accrues yield multiple times with different accrued yield
    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) public boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[1]; // receiver

        init.yield = 0;
        setUpVault(init);

        for (uint256 i = 0; i < 3; i++) {
            context.yield = bound(context.yield + yields[i], type(int80).min, type(int80).max);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }

    function execute_accrue(Context memory context) internal {
        uint256 shares = bound(context.seed, 0, _max_supply(context.users[0]));
        _approve(target, context.users[0], address(principalToken), type(uint256).max);
        prop_supply(context.users[0], context.users[1], shares);
    }

    function assert_accrue(Context memory context) internal view {
        State memory prestate = context.prestate;
        State memory poststate = context.poststate;

        // Compute interest accrued by the user
        uint256 perfFeeUser = context.profit * getPerformanceFeePctBps(feeModule.getFeePcts()) / BASIS_POINTS;
        uint256 expectAccrued = context.profit - perfFeeUser;
        assertGe(
            poststate.snapshot.globalIndex.unwrap(), prestate.snapshot.globalIndex.unwrap(), Property.T04_YIELD_INDEX
        );
        assertApproxLeAbs(poststate.accrued, prestate.accrued + expectAccrued, _delta_, Property.T01_INTEREST_ACCURAL);
    }
}

contract MockSupplyCallbacker is ISupplyHook {
    function onSupply(uint256 shares, uint256, /* principal */ bytes calldata data) external override {
        bool expectInsufficientSharesError = abi.decode(data, (bool));
        if (expectInsufficientSharesError) shares -= 1;
        ERC20(PrincipalToken(msg.sender).underlying()).transfer(msg.sender, shares);
    }
}

contract SupplyWithCallbackTest is SupplyTest {
    bool s_expectInsufficientSharesError;

    function prop_supply(address caller, address receiver, uint256 shares) public override {
        assumeNotPrecompile(caller);
        vm.etch(caller, type(MockSupplyCallbacker).runtimeCode);

        uint256 oldCallerShares = target.balanceOf(caller);
        uint256 oldReceiverPrincipal = principalToken.balanceOf(receiver);

        vm.prank(caller);
        uint256 principal = _pt_supply(shares, receiver);

        uint256 newCallerShare = target.balanceOf(caller);
        uint256 newReceiverPrincipal = principalToken.balanceOf(receiver);

        assertApproxEqAbs(newCallerShare, oldCallerShares - shares, _delta_, "share"); // NOTE: this may fail if the caller is a contract in which the asset is stored
        assertApproxEqAbs(newReceiverPrincipal, oldReceiverPrincipal + principal, _delta_, "principal");
    }

    function _pt_supply(uint256 shares, address receiver) internal override returns (uint256) {
        (bool success, bytes memory retdata) = address(principalToken).call(
            abi.encodeWithSignature(
                "supply(uint256,address,bytes)", shares, receiver, abi.encode(s_expectInsufficientSharesError)
            )
        );
        if (success) return abi.decode(retdata, (uint256));
        vm.assume(false);
        return 0; // Silence warning
    }

    function test_RevertWhen_InsufficientShares() public {
        s_expectInsufficientSharesError = true;
        vm.etch(alice, type(MockSupplyCallbacker).runtimeCode);
        deal(address(target), alice, 1e18);

        vm.prank(alice);
        vm.expectRevert(Errors.PrincipalToken_InsufficientSharesReceived.selector);
        principalToken.supply(88888, alice, abi.encode(s_expectInsufficientSharesError));
    }
}

contract PreviewSupplyTest is PrincipalTokenTest {
    /// @notice Test `previewSupply` function
    function testFuzz_Preview(Init memory init, uint256 shares, uint64 timeJump, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        address other = init.user[2];
        shares = bound(shares, 0, _max_supply(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);

        skip(timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);
        prop_previewSupply(caller, receiver, other, shares);
    }

    function test_WhenExpired() public {
        vm.warp(expiry);
        assertEq(principalToken.previewSupply(2424413), 0, "Should return 0 when expired");
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

        assertEq(principalToken.previewSupply(29291), 0, "Preview should return 0 when paused");
    }
}
