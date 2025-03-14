// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Snapshot} from "src/utils/YieldMathLib.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import {Events} from "src/Events.sol";

contract CollectTest is PrincipalTokenTest {
    function test_RevertWhen_NotApproved() public {
        vm.expectRevert(Errors.PrincipalToken_NotApprovedCollector.selector);
        vm.prank(alice);
        principalToken.collect(bob, bob);
    }

    function test_RevertWhen_RewardTokenIsUnderlying() public {
        require(rewardTokens.length > 1, "TEST-ASSUMPTION: Need at least 2 reward tokens");
        rewardTokens[1] = address(target);

        // Replace rewardProxy with bad RewardProxy that tries to collect underlying token.
        bytes memory immutableArgs = abi.encode(principalToken, abi.encode(rewardTokens, multiRewardDistributor));
        address newRewardProxy = LibClone.clone(mockRewardProxy_logic, immutableArgs);
        vm.etch(address(rewardProxy), newRewardProxy.code);

        vm.expectRevert(Errors.PrincipalToken_ProtectedToken.selector);
        vm.prank(alice);
        principalToken.collect(bob, alice);
    }

    /// @dev Collect twice to ensure no interest is accrued in the second collection
    function test_NoInterest(Init memory init) public boundInit(init) {
        setUpVault(init);

        vm.startPrank(alice);
        principalToken.collect(alice, alice);
        (uint256 shares,) = principalToken.collect(bob, alice);

        assertEq(shares, 0, "No interest to collect");
    }

    function test_Event() public {
        address mike = makeAddr("mike");
        vm.prank(alice);
        principalToken.setApprovalCollector(mike, true);

        vm.expectEmit(true, true, true, false);
        emit Events.InterestCollected({by: mike, receiver: bob, owner: alice, shares: 0});

        vm.prank(mike);
        principalToken.collect(bob, alice);
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
        principalToken.collect(alice, alice);
    }
}

contract CollectAccrualTest is PrincipalTokenTest {
    function execute_accrue(Context memory context) internal {
        vm.prank(context.users[0]);
        principalToken.setApprovalCollector(context.users[2], true);

        vm.recordLogs();
        prop_collect({caller: context.users[2], receiver: context.users[1], owner: context.users[0]});
    }

    function assert_accrue(Context memory context) internal virtual {
        State memory prestate = context.prestate;
        State memory poststate = context.poststate;

        Vm.Log memory log = getLatestLogByTopic0(keccak256("YieldAccrued(address,uint256,uint256)"));
        (uint256 accrued,) = abi.decode(log.data, (uint256, uint256));

        assertEq(poststate.accrued, 0, "Pending interest is zero after collection");
        // Compute interest accrued by the user
        uint256 performanceFeePct = prestate.isSettled
            ? getPostSettlementFeePctBps(feeModule.getFeePcts())
            : getPerformanceFeePctBps(feeModule.getFeePcts());

        uint256 perfFeeUser = context.profit * performanceFeePct / BASIS_POINTS;
        uint256 expectAccrued = context.profit - perfFeeUser;
        assertGe(
            poststate.snapshot.globalIndex.unwrap(), prestate.snapshot.globalIndex.unwrap(), Property.T04_YIELD_INDEX
        );
        assertApproxLeAbs(accrued, expectAccrued, _delta_, Property.T01_INTEREST_ACCURAL);
    }
}

contract CollectPreSettlementAccrualTest is CollectAccrualTest {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();

        // For the sake of simplicity, issuance fee is zero.
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 100, 0, 5000); // 30% split fee, 1% perf fee, 50% post settlement fee
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
        context.src = init.user[0];

        // 1th update
        init.yield = 0;
        setUpVault(init);

        // 2nd update
        uint256 prev = resolver.scale();
        prop_accrue(context, execute_accrue, assert_accrue);

        address receiver = context.users[1];
        uint256 accrued = target.balanceOf(receiver) - init.share[1];
        assertApproxEqAbs(resolver.scale(), 4 * prev, 1, "4x previous scale");
        assertEq(context.poststate.accrued, 0, "Pending interest is zero after collection");
        assertApproxEqAbs(accrued, tOne * 75 / 10, 1, "Alice accrued 7.5 shares equivalent interest");
    }

    /// @dev Conditions:
    /// - Single user accrues yield
    function testFuzz_Accrue_0(Init memory init) public boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[0];

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
        context.src = init.user[0];

        init.yield = 0;
        setUpVault(init);

        for (uint256 i = 0; i < 3; i++) {
            context.yield = bound(context.yield + yields[i], type(int80).min, type(int80).max);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }

    function test_Equivalence(Init memory init) public boundInit(init) {
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 100, 0, 5000); // 30% split fee, 1% perf fee, 50% post settlement fee
        setFeePcts(newFeePcts);

        init.yield = int80(int256(10 * bOne));
        int256 yield = int256(12 * bOne);

        // Ensure that the user has enough balance to collect
        // Small amount causes rounding errors in the accrued yield calculation
        address user0 = init.user[0];
        init.principal[0] = 100 * bOne;
        setUpVault(init);

        uint256 snapshot = vm.snapshot();

        // a)
        vm.prank(user0);
        (uint256 shares1,) = principalToken.collect(user0, user0);

        setUpYield(yield);

        vm.prank(user0);
        (uint256 shares2,) = principalToken.collect(user0, user0);

        // b)
        vm.revertTo(snapshot);

        setUpYield(yield);
        vm.prank(user0);
        (uint256 shares,) = principalToken.collect(user0, user0);

        uint256 sum = shares1 + shares2;
        assertApproxEqAbs(shares, sum, 5, Property.T04_ACCURAL_EQ);
    }
}

contract CollectPostSettlementAccrualTest is CollectAccrualTest {
    function setUp() public virtual override {
        super.setUp();

        // For the sake of simplicity, issuance fee is zero.
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, 100); // 30% split fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function test_Accrue_1() public {
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("goku"), makeAddr("vegeta")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            // No yield because the assertion calculates the `context.profit` based on the scale right before and the right after the collection.
            // Otherwise, the test would fail.
            yield: int256(0)
        });

        Context memory context;
        context.yield = int256(20 * bOne);
        context.users = init.user;
        context.src = init.user[0]; // caller

        setUpVault(init);

        // Settle
        vm.warp(expiry);
        prop_collect({caller: context.users[2], receiver: context.users[1], owner: context.users[2]});
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        prop_accrue(context, execute_accrue, assert_accrue);
    }

    function testFuzz_Accrue_0(Init memory init) public boundInit(init) {
        vm.skip(true);
    }
}

contract CollectPostSettlement_MaximumPerformanceFee_AccrualTest is CollectPostSettlementAccrualTest {
    function setUp() public override {
        super.setUp();

        // For the sake of simplicity, issuance fee is zero.
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 100, 0, BASIS_POINTS); // Maximum post settlement fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function testFuzz_Accrue_1(Init memory init, int40 extraYield) public boundInit(init) {
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[0];

        init.yield = 0;
        setUpVault(init);

        vm.warp(expiry);
        prop_collect({caller: context.users[2], receiver: context.users[1], owner: context.users[2]});

        context.yield = bound(extraYield, type(int80).min, type(int80).max);
        prop_accrue(context, execute_accrue, assert_accrue);
    }

    function assert_accrue(Context memory context) internal override {
        super.assert_accrue(context);

        State memory prestate = context.prestate;
        State memory poststate = context.poststate;

        assertEq(
            poststate.snapshot.globalIndex.unwrap(),
            prestate.snapshot.globalIndex.unwrap(),
            "It should not change because of maximum performance fee"
        );
    }
}

contract PreviewCollectTest is PrincipalTokenTest {
    function testFuzz_Preview(Init memory init, uint64 timeJump, FeePcts newFeePcts, bool settle)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address owner = init.user[1];
        address receiver = init.user[2];
        address other = init.user[3];

        vm.prank(owner);
        principalToken.setApprovalCollector(caller, true); // Caller is approved to collect on behalf of owner

        skip(timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        // There is 50% chance that the principalToken is settled before previewing the collection
        if (isExpired() && settle) {
            prop_collect({caller: alice, receiver: alice, owner: alice});
        }

        prop_previewCollect({caller: caller, receiver: receiver, owner: owner, other: other});
    }
}
