// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Base} from "../Base.t.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {FeePcts, FeePctsLib} from "src/utils/FeePctsLib.sol";
import {MockFeeModule} from "../mocks/MockFeeModule.sol";
import {ModuleAccessor} from "src/utils/ModuleAccessor.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {Errors} from "src/Errors.sol";

contract CollectFeesTest is PrincipalTokenTest {
    using stdStorage for StdStorage;

    function toyInit() internal returns (Init memory init) {
        init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: int256(1e18)
        });
    }

    function setUp() public override {
        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        // Overwrite fee module to use MockFeeModule
        FeePcts feePcts = FeePctsLib.pack(2_000, 0, 1000, 0, 200);
        deployCodeTo("MockFeeModule", address(feeModule));
        MockFeeModule(address(feeModule)).setFeePcts(feePcts);

        // Toy data setup: deposit some shares
        uint256 lscale = resolver.scale();
        Init memory init = toyInit();
        setUpVault(init);
        require(resolver.scale() > lscale, "TEST: Scale must be greater than initial scale");

        vm.warp(expiry);
        vm.startPrank(alice);
        principalToken.collect(alice, alice); // Settle
        vm.warp(expiry + 10 days); // Accrue some rewards
        principalToken.collect(alice, alice); // Accrue fee rewards

        changePrank(admin);
        napierAccessManager.grantRoles(admin, Constants.FEE_COLLECTOR_ROLE);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.collectCuratorFees.selector; // In theory, this assignment doesn't work because protocol curator fees collection is restricted by Curator's Access Manager
        selectors[1] = principalToken.collectProtocolFees.selector;
        napierAccessManager.grantTargetFunctionRoles(address(principalToken), selectors, Constants.FEE_COLLECTOR_ROLE);
        vm.stopPrank();

        vm.startPrank(curator);
        accessManager.grantRoles(feeCollector, Constants.FEE_COLLECTOR_ROLE);
        selectors = new bytes4[](2);
        selectors[0] = principalToken.collectCuratorFees.selector;
        selectors[1] = principalToken.collectProtocolFees.selector; // In theory, this assignment doesn't work
        accessManager.grantTargetFunctionRoles(address(principalToken), selectors, Constants.FEE_COLLECTOR_ROLE);
        vm.stopPrank();
    }

    function test_CollectCuratorFees_Ok() public {
        address[] memory additionalTokens = new address[](0);
        _test_CollectCuratorFees(additionalTokens);
    }

    function _test_CollectCuratorFees(address[] memory additionalTokens) internal {
        (uint256 expectInterestFee,) = principalToken.getFees();
        uint256[] memory expectFeeRewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (uint256 curatorReward,) = principalToken.getFeeRewards(rewardTokens[i]);
            expectFeeRewards[i] = curatorReward;
        }

        vm.prank(feeCollector);
        (uint256 interestFee, TokenReward[] memory feeRewards) =
            principalToken.collectCuratorFees({additionalTokens: additionalTokens, feeReceiver: dev});

        // Check that the fees received are as expected and return values are correct
        assertEq(interestFee, expectInterestFee, "Interest fee collected");
        assertEq(target.balanceOf(dev), expectInterestFee, "Interest fee collected to dev");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(feeRewards[i].amount, expectFeeRewards[i], "Rewards collected");
            assertEq(ERC20(rewardTokens[i]).balanceOf(dev), expectFeeRewards[i], "Rewards collected to dev");
        }

        // Check that the rewards are zeroed out after collection
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (uint256 curatorReward,) = principalToken.getFeeRewards(rewardTokens[i]);
            assertEq(curatorReward, 0, "Rewards zeroed out");
        }
    }

    function test_CollectProtocolFees_Ok() public {
        address[] memory additionalTokens = new address[](0);
        _test_CollectProtocolFees(additionalTokens);
    }

    function _test_CollectProtocolFees(address[] memory additionalTokens) internal {
        (, uint256 expectInterestFee) = principalToken.getFees();
        uint256[] memory expectFeeRewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (, uint256 protocolReward) = principalToken.getFeeRewards(rewardTokens[i]);
            expectFeeRewards[i] = protocolReward;
        }

        vm.prank(admin);
        (uint256 interestFee, TokenReward[] memory feeRewards) = principalToken.collectProtocolFees(additionalTokens);

        // Check that the fees received are as expected and return values are correct
        assertEq(interestFee, expectInterestFee, "Interest fee collected");
        assertEq(target.balanceOf(treasury), expectInterestFee, "Interest fee collected to treasury");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(feeRewards[i].amount, expectFeeRewards[i], "Rewards collected");
            assertEq(ERC20(rewardTokens[i]).balanceOf(treasury), expectFeeRewards[i], "Rewards collected to treasury");
        }

        // Check that the rewards are zeroed out after collection
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (, uint256 protocolReward) = principalToken.getFeeRewards(rewardTokens[i]);
            assertEq(protocolReward, 0, "Rewards zeroed out");
        }
    }

    function test_CollectCuratorFees_When_Duplicated() public {
        address[] memory duplicatedTokens = new address[](4);
        duplicatedTokens[0] = rewardTokens[0];
        duplicatedTokens[1] = rewardTokens[1];
        duplicatedTokens[2] = rewardTokens[1];
        duplicatedTokens[3] = address(target);

        _test_CollectCuratorFees(rewardTokens);
    }

    function test_CollectProtocolFees_When_Duplicated() public {
        address[] memory duplicatedTokens = new address[](4);
        duplicatedTokens[0] = rewardTokens[0];
        duplicatedTokens[1] = rewardTokens[1];
        duplicatedTokens[2] = rewardTokens[1];
        duplicatedTokens[3] = address(target);

        _test_CollectProtocolFees(duplicatedTokens);
    }

    function test_CollectCuratorFees_When_NoRewardProxy() public {
        // Remove rewardProxy
        address pointer = principalToken.s_modules();
        address[] memory modules = ModuleAccessor.read(pointer);
        ModuleAccessor.set(modules, REWARD_PROXY_MODULE_INDEX, address(0));
        address newPointer = SSTORE2.write(abi.encode(modules));
        vm.prank(address(factory));
        principalToken.setModules(newPointer);

        // Pre-condition
        uint256[] memory expectFeeRewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (uint256 curatorReward,) = principalToken.getFeeRewards(rewardTokens[i]);
            expectFeeRewards[i] = curatorReward;
        }

        vm.prank(feeCollector);
        (, TokenReward[] memory feeRewards) =
            principalToken.collectCuratorFees({additionalTokens: rewardTokens, feeReceiver: dev});

        assertEq(feeRewards.length, rewardTokens.length, "Number of fee rewards matches number of reward tokens");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(feeRewards[i].amount, expectFeeRewards[i], "Fee reward amount matches expected");
        }
    }

    function test_CollectProtocolFees_When_NoRewardProxy() public {
        // Remove rewardProxy
        address pointer = principalToken.s_modules();
        address[] memory modules = ModuleAccessor.read(pointer);
        ModuleAccessor.set(modules, REWARD_PROXY_MODULE_INDEX, address(0));
        address newPointer = SSTORE2.write(abi.encode(modules));
        vm.prank(address(factory));
        principalToken.setModules(newPointer);

        // Pre-condition
        uint256[] memory expectFeeRewards = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            (, uint256 protocolReward) = principalToken.getFeeRewards(rewardTokens[i]);
            expectFeeRewards[i] = protocolReward;
        }

        vm.prank(admin);
        (, TokenReward[] memory feeRewards) = principalToken.collectProtocolFees({additionalTokens: rewardTokens});

        assertEq(feeRewards.length, rewardTokens.length, "Number of fee rewards matches number of reward tokens");
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(feeRewards[i].amount, expectFeeRewards[i], "Fee reward amount matches expected");
        }
    }

    function test_CollectCuratorFees_RevertWhen_NotAuthorized() public {
        address[] memory additionalTokens = new address[](0);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(alice); // User
        principalToken.collectCuratorFees(additionalTokens, alice);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(admin); // Napier
        principalToken.collectCuratorFees(additionalTokens, alice);
    }

    function test_CollectProtocolFees_RevertWhen_NotAuthorized() public {
        address[] memory additionalTokens = new address[](0);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob); // User
        principalToken.collectProtocolFees(additionalTokens);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(feeCollector); // Curator's fee collector
        principalToken.collectProtocolFees(additionalTokens);
    }

    // Revert with arithmetic underflow when interest fee is zero
    function test_RevertWhen_InterestFeeZero() public {
        vm.skip(true);
    }
}
