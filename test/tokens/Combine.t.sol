// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {IUniteHook} from "src/interfaces/IHook.sol";
import {Snapshot} from "src/utils/YieldMathLib.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract CombinePreExpiryTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 2;
    }

    function test_Combine() public {
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(bOne)
        });

        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // 70% split fee
        setFeePcts(newFeePcts);

        uint256 principal = 10 * bOne;
        _test_Combine(init, principal);

        address caller = init.user[0];
        address receiver = init.user[1];
        assertEq(principalToken.balanceOf(caller), init.principal[0] - principal, "PT mismatch");
        assertEq(yt.balanceOf(caller), init.principal[0] - principal, "YT mismatch");
        // 1 PT + 1 YT = 1 shares
        assertApproxEqAbs(
            target.balanceOf(receiver) + principalToken.getUserYield(caller).accrued - init.share[1],
            shares,
            _delta_,
            "shares mismatch"
        );
    }

    // Check 1 PT + 1 YT = 1 shares
    function testFuzz_Equivalence(uint256 shares, int256 yield) public {
        _delta_ = 5;
        // Note Too small amount results in precision loss in interest calculation,
        // which makes test assertion fails.
        // So, yield and YT balance should be large enough for the sake of simplicity.
        shares = bound(shares, tOne, 1e9 * tOne);

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(100 * bOne) // Large enough
        });

        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // For the sake of simplicity, zero fee
        setFeePcts(newFeePcts);

        setUpVault(init);

        address caller = init.user[0];
        shares = bound(shares, 0, _max_supply(caller));
        yield = bound(yield, type(int80).min, type(int80).max);
        prop_combine_equivalence(caller, shares, yield);
    }

    function prop_combine_equivalence(address caller, uint256 shares, int256 yield) public {
        _approve(target, caller, address(principalToken), type(uint256).max);
        vm.prank(caller);
        uint256 principal = _pt_supply(shares, caller);
        // At this point, caller have already accrued interest.

        uint256 oldAccrued = principalToken.getUserYield(caller).accrued;
        uint256 oldYtBalance = yt.balanceOf(caller);
        uint256 oldPtBalance = principalToken.balanceOf(caller);

        setUpYield(yield); // Loss or gain

        // Again, caller accrues new interest since the last supply.
        vm.prank(caller);
        uint256 shares2 = _pt_combine(principal, caller);

        uint256 newAccrued = principalToken.getUserYield(caller).accrued;
        uint256 newYtBalance = yt.balanceOf(caller);
        uint256 newPtBalance = principalToken.balanceOf(caller);

        assertEq(newPtBalance, oldPtBalance - principal, "PT mismatch");
        assertEq(newYtBalance, oldYtBalance - principal, "YT mismatch");
        // `combine` doesn't collect accrued interest. The accrued interest is produced by the user's YTs.
        assertApproxEqAbs(
            shares2 + (newAccrued - oldAccrued) * principal / oldYtBalance, shares, _delta_, "shares mismatch"
        );
    }

    function testFuzz_Combine(Init memory init, uint256 principal, FeePcts newFeePcts) public boundInit(init) {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Combine(init, principal);
    }

    /// @notice Test `combine` function
    function _test_Combine(Init memory init, uint256 principal) internal {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        principal = bound(principal, 0, _max_combine(caller));
        prop_combine(caller, receiver, principal);
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

        vm.prank(alice);
        vm.expectRevert(Errors.PrincipalToken_UnderlyingTokenBalanceChanged.selector);
        principalToken.combine(100, alice);
    }
}

contract CombineSettlementTest is PrincipalTokenTest {
    function test_Settle() public {
        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // 0 % performance fee
        setFeePcts(newFeePcts);

        _delta_ = 2;
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(bOne)
        });

        // Execution
        uint256 principal = 10 * bOne;
        _test_Combine(init, principal, expiry);

        address caller = init.user[0];
        address receiver = init.user[1];
        uint256 newAccrued = principalToken.getUserYield(caller).accrued;

        // Common (Pre expiry)
        assertEq(principalToken.balanceOf(caller), init.principal[0] - principal, "PT mismatch");
        assertEq(yt.balanceOf(caller), init.principal[0] - principal, "YT mismatch");
        assertApproxEqAbs(target.balanceOf(receiver) + newAccrued - init.share[1], shares, _delta_, "shares mismatch");
        // Assertions
        assertGt(newAccrued, 0, Property.T01_INTEREST_ACCURAL);
        assertTrue(principalToken.isSettled(), "Settlement should be done");
    }

    /// @notice Test `combine` function at the timestamp of `ts`
    function _test_Combine(Init memory init, uint256 principal, uint256 ts) internal {
        require(ts >= expiry, "TEST: Invalid ts");
        setUpVault(init);

        vm.warp(ts);

        address caller = init.user[0];
        address receiver = init.user[1];
        principal = bound(principal, 0, _max_combine(caller));
        prop_combine(caller, receiver, principal);
    }
}

contract CombinePostSettlementTest is PrincipalTokenTest {
    function test_Combine() public {
        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // 0 % performance fee
        setFeePcts(newFeePcts);

        _delta_ = 2;
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("bocchi"), makeAddr("nijika")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(bOne)
        });

        setUpVault(init); // Yield before settlement

        // Settle
        address caller = init.user[0];
        vm.warp(expiry);
        prop_combine(caller, caller, 0); // combine 0 principal to trigger settlement
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        setUpYield(int256(bOne)); // Yield after settlement

        // Execution
        uint256 principal = 10 * bOne;
        address receiver = init.user[1];
        vm.recordLogs();
        _test_Combine(init, principal); // Combine all principal and YT

        // Post state
        Vm.Log memory log = getLatestLogByTopic0(keccak256("YieldFeeAccrued(uint256)"));
        uint256 fee = abi.decode(log.data, (uint256)); // Interest from the settlement to the last interaction

        // Assertions
        uint256 accrued = principalToken.getUserYield(caller).accrued; // Interest from the first issuance to the settlement
        assertApproxEqAbs(
            target.balanceOf(receiver) + accrued + fee - init.share[1], shares, _delta_, "shares mismatch"
        );
    }

    function testFuzz_Combine(Init memory init, uint256 principal, FeePcts newFeePcts) public boundInit(init) {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        setUpVault(init);

        address caller = init.user[0];
        vm.warp(expiry); // Settle
        prop_combine(caller, caller, 0); // combine 0 principal to trigger settlement
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        _test_Combine(init, principal);
    }

    /// @notice Test `combine` function at the timestamp of `ts`
    function _test_Combine(Init memory init, uint256 principal) internal {
        address caller = init.user[0];
        address receiver = init.user[1];

        Snapshot memory oldS = principalToken.getSnapshot();
        uint256 oldAccrued = principalToken.getUserYield(caller).accrued;

        principal = bound(principal, 0, _max_combine(caller));
        prop_combine(caller, receiver, principal);

        Snapshot memory newS = principalToken.getSnapshot();
        uint256 newAccrued = principalToken.getUserYield(caller).accrued;

        assertEq(newS.globalIndex.unwrap(), oldS.globalIndex.unwrap(), "Post settlemnet globalIndex should not change");
        // TEST-ASSUMPTION: the caller has already accrued interest produced before making `combine` call.
        assertEq(newAccrued, oldAccrued, Property.T01_INTEREST_ACCURAL);
    }
}

abstract contract CombineAccrualTest is PrincipalTokenTest {
    using FixedPointMathLib for uint256;

    /// @dev Conditions:
    /// - Single user accrues yield
    function _testFuzz_Accrue_0(Init memory init, bool settle) internal boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[1]; // receiver

        // TODO Refactor: optionally doesn't set up yield
        init.yield = 0;
        setUpVault(init);

        if (settle) {
            vm.warp(expiry);
            prop_combine(init.user[2], init.user[2], 0); // combine 0 principal to trigger settlement
            assertTrue(principalToken.isSettled(), "Settlement should be done");
        }

        prop_accrue(context, execute_accrue, assert_accrue);

        uint256 expectFee;
        if (context.yield > 0) {
            // Calculate interest accrued by YTs and performance fee
            uint256 totalAssetsAccrued = uint256(context.yield);
            uint256 expectTotalAccrued =
                target.convertToShares(totalAssetsAccrued) * context.prestate.totalShares / context.prestate.shareSupply;

            uint256 performanceFeePct = context.prestate.isSettled
                ? getPostSettlementFeePctBps(feeModule.getFeePcts())
                : getPerformanceFeePctBps(feeModule.getFeePcts());

            expectFee = expectTotalAccrued.mulDivUp(performanceFeePct, BASIS_POINTS);
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
    function _testFuzz_Accrue_1(Init memory init, int40[3] memory yields, bool settle) internal boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[1]; // receiver

        init.yield = 0;
        setUpVault(init);

        if (settle) {
            vm.warp(expiry);
            prop_combine(init.user[2], init.user[2], 0); // combine 0 principal to trigger settlement
            assertTrue(principalToken.isSettled(), "Settlement should be done");
        }

        for (uint256 i = 0; i < 3; i++) {
            context.yield = bound(context.yield + yields[i], type(int80).min, type(int80).max);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }

    function execute_accrue(Context memory context) internal virtual {
        vm.recordLogs();
        uint256 principal = bound(context.seed, 0, _max_combine(context.users[0]));
        prop_combine(context.users[0], context.users[1], principal);
    }

    function assert_accrue(Context memory context) internal view virtual {
        State memory prestate = context.prestate;
        State memory poststate = context.poststate;

        // Compute interest accrued by the user
        uint256 performanceFeePct = context.prestate.isSettled
            ? getPostSettlementFeePctBps(feeModule.getFeePcts())
            : getPerformanceFeePctBps(feeModule.getFeePcts());

        uint256 perfFeeUser = context.profit * performanceFeePct / BASIS_POINTS;
        uint256 expectAccrued = context.profit - perfFeeUser;
        assertGe(
            poststate.snapshot.globalIndex.unwrap(), prestate.snapshot.globalIndex.unwrap(), Property.T04_YIELD_INDEX
        );
        assertApproxLeAbs(poststate.accrued, prestate.accrued + expectAccrued, _delta_, Property.T01_INTEREST_ACCURAL);
    }
}

// combinePreSettlemtnとpostSettlementを比べて共通部分を抽出
contract CombinePreSettlementAccrualTest is CombineAccrualTest {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();

        // For the sake of simplicity, issuance fee is zero.
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 100, 0, BASIS_POINTS); // 30% split fee, 1% perf fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function test_Accrue_1() public {
        // 0 % performance fee for the sake of simplicity
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, BASIS_POINTS); // 30% split fee
        setFeePcts(newFeePcts);

        Init memory init = Init({
            user: [alice, bob, makeAddr("L"), makeAddr("kira")],
            share: [uint256(0), 0, 0, 0],
            principal: [uint256(10e6), 10e6, 0, 0],
            yield: 60e6
        });
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[0]; // caller

        // 1th update
        init.yield = 0;
        setUpVault(init);

        // 2nd update
        uint256 prev = resolver.scale();
        prop_accrue(context, execute_accrue, assert_accrue);
        assertApproxEqAbs(resolver.scale(), 4 * prev, 1, "4x previous scale");
        assertApproxEqAbs(context.poststate.accrued, tOne * 75 / 10, 1, "Alice accrued 7.5 shares equivalent interest");
    }

    /// @dev Conditions:
    /// - Single user accrues yield
    function testFuzz_Accrue_0(Init memory init) public {
        _testFuzz_Accrue_0({init: init, settle: false});
    }

    /// @dev Conditions:
    /// - Single user accrues yield multiple times with different accrued yield
    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) public {
        _testFuzz_Accrue_1({init: init, yields: yields, settle: false});
    }
}

contract CombinePostSettlementAccuralTest is CombineAccrualTest {
    function setUp() public override {
        super.setUp();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, 3113); // 30% split fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function test_Accrue_1() public {
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("goku"), makeAddr("vegeta")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: 0
        });

        setUpVault(init);

        // Settle
        vm.warp(expiry);
        prop_combine(init.user[2], init.user[2], 0); // combine 0 principal to trigger settlement
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        Context memory context;
        context.yield = int256(2 * bOne);
        context.users = init.user;
        context.src = init.user[0]; // caller

        // 1th update after settlement
        context.yield = int256(10 * bOne);
        prop_accrue(context, execute_accrue, assert_accrue);

        // All interest accrued by YTs goes to performance fee
        Vm.Log memory log = getLatestLogByTopic0(keccak256("YieldFeeAccrued(uint256)"));
        uint256 fee = abi.decode(log.data, (uint256));
        uint256 profit =
            target.convertToShares(uint256(context.yield)) * context.prestate.totalShares / context.prestate.shareSupply;
        uint256 expectFee = profit * getPostSettlementFeePctBps(feeModule.getFeePcts()) / BASIS_POINTS;
        assertApproxEqAbs(fee, expectFee, 10, "Fee should be approx equal to profit");
        assertApproxEqAbs(context.poststate.accrued, profit - fee, 10, "Interest should be accrued");

        // 2nd update after settlement
        context.yield = int256(12 * bOne);
        prop_accrue(context, execute_accrue, assert_accrue);

        // 3rd update: Redeem all principal and YT
        prop_combine(init.user[0], init.user[0], principalToken.balanceOf(init.user[0]));

        // Assertions: Solvency check
        assertEq(principalToken.balanceOf(init.user[0]), 0, "PT should be zero");
        assertEq(yt.balanceOf(init.user[0]), 0, "YT should be zero");
        uint256 totalShares = target.balanceOf(address(principalToken));
        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        assertApproxEqAbs(totalShares, curatorFee + protocolFee + context.poststate.accrued, _delta_, "Solvency check");
    }

    /// @dev Conditions:
    /// - Single user accrues yield
    function testFuzz_Accrue_0(Init memory init) public {
        _testFuzz_Accrue_0({init: init, settle: true});
    }

    /// @dev Conditions:
    /// - Single user accrues yield multiple times with different accrued yield
    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) public {
        _testFuzz_Accrue_1({init: init, yields: yields, settle: true});
    }
}

contract Dummy is IUniteHook {
    function onUnite(uint256 shares, uint256 principal, bytes calldata data) external override {}
}

contract CombineWithCallbackPreExpiryTest is CombinePreExpiryTest {
    function prop_combine(address caller, address receiver, uint256 principal) public override {
        assumeNotPrecompile(caller);
        vm.etch(caller, type(Dummy).runtimeCode);

        super.prop_combine(caller, receiver, principal);
    }

    function _pt_combine(uint256 principal, address receiver) internal override returns (uint256) {
        (bool success, bytes memory retdata) = address(principalToken).call(
            abi.encodeWithSignature("combine(uint256,address,bytes)", principal, receiver, "")
        );
        if (success) return abi.decode(retdata, (uint256));
        vm.assume(false);
        return 0; // Silence warning
    }

    error InsufficientBalance(); // from solady SafeTransferLib

    function test_RevertWhen_InsufficientPtBalance() public {
        deal(address(target), address(principalToken), type(uint64).max); // donate

        vm.etch(alice, type(Dummy).runtimeCode);

        uint256 principal = 1e18;
        deal(address(principalToken), alice, principal - 1); // Insufficient PT
        deal(address(yt), alice, principal);

        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        principalToken.combine(principal, alice, abi.encode("junk"));
    }

    function test_RevertWhen_InsufficientYtBalance() public {
        deal(address(target), address(principalToken), type(uint64).max); // donate

        vm.etch(alice, type(Dummy).runtimeCode);

        uint256 principal = 1e18;
        deal(address(principalToken), alice, principal);
        deal(address(yt), alice, principal - 1); // Insufficient YT

        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        principalToken.combine(principal, alice, abi.encode("junk"));
    }
}

contract PreviewCombineTest is PrincipalTokenTest {
    /// @notice Test `previewCombine` function
    function testFuzz_Preview(Init memory init, uint256 principal, uint64 timeJump, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        address other = init.user[2];
        principal = bound(principal, 0, _max_combine(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);

        skip(timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        prop_previewCombine(caller, receiver, other, principal);
    }
}
