// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Base, TwoCryptoBase} from "../../TwoCryptoBase.t.sol";
import {RewardProxyBaseTest} from "../RewardProxy.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {MorphoRewardProxy} from "src/modules/reward-proxies/MorphoRewardProxy.sol";

import {IUniversalRewardsDistributor} from "src/interfaces/external/IUniversalDistributor.sol";

import "src/Types.sol";
import "src/Constants.sol";
import "src/Errors.sol";

contract MockDistributor {
    event Claimed(address indexed account, address indexed reward, uint256 amount);

    mapping(address account => mapping(address reward => uint256 claimed)) s_claimed;

    function claimed(address account, address reward) public view returns (uint256) {
        return s_claimed[account][reward];
    }

    function claim(address account, address reward, uint256 claimable, bytes32[] calldata proof) external {
        proof; // Skip proof for testing

        uint256 amount = claimable - s_claimed[account][reward];
        s_claimed[account][reward] = claimable;
        ERC20(reward).transfer(account, amount);

        emit Claimed(account, reward, amount);
    }
}

contract MorphoRewardProxyTest is RewardProxyBaseTest {
    MockDistributor distributor;

    function setUp() public virtual override {
        distributor = new MockDistributor();
        rewardProxy_logic = address(new MorphoRewardProxy());

        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        /// Prepare distributor
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            deal(rewardTokens[i], address(distributor), type(uint64).max);
        }
    }

    function getCustomArgs() public view override returns (bytes memory) {
        return abi.encode(rewardTokens, distributor, treasury);
    }

    /// @dev Helper to get the last claimed amount for a reward token stored in PrincipalToken storage.
    function getLastClaimed(address reward) public view returns (uint256) {
        bytes32 MORPHO_REWARD_PROXY_STORAGE_LOCATION = keccak256(
            abi.encode(uint256(keccak256("napier-v2.storage.morpho-reward-proxy")) - 1)
        ) & ~bytes32(uint256(0xff));
        // Inside struct, the mapping is the first element.
        uint256 offset = 0;
        bytes32 slot = keccak256(abi.encode(reward, uint256(MORPHO_REWARD_PROXY_STORAGE_LOCATION) + offset));
        return uint256(vm.load(address(principalToken), slot));
    }

    function test_ClaimRewards() public {
        // Prepare - Alice is eligible for rewards
        uint256 shares = 0.01e18;
        deal(address(base), alice, shares);

        _approve(base, alice, address(target), shares);
        vm.prank(alice);
        target.deposit(shares, alice);

        _approve(target, alice, address(principalToken), shares);
        vm.prank(alice);
        principalToken.supply(shares, alice);

        // Execution

        skip(1 hours);
        uint256 totalClaimable = 1000;
        distributor.claim(address(principalToken), rewardTokens[0], totalClaimable, new bytes32[](0));

        // Accrued reward is updated
        vm.prank(alice);
        principalToken.supply(0, alice);

        assertEq(getLastClaimed(rewardTokens[0]), totalClaimable);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable);

        skip(2 hours);
        uint256 claimable2 = 2030;
        uint256 totalClaimable2 = claimable2 + totalClaimable;
        distributor.claim(address(principalToken), rewardTokens[0], totalClaimable2, new bytes32[](0));

        // Accrued reward is updated
        vm.prank(alice);
        principalToken.supply(0, alice);

        assertEq(getLastClaimed(rewardTokens[0]), totalClaimable2);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable2);

        skip(3 hours);
        uint256 claimable3 = 30003;
        uint256 totalClaimable3 = claimable3 + totalClaimable2;
        // Nobody claimed yet

        vm.prank(alice);
        principalToken.combine(0, alice);

        assertEq(getLastClaimed(rewardTokens[0]), totalClaimable2);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable2);

        vm.warp(expiry);
        distributor.claim(address(principalToken), rewardTokens[0], totalClaimable3, new bytes32[](0));

        // Accrued reward is updated
        vm.prank(alice);
        principalToken.combine(0, alice);

        assertEq(getLastClaimed(rewardTokens[0]), totalClaimable3);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable3);
        assertEq(ERC20(rewardTokens[0]).balanceOf(address(principalToken)), 0, "Reward token balance");
    }

    function test_GetCustomArgs() public view {
        (address[] memory _rewardTokens, address _distributor, address _treasury) =
            MorphoRewardProxy(address(rewardProxy)).getCustomArgs();

        assertEq(_distributor, address(distributor));
        assertEq(_treasury, treasury);
        assertEq(_rewardTokens.length, rewardTokens.length);
        assertEq(keccak256(abi.encode(_rewardTokens)), keccak256(abi.encode(rewardTokens)));
    }

    function test_RevertWhen_RewardTokensEmpty() public {
        bytes memory customArgs = abi.encode(new address[](0), distributor, treasury);
        _test_RevertWhen_RewardTokensEmpty(customArgs);
    }

    function test_RevertWhen_DuplicatedRewardTokens() public {
        rewardTokens.push(rewardTokens[0]);
        bytes memory customArgs = abi.encode(rewardTokens, distributor, treasury);
        _test_RevertWhen_DuplicatedRewardTokens(customArgs);
    }

    function test_RevertWhen_BadRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = address(0x02);
        badRewardTokens[1] = address(0x01); // Descending order
        bytes memory customArgs = abi.encode(badRewardTokens, distributor, treasury);
        _test_RevertWhen_BadRewardTokens(customArgs);
    }

    function test_RevertWhen_BadDistributor() public {
        address badDistributor = address(0xbbbbb); // EOA
        bytes memory customArgs = abi.encode(rewardTokens, badDistributor);
        cloneRewardProxy(customArgs);
        vm.expectRevert(Errors.MorphoRewardProxy_InvalidDistributor.selector);
        rewardProxy.initialize();
    }
}
