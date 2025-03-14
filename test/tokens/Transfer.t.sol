// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Snapshot, Yield} from "src/utils/YieldMathLib.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Reward} from "src/utils/RewardMathLib.sol";
import {Errors} from "src/Errors.sol";

contract TransferTest is PrincipalTokenTest {
    struct Transfer_State {
        Snapshot snapshot;
        uint256 ytSupply;
        uint256 totalShares; // target.balanceof(principalToken)
        uint256 shareSupply; // target.totalSupply()
        uint256 curatorFee;
        uint256 protocolFee;
        bool isSettled;
        bool isExpired;
    }

    struct User_State {
        uint256 accrued;
        uint256 userIndex;
        uint256 ytBalance;
        uint256 sharesBalance;
        Reward[] rewards;
    }

    struct TransferTest_Context {
        address caller;
        address[2] users;
        uint256 value; // amount of YT to transfer
        int256 yield;
        uint256 seed;
        uint256[2] profits;
        User_State[2] userPrestates;
        User_State[2] userPoststates;
        Transfer_State prestate;
        Transfer_State poststate;
    }

    function prop_accrue(
        TransferTest_Context memory context,
        function (TransferTest_Context memory) internal execute_accrue,
        function (TransferTest_Context memory) internal assert_accrue
    ) internal {
        require(context.caller != address(0), "TransferTest: caller not set");
        require(context.users[0] != address(0), "TransferTest: src not set");
        require(context.users[1] != address(0), "TransferTest: receiver not set");
        context.seed = uint256(keccak256(abi.encodePacked(context.users, context.yield, context.seed)));

        uint256 prev = resolver.scale();
        setUpYield(context.yield); // Setup yield for the vault (loss or gain)
        uint256 cscale = resolver.scale();
        {
            Snapshot memory s = principalToken.getSnapshot();
            (uint256 oldCuratorFee, uint256 oldProtocolFee) = principalToken.getFees();

            context.prestate = Transfer_State({
                snapshot: s,
                ytSupply: yt.totalSupply(),
                totalShares: target.balanceOf(address(principalToken)),
                shareSupply: target.totalSupply(),
                curatorFee: oldCuratorFee,
                protocolFee: oldProtocolFee,
                isSettled: principalToken.isSettled(),
                isExpired: isExpired()
            });
            for (uint256 i = 0; i < context.userPrestates.length; i++) {
                Reward[] memory rewards = new Reward[](rewardTokens.length);
                for (uint256 j = 0; j < rewards.length; j++) {
                    rewards[i] = principalToken.getUserReward(rewardTokens[i], context.users[i]);
                }
                // Note This test assumes `prev` is a scale at the last time of the user's YT balance update
                Yield memory yield = principalToken.getUserYield(context.users[i]);
                context.userPrestates[i] = User_State({
                    accrued: yield.accrued,
                    userIndex: yield.userIndex.unwrap(),
                    ytBalance: yt.balanceOf(context.users[i]),
                    sharesBalance: target.balanceOf(context.users[i]),
                    rewards: rewards
                });
            }
        }
        for (uint256 i = 0; i < context.userPrestates.length; i++) {
            context.profits[i] = calcYield(prev, cscale, context.userPrestates[i].ytBalance);
        }
        execute_accrue(context); // Operation that will accrue yield
        {
            Snapshot memory s = principalToken.getSnapshot();
            (uint256 newCuratorFee, uint256 newProtocolFee) = principalToken.getFees();

            context.poststate = Transfer_State({
                snapshot: s,
                ytSupply: yt.totalSupply(),
                totalShares: target.balanceOf(address(principalToken)),
                shareSupply: target.totalSupply(),
                curatorFee: newCuratorFee,
                protocolFee: newProtocolFee,
                isSettled: principalToken.isSettled(),
                isExpired: isExpired()
            });
            for (uint256 i = 0; i < context.userPoststates.length; i++) {
                Reward[] memory rewards = new Reward[](rewardTokens.length);
                for (uint256 j = 0; j < rewards.length; j++) {
                    rewards[i] = principalToken.getUserReward(rewardTokens[i], context.users[i]);
                }
                Yield memory yield = principalToken.getUserYield(context.users[i]);
                context.userPoststates[i] = User_State({
                    accrued: yield.accrued,
                    userIndex: yield.userIndex.unwrap(),
                    ytBalance: yt.balanceOf(context.users[i]),
                    sharesBalance: target.balanceOf(context.users[i]),
                    rewards: rewards
                });
            }
        }
        assert_accrue(context);
    }
}

abstract contract TransferAccrualTest is TransferTest {
    using FixedPointMathLib for uint256;

    function test_RevertWhen_NotYt() public {
        vm.expectRevert(Errors.PrincipalToken_OnlyYieldToken.selector);
        vm.prank(alice);
        principalToken.onYtTransfer(alice, bob, 1, 111);
    }

    /// @dev Assert double counting of interest and rewards does not occur when transferring YT to self
    function test_WhenSrcAndReceiverAreTheSame() public {
        Init memory init = Init({
            user: [alice, bob, makeAddr("shika"), makeAddr("nokonoko")],
            share: [uint256(323318900), 113090900, 1313800, 3434380],
            principal: [uint256(10e6), 319809, 89831930, 3131],
            yield: 1_000_000_000
        });
        init.yield = 0;
        setUpVault(init);

        skip(1 days);

        uint256 snapshot = vm.snapshot();
        for (uint256 i = 0; i < 2; i++) {
            uint256 expectAccrued;
            Reward[] memory expectRewards = new Reward[](rewardTokens.length);
            {
                // When receiver != src
                TransferTest_Context memory context;
                context.yield = init.yield;
                context.users = [init.user[0], init.user[1]];
                context.caller = init.user[0];

                prop_accrue(context, execute_accrue, assert_accrue);

                User_State[2] memory userPostStates = context.userPoststates;
                expectAccrued = userPostStates[i].accrued;
                expectRewards = userPostStates[i].rewards;
            }
            vm.revertTo(snapshot); // Revert to the state before the accrual
            {
                // When receiver := src or src := receiver
                TransferTest_Context memory context;
                context.yield = init.yield;
                context.users = [init.user[i], init.user[i]];
                context.caller = init.user[i];

                prop_accrue(context, execute_accrue, assert_accrue);

                User_State[2] memory userPostStates = context.userPoststates;
                assertEq(userPostStates[i].accrued, expectAccrued, "Accrued interest is the same");
                for (uint256 j = 0; j < rewardTokens.length; j++) {
                    assertEq(
                        userPostStates[i].rewards[j].accrued,
                        expectRewards[j].accrued,
                        string.concat("Reward ", vm.toString(j), " is the same")
                    );
                }
            }
        }
    }

    function testFuzz_WhenSrcAndReceiverAreTheSame(Init memory init, uint256 timestamp) public boundInit(init) {
        vm.assume(init.user[0] != init.user[1]);
        setUpVault(init);
        timestamp = bound(timestamp, block.timestamp, expiry + 365 days);
        vm.warp(timestamp);

        uint256 balanceOfSrc = yt.balanceOf(init.user[0]);
        uint256 balanceOfReceiver = yt.balanceOf(init.user[1]);

        uint256 snapshot = vm.snapshot();

        // src and receiver are different
        vm.prank(address(yt));
        principalToken.onYtTransfer(init.user[0], init.user[1], balanceOfSrc, balanceOfReceiver);

        uint256 expectAccrued = principalToken.getUserYield(init.user[0]).accrued;
        Reward[] memory expectRewards = new Reward[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            expectRewards[i] = principalToken.getUserReward(rewardTokens[i], init.user[0]);
        }

        vm.revertTo(snapshot);

        // src and receiver are the same
        vm.prank(address(yt));
        principalToken.onYtTransfer(init.user[0], init.user[0], balanceOfSrc, balanceOfSrc);
        Reward[] memory actualRewards = new Reward[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            actualRewards[i] = principalToken.getUserReward(rewardTokens[i], init.user[0]);
        }

        uint256 actualAccrued = principalToken.getUserYield(init.user[0]).accrued;
        assertEq(actualAccrued, expectAccrued, "Accrued should be the same");
        assertEq(
            keccak256(abi.encode(expectRewards)), keccak256(abi.encode(actualRewards)), "Rewards should be the same"
        );
    }

    function _testFuzz_Accrue_0(Init memory init, bool settle) internal boundInit(init) {
        TransferTest_Context memory context;
        context.yield = init.yield;
        context.users = [init.user[0], init.user[1]];
        context.caller = init.user[2]; // In case of transfer, the caller is the owner.

        init.yield = 0;
        setUpVault(init);

        if (settle) {
            vm.warp(expiry);
            prop_combine(init.user[2], init.user[2], 0); // combine 0 principal to trigger settlement
            assertTrue(principalToken.isSettled(), "Settlement should be done");
        }

        prop_accrue(context, execute_accrue, assert_accrue);

        Vm.Log memory log = getLatestLogByTopic0(keccak256("YieldFeeAccrued(uint256)"));
        uint256 feeShares = abi.decode(log.data, (uint256));

        assertApproxEqAbs(
            context.poststate.curatorFee + context.poststate.protocolFee,
            feeShares + context.prestate.curatorFee + context.prestate.protocolFee,
            _delta_,
            "Fee is distributed to Curator and Napier"
        );
        uint256 curatorFee = feeShares * getSplitPctBps(feeModule.getFeePcts()) / BASIS_POINTS;
        assertApproxEqAbs(
            context.poststate.curatorFee, context.prestate.curatorFee + curatorFee, 1, "Curator fee is accrued"
        );
        assertApproxEqAbs(
            context.poststate.protocolFee,
            context.prestate.protocolFee + feeShares - curatorFee,
            1,
            "Napier fee is accrued"
        );
    }

    function _testFuzz_Accrue_1(Init memory init, int40[3] memory yields, bool settle) internal boundInit(init) {
        TransferTest_Context memory context;
        context.yield = init.yield;
        context.users = [init.user[0], init.user[1]];
        context.caller = init.user[2];

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

    function execute_accrue(TransferTest_Context memory context) internal virtual {
        vm.recordLogs();
        uint256 value = bound(context.seed, 0, yt.balanceOf(context.users[0]));
        prop_yt_transfer({owner: context.users[0], receiver: context.users[1], value: value});
    }

    function assert_accrue(TransferTest_Context memory context) internal view {
        Transfer_State memory prestate = context.prestate;
        Transfer_State memory poststate = context.poststate;
        User_State[2] memory userPoststates = context.userPoststates;
        User_State[2] memory userPrestates = context.userPrestates;

        assertGe(
            poststate.snapshot.globalIndex.unwrap(), prestate.snapshot.globalIndex.unwrap(), Property.T04_YIELD_INDEX
        );
        // Compute interest accrued by the user
        for (uint256 i = 0; i < context.users.length; i++) {
            uint256 performanceFeePct = prestate.isSettled
                ? getPostSettlementFeePctBps(feeModule.getFeePcts())
                : getPerformanceFeePctBps(feeModule.getFeePcts());

            uint256 perfFeeUser = context.profits[i] * performanceFeePct / BASIS_POINTS;
            uint256 expectAccrued = context.profits[i] - perfFeeUser;
            assertApproxLeAbs(
                userPoststates[i].accrued,
                userPrestates[i].accrued + expectAccrued,
                _delta_,
                string.concat(Property.T01_INTEREST_ACCURAL, ": user_", vm.toString(i))
            );
        }
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

        vm.expectRevert(Errors.PrincipalToken_UnderlyingTokenBalanceChanged.selector);
        vm.prank(alice);
        yt.transfer(bob, 10);
    }
}

contract TransferPreSettlementAccrualTest is TransferAccrualTest {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, BASIS_POINTS); // 30% split fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function testFuzz_Accrue_0(Init memory init) public {
        _testFuzz_Accrue_0({init: init, settle: false});
    }

    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) internal {
        _testFuzz_Accrue_1({init: init, yields: yields, settle: false});
    }
}

contract TransferFromPreSettlementAccrualTest is TransferPreSettlementAccrualTest {
    function execute_accrue(TransferTest_Context memory context) internal override {
        vm.recordLogs();
        uint256 value = bound(context.seed, 0, yt.balanceOf(context.users[0]));
        _approve(yt, context.users[0], context.caller, value);
        prop_yt_transferFrom({caller: context.caller, owner: context.users[0], receiver: context.users[1], value: value});
    }
}

contract TransferPostSettlementAccrualTest is TransferAccrualTest {
    using FixedPointMathLib for uint256;

    function setUp() public override {
        super.setUp();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, 1210); // 30% split fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function testFuzz_Accrue_0(Init memory init) public {
        _testFuzz_Accrue_0({init: init, settle: true});
    }

    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) internal {
        _testFuzz_Accrue_1({init: init, yields: yields, settle: true});
    }
}
