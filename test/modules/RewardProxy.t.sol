// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {RewardProxyModule, TokenReward} from "src/modules/RewardProxyModule.sol";
import {TokenReward} from "src/Types.sol";
import {Errors} from "src/Errors.sol";

contract RewardProxyTest is PrincipalTokenTest {
    MockSiloDistributionManager distributor;

    function setUp() public override {
        // Override rewardProxy implementation
        mockRewardProxy_logic = address(new MockSiloRewardProxyModule());
        super.setUp();

        distributor = new MockSiloDistributionManager();
        address siloAsset = makeAddr("silo_asset");

        // Deploy the rewardProxy module
        bytes memory customArgs = abi.encode(rewardTokens, distributor, siloAsset);
        cloneRewardProxy(customArgs);
        rewardProxy.initialize();

        // Toy data
        distributor.setRewardToken(rewardTokens[0]);
        distributor.setReward(address(principalToken), 1000);
    }

    function cloneRewardProxy(bytes memory customArgs) public {
        bytes memory args = abi.encode(principalToken, customArgs);
        address instance = LibClone.clone(mockRewardProxy_logic, args);
        assembly {
            sstore(rewardProxy.slot, instance)
        }
    }

    /// @dev RewardProxy.initialize() is view function
    function test_RevertWhen_Reinitialize() public {}

    function test_RewardTokens() public view {
        assertEq(rewardProxy.rewardTokens().length, rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(rewardProxy.rewardTokens()[i], rewardTokens[i]);
        }
    }

    function test_RevertWhen_RewardTokensEmpty() public {
        bytes memory customArgs = abi.encode(new address[](0), distributor, makeAddr("silo_asset"));
        cloneRewardProxy(customArgs);
        vm.expectRevert();
        rewardProxy.initialize();
    }

    function test_RevertWhen_DuplicatedRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = rewardTokens[0];
        badRewardTokens[1] = rewardTokens[0]; // Duplicate reward token address
        bytes memory customArgs = abi.encode(badRewardTokens, distributor, makeAddr("silo_asset"));
        cloneRewardProxy(customArgs);
        vm.expectRevert(Errors.RewardProxy_InconsistentRewardTokens.selector);
        rewardProxy.initialize();
    }

    function test_RevertWhen_BadRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = address(0x02);
        badRewardTokens[1] = address(0x01); // Descending order
        bytes memory customArgs = abi.encode(badRewardTokens, distributor, makeAddr("silo_asset"));
        cloneRewardProxy(customArgs);
        vm.expectRevert(Errors.RewardProxy_InconsistentRewardTokens.selector);
        rewardProxy.initialize();
    }

    function test_Rescue() public {
        vm.mockCall(
            address(principalToken.i_accessManager()),
            abi.encodeWithSelector(
                accessManager.canCall.selector, alice, address(rewardProxy), rewardProxy.rescue.selector
            ),
            abi.encode(true)
        );
        deal(address(rewardTokens[0]), address(rewardProxy), 999);
        vm.prank(alice);
        rewardProxy.rescue(address(rewardTokens[0]), alice, 999);
        assertEq(ERC20(rewardTokens[0]).balanceOf(alice), 999);
    }

    function test_Rescue_RevertWhen_Unauthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        rewardProxy.rescue(address(rewardTokens[0]), alice, 999);
    }
}

/// @notice https://github.com/silo-finance/silo-core-v1/blob/e3e660a8320840b7a0d9b6791aac26208f3088dc/contracts/incentives/SiloIncentivesController.sol
contract MockSiloDistributionManager {
    ERC20 s_rewardToken;
    mapping(address => uint256) s_amounts;

    function setRewardToken(address rewardToken) external {
        s_rewardToken = ERC20(rewardToken);
    }

    function setReward(address user, uint256 amount) external {
        s_amounts[user] = amount;
    }

    /// @custom:param assets Silo YBT address (underlying)
    function claimRewards(address[] calldata, /* assets */ uint256, /* amount */ address to)
        external
        returns (uint256)
    {
        uint256 value = s_amounts[msg.sender];
        s_amounts[msg.sender] = 0;
        s_rewardToken.transfer(to, value);
        return value;
    }
}

/// @notice RewadProxy for Silo finance SILO rewards
/// @dev CWIA is encoded as follows: abi.encode(address principalToken, abi.encode(address rewardTokens, address distributor, address underlying))
contract MockSiloRewardProxyModule is RewardProxyModule {
    bytes32 public constant override VERSION = "2.0.0";

    function collectReward(address rewardProxy) public override returns (TokenReward[] memory) {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(rewardProxy), (address, bytes));

        (address[] memory rewardTokens, MockSiloDistributionManager distributor, address underlying) =
            abi.decode(args, (address[], MockSiloDistributionManager, address));

        address[] memory assets = new address[](1);
        assets[0] = underlying;
        uint256 amount = distributor.claimRewards(assets, type(uint256).max, address(this));

        TokenReward[] memory rewards = new TokenReward[](1);
        rewards[0] = TokenReward({token: rewardTokens[0], amount: amount});
        return rewards;
    }

    function _rewardTokens(address rewardProxy) internal view override returns (address[] memory) {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(rewardProxy), (address, bytes));

        (address[] memory rewardTokens,,) = abi.decode(args, (address[], MockSiloDistributionManager, address));
        return rewardTokens;
    }
}
