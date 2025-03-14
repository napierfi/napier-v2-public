// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import "../Property.sol" as Property;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {Reward} from "src/utils/RewardMathLib.sol";

abstract contract RewardsAccrualTest is PrincipalTokenTest {
    function setUp() public virtual override {
        expiry = block.timestamp + 20 days; // Shorten the expiry for testing post settlement cases easily
        super.setUp();
    }

    struct RewardsAccrual_State {
        uint256 accrued;
        uint256 userIndex;
        uint256 ytBalance; // yt.balanceOf(context.src)
        uint256 globalIndex;
        uint256 ytSupply;
        uint256 protocolReward;
        uint256 curatorReward;
        bool isSettled;
        bool isExpired;
    }

    struct Reward_Input {
        uint256 timeJump;
        address rewardToken;
    }

    struct RewardsAccrual_Context {
        address[N] users; // Init.user
        address src; // Target of the accrual operation and assertion target
        Reward_Input input;
        uint256 seed;
        uint256 totalRewards; // Total rewards distributed in the timeJump period
        RewardsAccrual_State prestate;
        RewardsAccrual_State poststate;
    }

    modifier boundRewardInput(Reward_Input memory input) {
        input.rewardToken = rewardTokens[uint256(uint160(input.rewardToken)) % rewardTokens.length];
        input.timeJump = bound(input.timeJump, 0, 60 days);
        _;
    }

    function prop_accrue(
        RewardsAccrual_Context memory context,
        function (RewardsAccrual_Context memory) internal execute_accrue_fn,
        function (RewardsAccrual_Context memory) internal assert_accrue_fn
    ) internal {
        require(context.src != address(0), "EIP5095PropTest: src not set");
        require(context.input.rewardToken != address(0), "EIP5095PropTest: rewardToken not set");
        require(context.input.timeJump <= 365 days, "EIP5095PropTest: timeJump too large");

        context.seed = uint256(keccak256(abi.encodePacked(context.src, context.input.timeJump, context.seed)));

        // Note This test assumes rewards were accrued at the last time of users' YT balanace update.
        uint256 totalRewards = multiRewardDistributor.s_rewardsRate(context.input.rewardToken) * context.input.timeJump;
        context.totalRewards = totalRewards;
        {
            uint256 oldYtBalance = yt.balanceOf(context.src);
            Reward memory oldUserReward = principalToken.getUserReward(context.input.rewardToken, context.src);

            (uint256 curatorReward, uint256 protocolReward) = principalToken.getFeeRewards(context.input.rewardToken);
            context.prestate = RewardsAccrual_State({
                globalIndex: principalToken.getRewardGlobalIndex(context.input.rewardToken).unwrap(),
                accrued: oldUserReward.accrued,
                userIndex: oldUserReward.userIndex.unwrap(),
                ytBalance: oldYtBalance,
                ytSupply: yt.totalSupply(),
                curatorReward: curatorReward,
                protocolReward: protocolReward,
                isSettled: principalToken.isSettled(),
                isExpired: isExpired()
            });
        }
        skip(context.input.timeJump);
        execute_accrue_fn(context); // Operation that will accrue reward
        {
            uint256 newYtBalance = yt.balanceOf(context.src);
            Reward memory newUserReward = principalToken.getUserReward(context.input.rewardToken, context.src);

            (uint256 curatorReward, uint256 protocolReward) = principalToken.getFeeRewards(context.input.rewardToken);
            context.poststate = RewardsAccrual_State({
                globalIndex: principalToken.getRewardGlobalIndex(context.input.rewardToken).unwrap(),
                accrued: newUserReward.accrued,
                userIndex: newUserReward.userIndex.unwrap(),
                ytBalance: newYtBalance,
                ytSupply: yt.totalSupply(),
                curatorReward: curatorReward,
                protocolReward: protocolReward,
                isSettled: principalToken.isSettled(),
                isExpired: isExpired()
            });
        }
        assert_accrue_fn(context);
    }

    function testFuzz_Accrue_0(Init memory init, Reward_Input memory input)
        public
        virtual
        boundInit(init)
        boundRewardInput(input)
    {
        setUpVault(init);

        RewardsAccrual_Context memory context = create_context(init, input);

        prop_accrue(context, execute_accrue, assert_accrue);
    }

    function testFuzz_Accrue_1(Init memory init, Reward_Input memory input, uint40[3] memory timeJumps)
        public
        virtual
        boundInit(init)
        boundRewardInput(input)
    {
        setUpVault(init);

        RewardsAccrual_Context memory context = create_context(init, input);

        for (uint256 i = 0; i < 3; i++) {
            context.input.timeJump = bound(context.input.timeJump + timeJumps[i], 0, 60 days);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }

    function create_context(Init memory init, Reward_Input memory input)
        internal
        virtual
        returns (RewardsAccrual_Context memory context);

    function execute_accrue(RewardsAccrual_Context memory context) internal virtual;

    function assert_accrue(RewardsAccrual_Context memory context) internal view virtual {
        RewardsAccrual_State memory prestate = context.prestate;
        RewardsAccrual_State memory poststate = context.poststate;

        if (prestate.isSettled) {
            uint256 fees = context.totalRewards * getPostSettlementFeePctBps(feeModule.getFeePcts()) / BASIS_POINTS;
            uint256 curatorFee = fees * getSplitPctBps(feeModule.getFeePcts()) / BASIS_POINTS;
            assertLe(poststate.curatorReward, prestate.curatorReward + curatorFee, Property.T06_REWARD_POST_SETTLEMENT);
            assertLe(
                poststate.protocolReward,
                prestate.protocolReward + (fees - curatorFee),
                Property.T06_REWARD_POST_SETTLEMENT
            );
            assertApproxLeAbs(
                poststate.accrued,
                prestate.accrued + (context.totalRewards - fees) * prestate.ytBalance / prestate.ytSupply,
                _delta_,
                Property.T06_REWARD_POST_SETTLEMENT
            );
        } else {
            assertEq(poststate.curatorReward, prestate.curatorReward, Property.T06_REWARD_PRE_SETTLEMENT);
            assertEq(poststate.protocolReward, prestate.protocolReward, Property.T06_REWARD_PRE_SETTLEMENT);
            uint256 userRewards = calcReward(context.totalRewards, prestate.ytBalance, prestate.ytSupply); // Proportional to the user's YT balance
            assertApproxLeAbs(
                poststate.accrued, prestate.accrued + userRewards, _delta_, Property.T06_REWARD_PRE_SETTLEMENT
            );
        }
        assertGe(poststate.globalIndex, prestate.globalIndex, Property.T09_REWARD_INDEX);
        assertEq(poststate.userIndex, poststate.globalIndex, "User index should be equal to global index");
    }

    /// @dev Utility function as a workaround for handling underflow or overflow in the reward calculation
    function math_calcReward(uint256 rewards, uint256 ytBalance, uint256 ytSupply) external pure returns (uint256) {
        return rewards * ytBalance / ytSupply;
    }

    /// @dev Fuzzing helper function. Skip underflow/overflow errors
    function calcReward(uint256 rewards, uint256 ytBalance, uint256 ytSupply) public view returns (uint256) {
        (bool success, bytes memory retdata) =
            address(this).staticcall(abi.encodeCall(this.math_calcReward, (rewards, ytBalance, ytSupply)));
        vm.assume(success);
        return abi.decode(retdata, (uint256));
    }
}

abstract contract PostSettlement_RewardsAccrualTest is RewardsAccrualTest {
    function testFuzz_Accrue_0(Init memory init, Reward_Input memory input)
        public
        override
        boundInit(init)
        boundRewardInput(input)
    {
        setUpVault(init);

        RewardsAccrual_Context memory context = create_context(init, input);

        // Settle
        vm.warp(expiry);
        prop_combine(context.users[0], context.users[0], 0); // combine 0 principal to trigger settlement

        prop_accrue(context, execute_accrue, assert_accrue);
    }

    function testFuzz_Accrue_1(Init memory init, Reward_Input memory input, uint40[3] memory timeJumps)
        public
        override
        boundInit(init)
        boundRewardInput(input)
    {
        setUpVault(init);

        RewardsAccrual_Context memory context = create_context(init, input);

        // Settle
        vm.warp(expiry);
        prop_combine(context.src, context.src, 0); // combine 0 principal to trigger settlement

        for (uint256 i = 0; i < 3; i++) {
            context.input.timeJump = bound(context.input.timeJump + timeJumps[i], 0, 60 days);
            prop_accrue(context, execute_accrue, assert_accrue);
        }
    }
}

contract Supply_RewardsAccrualTest is RewardsAccrualTest {
    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[1]; // receiver
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal virtual override {
        uint256 shares = bound(context.seed, 0, _max_supply(context.users[0]));
        _approve(target, context.users[0], address(principalToken), type(uint256).max);
        prop_supply(context.users[0], context.users[1], shares);
    }

    function assert_accrue(RewardsAccrual_Context memory context) internal view override {
        super.assert_accrue(context);
    }
}

contract Issue_RewardsAccrualTest is Supply_RewardsAccrualTest {
    function execute_accrue(RewardsAccrual_Context memory context) internal override {
        uint256 shares = bound(context.seed, 0, _max_issue(context.users[0]));
        _approve(target, context.users[0], address(principalToken), type(uint256).max);
        prop_issue(context.users[0], context.users[1], shares);
    }
}

contract CombinePreSettlement_RewardsAccrualTest is RewardsAccrualTest {
    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[0]; // src
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal virtual override {
        uint256 principal = bound(context.seed, 0, _max_combine(context.users[0]));
        prop_combine(context.users[0], context.users[1], principal);
    }

    function assert_accrue(RewardsAccrual_Context memory context) internal view override {
        super.assert_accrue(context);
    }
}

contract CombinePostSettlement_RewardsAccrualTest is PostSettlement_RewardsAccrualTest {
    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[0]; // src
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal virtual override {
        require(principalToken.isSettled(), "TEST-ASSUMPTION: after settlement only");

        uint256 principal = bound(context.seed, 0, _max_combine(context.users[0]));
        prop_combine(context.users[0], context.users[1], principal);
    }
}

contract UnitePreSettlement_RewardsAccrualTest is CombinePreSettlement_RewardsAccrualTest {
    function execute_accrue(RewardsAccrual_Context memory context) internal override {
        uint256 shares = bound(context.seed, 0, _max_unite(context.users[0]));
        prop_unite(context.users[0], context.users[1], shares);
    }
}

contract UnitePostSettlement_RewardsAccrualTest is CombinePostSettlement_RewardsAccrualTest {
    function execute_accrue(RewardsAccrual_Context memory context) internal override {
        require(principalToken.isSettled(), "TEST-ASSUMPTION: after settlement only");

        uint256 shares = bound(context.seed, 0, _max_unite(context.users[0]));
        prop_unite(context.users[0], context.users[1], shares);
    }
}

contract CollectPreSettlement_RewardsAccrualTest is RewardsAccrualTest {
    uint256 oldRewardBalance;

    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[0]; // owner of the YT
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal virtual override {
        vm.prank(context.users[0]);
        principalToken.setApprovalCollector(context.users[2], true);

        oldRewardBalance = ERC20(context.input.rewardToken).balanceOf(context.users[1]);
        prop_collect({caller: context.users[2], receiver: context.users[1], owner: context.users[0]});
    }

    function assert_accrue(RewardsAccrual_Context memory context) internal view override {
        RewardsAccrual_State memory prestate = context.prestate;
        RewardsAccrual_State memory poststate = context.poststate;

        assertGe(poststate.globalIndex, prestate.globalIndex, Property.T09_REWARD_INDEX);
        assertEq(poststate.userIndex, poststate.globalIndex, "User index should be equal to global index");

        uint256 expectRewardsCollected =
            prestate.accrued + calcReward(context.totalRewards, prestate.ytBalance, prestate.ytSupply); // Proportional to the user's YT balance
        uint256 newRewardBalance = ERC20(context.input.rewardToken).balanceOf(context.users[1]);
        uint256 actual = newRewardBalance - oldRewardBalance;
        assertApproxLeAbs(actual, expectRewardsCollected, _delta_, Property.T06_REWARD_PRE_SETTLEMENT);
    }
}

contract CollectPostSettlement_RewardsAccrualTest is PostSettlement_RewardsAccrualTest {
    uint256 oldRewardBalance;

    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[0]; // owner of the YT
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal override {
        vm.prank(context.users[0]);
        principalToken.setApprovalCollector(context.users[2], true);

        oldRewardBalance = ERC20(context.input.rewardToken).balanceOf(context.users[1]);
        prop_collect({caller: context.users[2], receiver: context.users[1], owner: context.users[0]});
    }

    function assert_accrue(RewardsAccrual_Context memory context) internal view override {
        RewardsAccrual_State memory prestate = context.prestate;
        RewardsAccrual_State memory poststate = context.poststate;

        assertGe(poststate.globalIndex, prestate.globalIndex, Property.T09_REWARD_INDEX);
        assertEq(poststate.userIndex, poststate.globalIndex, "User index should be equal to global index");

        uint256 fees = context.totalRewards * getPostSettlementFeePctBps(feeModule.getFeePcts()) / BASIS_POINTS;
        uint256 curatorFee = fees * getSplitPctBps(feeModule.getFeePcts()) / BASIS_POINTS;
        assertLe(poststate.curatorReward, prestate.curatorReward + curatorFee, Property.T06_REWARD_POST_SETTLEMENT);
        assertLe(
            poststate.protocolReward, prestate.protocolReward + (fees - curatorFee), Property.T06_REWARD_POST_SETTLEMENT
        );

        uint256 expectRewardsCollected =
            prestate.accrued + (context.totalRewards - fees) * prestate.ytBalance / prestate.ytSupply;
        uint256 newRewardBalance = ERC20(context.input.rewardToken).balanceOf(context.users[1]);
        uint256 actual = newRewardBalance - oldRewardBalance;
        assertApproxLeAbs(actual, expectRewardsCollected, _delta_, Property.T06_REWARD_POST_SETTLEMENT);
    }
}

contract YtTransferPreSettlement_RewardsAccrualTest is RewardsAccrualTest {
    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[0]; // owner of the YT
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal override {
        uint256 value = bound(context.seed, 0, yt.balanceOf(context.users[0]));
        prop_yt_transfer({owner: context.users[0], receiver: context.users[1], value: value});
    }

    function assert_accrue(RewardsAccrual_Context memory context) internal view override {
        super.assert_accrue(context);
    }
}

contract YtTransferPostSettlement_RewardsAccrualTest is PostSettlement_RewardsAccrualTest {
    function create_context(Init memory init, Reward_Input memory input)
        internal
        pure
        override
        returns (RewardsAccrual_Context memory context)
    {
        context.users = init.user;
        context.src = init.user[0]; // owner of the YT
        context.input = input;
    }

    function execute_accrue(RewardsAccrual_Context memory context) internal virtual override {
        require(principalToken.isSettled(), "TEST-ASSUMPTION: after settlement only");

        uint256 value = bound(context.seed, 0, yt.balanceOf(context.users[0]));
        prop_yt_transfer({owner: context.users[0], receiver: context.users[1], value: value});
    }
}
