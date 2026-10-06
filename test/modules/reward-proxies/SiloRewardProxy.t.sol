// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Base} from "../../Base.t.sol";
import {RewardProxyBaseTest} from "../RewardProxy.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {SiloRewardProxy} from "src/modules/reward-proxies/SiloRewardProxy.sol";
import {ISiloIncentivesController} from "src/interfaces/external/ISiloIncentivesController.sol";

import "src/Types.sol";
import "src/Constants.sol";
import "src/Errors.sol";

contract MockSiloIncentivesController {
    event RewardsClaimed(address indexed account, string[] programNames, uint256 totalAmount);

    mapping(address account => mapping(string programName => uint256 amount)) public s_rewards;
    mapping(string programName => address rewardToken) public s_programRewardTokens;
    mapping(string programName => bytes32 programId) public s_programIds;

    function setReward(address account, string memory programName, uint256 amount) external {
        s_rewards[account][programName] = amount;
    }

    function setProgramRewardToken(string memory programName, address rewardToken) external {
        s_programRewardTokens[programName] = rewardToken;
        s_programIds[programName] = keccak256(abi.encodePacked(programName));
    }

    function claimRewards(address _to, string[] calldata _programNames)
        external
        returns (ISiloIncentivesController.AccruedRewards[] memory accruedRewards)
    {
        accruedRewards = new ISiloIncentivesController.AccruedRewards[](_programNames.length);
        uint256 totalAmount = 0;

        for (uint256 i = 0; i < _programNames.length; i++) {
            string memory programName = _programNames[i];
            uint256 amount = s_rewards[msg.sender][programName];
            address rewardToken = s_programRewardTokens[programName];

            if (amount > 0 && rewardToken != address(0)) {
                s_rewards[msg.sender][programName] = 0; // Reset after claiming
                ERC20(rewardToken).transfer(_to, amount);
                totalAmount += amount;

                accruedRewards[i] = ISiloIncentivesController.AccruedRewards({
                    programId: s_programIds[programName],
                    rewardToken: rewardToken,
                    amount: amount
                });
            } else {
                accruedRewards[i] = ISiloIncentivesController.AccruedRewards({
                    programId: s_programIds[programName],
                    rewardToken: rewardToken,
                    amount: 0
                });
            }
        }

        emit RewardsClaimed(msg.sender, _programNames, totalAmount);
    }

    function claimRewards(address _to) external pure returns (ISiloIncentivesController.AccruedRewards[] memory) {
        _to; // Silence unused parameter warning
        return new ISiloIncentivesController.AccruedRewards[](0);
    }

    function getRewardsBalance(address _user, string[] calldata _programNames)
        external
        view
        returns (uint256 unclaimedRewards)
    {
        for (uint256 i = 0; i < _programNames.length; i++) {
            unclaimedRewards += s_rewards[_user][_programNames[i]];
        }
    }
}

contract SiloRewardProxyTest is RewardProxyBaseTest {
    MockSiloIncentivesController controller;
    string[] programNames;

    function setUp() public virtual override {
        controller = new MockSiloIncentivesController();
        rewardProxy_logic = address(new SiloRewardProxy());

        // Set up program names
        programNames.push("SILO_PROGRAM_1");
        programNames.push("SILO_PROGRAM_2");

        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        /// Prepare controller
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            deal(rewardTokens[i], address(controller), type(uint64).max);
            // Map each reward token to a program
            if (i < programNames.length) {
                controller.setProgramRewardToken(programNames[i], rewardTokens[i]);
            }
        }
    }

    function getCustomArgs() public view override returns (bytes memory) {
        return abi.encode(rewardTokens, controller, programNames);
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

        // Set up rewards for different programs
        uint256 rewardAmount1 = 1000;
        uint256 rewardAmount2 = 2000;
        controller.setReward(address(principalToken), programNames[0], rewardAmount1);
        controller.setReward(address(principalToken), programNames[1], rewardAmount2);

        // Execution - trigger reward collection
        skip(1 hours);
        vm.prank(alice);
        principalToken.supply(0, alice);

        // Check that rewards were distributed (they go to users proportionally, not to a treasury)
        // In this case, since alice is the only YT holder, she should get all rewards
        assertEq(ERC20(rewardTokens[0]).balanceOf(address(principalToken)), rewardAmount1, "Reward token 0 balance");
        assertEq(ERC20(rewardTokens[1]).balanceOf(address(principalToken)), rewardAmount2, "Reward token 1 balance");

        // Test another round of rewards
        skip(2 hours);
        uint256 rewardAmount3 = 3000;
        uint256 rewardAmount4 = 4000;
        controller.setReward(address(principalToken), programNames[0], rewardAmount3);
        controller.setReward(address(principalToken), programNames[1], rewardAmount4);

        vm.prank(alice);
        principalToken.supply(0, alice);

        assertEq(
            ERC20(rewardTokens[0]).balanceOf(address(principalToken)),
            rewardAmount1 + rewardAmount3,
            "Reward token 0 total"
        );
        assertEq(
            ERC20(rewardTokens[1]).balanceOf(address(principalToken)),
            rewardAmount2 + rewardAmount4,
            "Reward token 1 total"
        );
    }

    function test_GetCustomArgs() public view {
        (address[] memory _rewardTokens, address _controller, string[] memory _programNames) =
            SiloRewardProxy(address(rewardProxy)).getCustomArgs();

        assertEq(_controller, address(controller));
        assertEq(_rewardTokens.length, rewardTokens.length);
        assertEq(_programNames.length, programNames.length);
        assertEq(keccak256(abi.encode(_rewardTokens)), keccak256(abi.encode(rewardTokens)));
        assertEq(keccak256(abi.encode(_programNames)), keccak256(abi.encode(programNames)));
    }

    function test_ClaimRewards_EmptyPrograms() public {
        // Prepare - Alice is eligible for rewards
        uint256 shares = 0.01e18;
        deal(address(base), alice, shares);

        _approve(base, alice, address(target), shares);
        vm.prank(alice);
        target.deposit(shares, alice);

        _approve(target, alice, address(principalToken), shares);
        vm.prank(alice);
        principalToken.supply(shares, alice);

        // Make the controller fail by not setting up rewards properly
        // This should not revert but return empty rewards
        vm.prank(alice);
        principalToken.supply(0, alice); // This should not revert even if claiming fails
    }

    function test_RevertWhen_RewardTokensEmpty() public {
        bytes memory customArgs = abi.encode(new address[](0), controller, programNames);
        _test_RevertWhen_RewardTokensEmpty(customArgs);
    }

    function test_RevertWhen_DuplicatedRewardTokens() public {
        rewardTokens.push(rewardTokens[0]);
        bytes memory customArgs = abi.encode(rewardTokens, controller, programNames);
        _test_RevertWhen_DuplicatedRewardTokens(customArgs);
    }

    function test_RevertWhen_BadRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = address(0x02);
        badRewardTokens[1] = address(0x01); // Descending order
        bytes memory customArgs = abi.encode(badRewardTokens, controller, programNames);
        _test_RevertWhen_BadRewardTokens(customArgs);
    }

    function test_RevertWhen_BadController() public {
        address badController = address(0xbbbbb); // EOA
        bytes memory customArgs = abi.encode(rewardTokens, badController, programNames);
        cloneRewardProxy(customArgs);
        vm.expectRevert(Errors.SiloRewardProxy_InvalidController.selector);
        rewardProxy.initialize();
    }

    function test_CollectWithNonExistentPrograms() public {
        // Test with programs that don't have rewards set up
        string[] memory nonExistentPrograms = new string[](2);
        nonExistentPrograms[0] = "NON_EXISTENT_1";
        nonExistentPrograms[1] = "NON_EXISTENT_2";

        bytes memory customArgs = abi.encode(rewardTokens, controller, nonExistentPrograms);
        cloneRewardProxy(customArgs);
        rewardProxy.initialize();

        // Should not revert and should return empty rewards
        uint256 shares = 0.01e18;
        deal(address(base), alice, shares);

        _approve(base, alice, address(target), shares);
        vm.prank(alice);
        target.deposit(shares, alice);

        _approve(target, alice, address(principalToken), shares);
        vm.prank(alice);
        principalToken.supply(shares, alice);
    }
}
