// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {BaseWrapperTest} from "./StandardERC4626Wrapper.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import {IBooster} from "src/wrapper/convex/interfaces/IBooster.sol";
import {IBaseRewardPool} from "src/wrapper/convex/interfaces/IBaseRewardPool.sol";
import {ConvexWrapper} from "src/wrapper/convex/ConvexWrapper.sol";
import {toDynamicArray} from "src/modules/connectors/WrapperConnector.sol";
import {ITokenWrapper} from "src/wrapper/convex/interfaces/ITokenWrapper.sol";
import "src/Constants.sol" as Constants;

using DynamicArrayLib for DynamicArrayLib.DynamicArray;

interface VirtualBalanceRewardPool {
    function operator() external view returns (address);
    function queueNewRewards(uint256 _rewards) external;
    function rewardToken() external view returns (address);
}

abstract contract ConvexWrapperTest is BaseWrapperTest {
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant BOOSTER = 0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    address donor = makeAddr("donor");
    address treasury = makeAddr("treasury");

    IBooster booster;
    IBaseRewardPool rewardPool;

    struct Init {
        uint256 underlyings;
        uint256 assets;
    }

    Init init;
    address lpToken;
    address cvxLpToken;
    uint256 poolId;

    function setUp() public virtual override {
        // Fork mainnet at a specific block

        booster = IBooster(BOOSTER);

        // Get lpToken and rewardPool from Booster
        (
            address _lpToken,
            address _cvxLpToken,
            , // token,
            address _rewardPool,
            , // gauge
                // stash
        ) = booster.poolInfo(poolId);
        lpToken = _lpToken;
        cvxLpToken = _cvxLpToken;
        rewardPool = IBaseRewardPool(_rewardPool);

        super.setUp();

        uint256 lpOne = 10 ** ERC20(lpToken).decimals();
        init = Init({underlyings: 10000 * lpOne, assets: 10000 * lpOne});

        deal(lpToken, alice, init.underlyings);
        _approve(lpToken, alice, address(booster), type(uint256).max);
        vm.prank(alice);
        booster.deposit(poolId, init.underlyings, true);

        deal(lpToken, alice, init.assets);
        setupRewards();
    }

    function _deployWrapper() internal override returns (address) {
        address implementation = address(new ConvexWrapper());
        bytes memory args = abi.encode(poolId, booster);
        address instance = LibClone.clone(implementation, args);

        ConvexWrapper(instance).initialize();

        return instance;
    }

    function _label() internal override {
        super._label();

        vm.label(BOOSTER, "convex-booster");
        vm.label(address(rewardPool), "convex-reward-pool");
        vm.label(lpToken, string.concat("curve-", ERC20(lpToken).symbol()));
        vm.label(cvxLpToken, string.concat("cvx-", ERC20(lpToken).symbol()));
        vm.label(CRV, "CRV");
        vm.label(CVX, "CVX");
    }

    function test_Immutables() public view {
        assertEq(ConvexWrapper(wrapper).asset(), lpToken, "asset");
        assertEq(ConvexWrapper(wrapper).vault(), cvxLpToken, "vault");
        assertEq(address(ConvexWrapper(wrapper).i_accessManager()), address(napierAccessManager), "access manager");
    }

    function test_RevertWhen_Reinitialize() public {
        vm.expectRevert(bytes4(0xf92ee8a9)); // `InvalidInitialization()`
        ConvexWrapper(wrapper).initialize();
    }

    function test_DepositLPToken() public {
        uint256 assets = init.assets;
        uint256 preview = ConvexWrapper(wrapper).previewDeposit(Token.wrap(lpToken), assets);
        _approve(lpToken, alice, wrapper, assets);
        vm.prank(alice);
        uint256 shares = ConvexWrapper(wrapper).deposit(Token.wrap(lpToken), assets, bob);

        assertEq(preview, shares, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        assertEq(ConvexWrapper(wrapper).totalAssets(), assets, "totalAssets");
        assertEq(rewardPool.balanceOf(address(wrapper)), assets, "staked balance");
        assertEq(ERC20(lpToken).balanceOf(address(wrapper)), 0, "no LP tokens should be in wrapper");
    }

    function test_MultipleDeposits() public {
        // First deposit by Alice
        uint256 aliceAssets = init.assets / 2; // Half of initial assets
        _approve(lpToken, alice, wrapper, aliceAssets);
        vm.prank(alice);
        uint256 aliceShares = ConvexWrapper(wrapper).deposit(Token.wrap(lpToken), aliceAssets, alice);

        // Check Alice's deposit
        assertEq(ERC20(wrapper).balanceOf(alice), aliceShares, "alice shares");
        assertEq(ConvexWrapper(wrapper).totalAssets(), aliceAssets, "total assets after alice");
        assertEq(rewardPool.balanceOf(address(wrapper)), aliceAssets, "staked balance after alice");

        // Second deposit by Bob
        uint256 bobAssets = init.assets / 4; // Quarter of initial assets
        deal(lpToken, bob, bobAssets);
        _approve(lpToken, bob, wrapper, bobAssets);
        vm.prank(bob);
        uint256 bobShares = ConvexWrapper(wrapper).deposit(Token.wrap(lpToken), bobAssets, bob);

        // Check Bob's deposit
        assertEq(ERC20(wrapper).balanceOf(bob), bobShares, "bob shares");
        assertEq(ConvexWrapper(wrapper).totalAssets(), aliceAssets + bobAssets, "total assets after bob");
        assertEq(rewardPool.balanceOf(address(wrapper)), aliceAssets + bobAssets, "staked balance after bob");

        // Verify share proportions are correct
        assertApproxEqRel(
            aliceShares * bobAssets,
            bobShares * aliceAssets,
            1e16, // 1% tolerance
            "share proportion mismatch"
        );
    }

    function test_RedeemLPToken() public {
        test_DepositLPToken(); // Setup initial state
        uint256 shares = ERC20(wrapper).balanceOf(bob);
        require(shares > 0, "bob has no shares");

        uint256 preview = ConvexWrapper(wrapper).previewRedeem(Token.wrap(lpToken), shares);
        _approve(wrapper, bob, wrapper, shares);
        vm.prank(bob);
        uint256 assets = ConvexWrapper(wrapper).redeem(Token.wrap(lpToken), shares, bob);

        assertEq(preview, assets, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), 0, "shares should be zero");
        assertEq(ERC20(lpToken).balanceOf(bob), assets, "should have LP tokens");
        assertEq(rewardPool.balanceOf(address(wrapper)), 0, "should have no staked balance");
        assertEq(ERC20(lpToken).balanceOf(address(wrapper)), 0, "no LP tokens should be in wrapper");
    }

    function test_DonatedLPTokens() public {
        test_DepositLPToken(); // Setup initial state with staked LP tokens
        uint256 initialTotalAssets = ConvexWrapper(wrapper).totalAssets();

        // Donate LP tokens directly to wrapper
        uint256 donatedAmount = 100e18;
        deal(lpToken, donor, donatedAmount);
        vm.prank(donor);
        SafeTransferLib.safeTransfer(lpToken, address(wrapper), donatedAmount);

        // Total assets should not include donated tokens
        assertEq(ConvexWrapper(wrapper).totalAssets(), initialTotalAssets, "totalAssets should not include donations");
        assertEq(ERC20(lpToken).balanceOf(address(wrapper)), donatedAmount, "donated tokens should be in wrapper");
    }

    function test_ClaimRewardsBasic() public virtual {
        test_DepositLPToken(); // Setup initial state with staked LP tokens

        uint256 extraRewardsLength = rewardPool.extraRewardsLength();
        // Set principalToken
        address mockPrincipalToken = makeAddr("principalToken");
        address setter = makeAddr("setter");

        // Grant role to the setter address
        vm.prank(admin);
        napierAccessManager.grantRoles(setter, Constants.DEV_ROLE);

        // Grant permission for the function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConvexWrapper.setPrincipalToken.selector;
        vm.prank(admin);
        napierAccessManager.grantTargetFunctionRoles(wrapper, selectors, Constants.DEV_ROLE);

        vm.prank(setter);
        ConvexWrapper(wrapper).setPrincipalToken(mockPrincipalToken);

        vm.warp(block.timestamp + 1000000000000000000);
        // Claim rewards
        vm.prank(mockPrincipalToken);
        TokenReward[] memory rewards = ConvexWrapper(wrapper).claimRewards();

        // Verify rewards were sent to principalToken
        assertEq(rewards.length, extraRewardsLength + 1, "reward tokens mismatch");

        // Check base reward (CRV)
        assertEq(rewards[0].token, rewardPool.rewardToken(), "base reward token mismatch");
        assertGt(rewards[0].amount, 0, "base reward should greater than 0");
        for (uint256 i = 1; i < rewards.length; i++) {
            assertGt(rewards[i].amount, 0, "reward should greater than 0");
        }
    }

    function test_ClaimRewards_OnlyPrincipalToken() public {
        address notPrincipalToken = makeAddr("notPrincipalToken");

        // Set principalToken
        address mockPrincipalToken = makeAddr("principalToken");
        address setter = makeAddr("setter");

        // Grant role to the setter address
        vm.startPrank(admin);
        napierAccessManager.grantRoles(setter, Constants.DEV_ROLE);

        // Grant permission for the function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConvexWrapper.setPrincipalToken.selector;
        napierAccessManager.grantTargetFunctionRoles(wrapper, selectors, Constants.DEV_ROLE);
        vm.stopPrank();

        vm.prank(setter);
        ConvexWrapper(wrapper).setPrincipalToken(mockPrincipalToken);

        // Try to claim rewards from non-principalToken address
        vm.prank(notPrincipalToken);
        TokenReward[] memory rewards = ConvexWrapper(wrapper).claimRewards();

        // Should return empty array
        assertEq(rewards.length, 0, "should return empty array for non-principalToken");
    }

    function test_RevertWhen_SetPrincipalToken_NotFactory() public {
        address mockPrincipalToken = makeAddr("principalToken");
        address notFactory = makeAddr("notFactory");

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConvexWrapper.setPrincipalToken.selector;
        napierAccessManager.grantTargetFunctionRoles(wrapper, selectors, Constants.DEV_ROLE);
        vm.stopPrank();

        vm.prank(notFactory);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        ConvexWrapper(wrapper).setPrincipalToken(mockPrincipalToken);
    }

    function test_RevertWhen_SetPrincipalToken_AlreadySet() public {
        address mockPrincipalToken = makeAddr("principalToken");
        address setter = makeAddr("setter");

        // Grant role to the setter address
        vm.startPrank(admin);
        napierAccessManager.grantRoles(setter, Constants.DEV_ROLE);

        // Grant permission for the function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConvexWrapper.setPrincipalToken.selector;
        napierAccessManager.grantTargetFunctionRoles(wrapper, selectors, Constants.DEV_ROLE);
        vm.stopPrank();

        // Set first time
        vm.prank(setter);
        ConvexWrapper(wrapper).setPrincipalToken(mockPrincipalToken);

        // Try to set again
        vm.prank(setter);
        vm.expectRevert(Errors.Wrapper_PrincipalTokenAlreadySet.selector);
        ConvexWrapper(wrapper).setPrincipalToken(mockPrincipalToken);
    }

    function test_RevertWhen_SetPrincipalToken_IssueAddress() public {
        address setter = makeAddr("setter");

        // Grant role to the setter address
        vm.startPrank(admin);
        napierAccessManager.grantRoles(setter, Constants.DEV_ROLE);

        // Grant permission for the function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConvexWrapper.setPrincipalToken.selector;
        napierAccessManager.grantTargetFunctionRoles(wrapper, selectors, Constants.DEV_ROLE);
        vm.stopPrank();

        vm.prank(setter);
        vm.expectRevert(Errors.Wrapper_InvalidPrincipalToken.selector);
        ConvexWrapper(wrapper).setPrincipalToken(address(wrapper));
    }

    function test_GetTokenInList() public view {
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ConvexWrapper(wrapper).getTokenInList());
        assertEq(tokens.asAddressArray().length, 1, "tokens.length");
        assertTrue(tokens.contains(lpToken), "Token not in list");
    }

    function test_GetTokenOutList() public view {
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ConvexWrapper(wrapper).getTokenOutList());
        assertEq(tokens.asAddressArray().length, 1, "tokens.length");
        assertTrue(tokens.contains(lpToken), "Token not in list");
    }

    function setupRewards() internal {
        // This setup works only for pools with poolId >= 151
        // https://docs.convexfinance.com/convexfinanceintegration/baserewardpool#extra-rewards
        if (poolId < 151) return;

        uint256 extraRewardsLength = IBaseRewardPool(rewardPool).extraRewardsLength();
        for (uint256 i = 0; i < extraRewardsLength; i++) {
            address virtualBalanceRewardPool = IBaseRewardPool(rewardPool).extraRewards(i);
            address rewardToken = VirtualBalanceRewardPool(virtualBalanceRewardPool).rewardToken();
            address wrappedRewardToken = ITokenWrapper(rewardToken).token();
            deal(wrappedRewardToken, rewardToken, 1000e18);
            vm.prank(VirtualBalanceRewardPool(virtualBalanceRewardPool).operator());
            VirtualBalanceRewardPool(virtualBalanceRewardPool).queueNewRewards(1000e18);
        }
    }
}

contract RSUPWETHConvexWrapperTest is ConvexWrapperTest {
    uint256 constant RSUPWETH_POOL_ID = 441;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
        poolId = RSUPWETH_POOL_ID;

        super.setUp();
    }
}

contract PXETHSTETHConvexWrapperTest is ConvexWrapperTest {
    uint256 constant PXETHSTETH_POOL_ID = 273;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
        poolId = PXETHSTETH_POOL_ID;

        super.setUp();
    }
}

contract SFXUSDREUSDConvexWrapperTest is ConvexWrapperTest {
    uint256 constant POOL_ID = 439;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
        poolId = POOL_ID;

        super.setUp();
    }
}

contract SCRVUSDREUSDConvexWrapperTest is ConvexWrapperTest {
    uint256 constant POOL_ID = 440;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
        poolId = POOL_ID;

        super.setUp();
    }
}

contract STETHETHConvexWrapperTest is ConvexWrapperTest {
    uint256 constant STETHETH_POOL_ID = 25;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
        poolId = STETHETH_POOL_ID;

        super.setUp();
    }

    function test_ClaimRewardsBasic() public override {
        test_DepositLPToken(); // Setup initial state with staked LP tokens

        uint256 extraRewardsLength = rewardPool.extraRewardsLength();
        // Set principalToken
        address mockPrincipalToken = makeAddr("principalToken");
        address setter = makeAddr("setter");

        // Grant role to the setter address
        vm.prank(admin);
        napierAccessManager.grantRoles(setter, Constants.DEV_ROLE);

        // Grant permission for the function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ConvexWrapper.setPrincipalToken.selector;
        vm.prank(admin);
        napierAccessManager.grantTargetFunctionRoles(wrapper, selectors, Constants.DEV_ROLE);

        vm.prank(setter);
        ConvexWrapper(wrapper).setPrincipalToken(mockPrincipalToken);

        vm.warp(block.timestamp + 1000000000000000000);
        // Claim rewards
        vm.prank(mockPrincipalToken);
        TokenReward[] memory rewards = ConvexWrapper(wrapper).claimRewards();

        // Verify rewards were sent to principalToken
        assertEq(rewards.length, extraRewardsLength + 1, "reward tokens mismatch");

        // Check base reward (CRV)
        assertEq(rewards[0].token, rewardPool.rewardToken(), "base reward token mismatch");
        assertGt(rewards[0].amount, 0, "base reward should greater than 0");
        // for (uint256 i = 1; i < rewards.length; i++) {
        //     assertGt(rewards[i].amount, 0, "reward should greater than 0");
        // }
    }
}
