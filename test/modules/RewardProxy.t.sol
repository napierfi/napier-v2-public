// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Base, TwoCryptoBase} from "../TwoCryptoBase.t.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

import {RewardProxyModule} from "src/modules/RewardProxyModule.sol";
import {MockRewardProxyModule} from "../mocks/MockRewardProxy.sol";
import {MockPrincipalToken} from "../mocks/MockPrincipalToken.sol";

import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {ConstantFeeModule} from "src/modules/FeeModule.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import "src/Types.sol";
import "src/Constants.sol";
import {Errors} from "src/Errors.sol";

abstract contract RewardProxyBaseTest is TwoCryptoBase {
    address rewardProxy_logic;

    function setUp() public virtual override {
        Base.setUp();

        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();
    }

    function _deployTokens() internal virtual override {
        super._deployTokens();
    }

    function _setUpModules() internal override {
        super._setUpModules();

        vm.startPrank(admin);
        factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, rewardProxy_logic, true);
        vm.stopPrank();
    }

    function _deployInstance() internal override {
        FeePcts feePcts = FeePctsLib.pack(DEFAULT_SPLIT_RATIO_BPS, 0, 100, 0, BASIS_POINTS); // 100% split fee, 0 issuance fee, 1% performance fee, 0 redemption fee

        bytes memory poolArgs = abi.encode(twocryptoParams);
        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](2);
        moduleParams[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        moduleParams[1] = Factory.ModuleParam({
            moduleType: REWARD_PROXY_MODULE_INDEX,
            implementation: rewardProxy_logic,
            immutableData: getCustomArgs()
        });

        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
        (address _pt, address _yt, address _twocrypto) =
            factory.deploy({suite: suite, params: moduleParams, expiry: expiry, curator: curator});
        // Store instances
        assembly {
            sstore(principalToken.slot, _pt)
            sstore(yt.slot, _yt)
            sstore(twocrypto.slot, _twocrypto)
        }
        resolver = principalToken.i_resolver();
        feeModule = ConstantFeeModule(factory.moduleFor(_pt, FEE_MODULE_INDEX));
        rewardProxy = MockRewardProxyModule(factory.moduleFor(_pt, REWARD_PROXY_MODULE_INDEX)); // Note: MorphoRewardProxy
        accessManager = principalToken.i_accessManager();
    }

    function cloneRewardProxy(bytes memory customArgs) public {
        bytes memory args = abi.encode(principalToken, customArgs);
        address instance = LibClone.clone(rewardProxy_logic, args);
        assembly {
            sstore(rewardProxy.slot, instance)
        }
    }

    function getCustomArgs() public virtual returns (bytes memory);

    function test_RevertWhen_Reinitialize() public virtual {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        rewardProxy.initialize();
    }

    function test_RewardTokens() public view {
        assertEq(rewardProxy.rewardTokens().length, rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertEq(rewardProxy.rewardTokens()[i], rewardTokens[i]);
        }
    }

    function _test_RevertWhen_RewardTokensEmpty(bytes memory badCustomArgs) internal {
        cloneRewardProxy(badCustomArgs);
        vm.expectRevert();
        rewardProxy.initialize();
    }

    function _test_RevertWhen_DuplicatedRewardTokens(bytes memory badCustomArgs) internal {
        cloneRewardProxy(badCustomArgs);
        vm.expectRevert(Errors.RewardProxy_InconsistentRewardTokens.selector);
        rewardProxy.initialize();
    }

    function _test_RevertWhen_BadRewardTokens(bytes memory badCustomArgs) internal {
        cloneRewardProxy(badCustomArgs);
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

contract RewardProxyTest is RewardProxyBaseTest {
    address siloAsset;
    MockSiloDistributionManager distributor;

    function setUp() public override {
        siloAsset = makeAddr("silo_asset");
        distributor = new MockSiloDistributionManager();
        mockRewardProxy_logic = address(new MockSiloRewardProxyModule());
        rewardProxy_logic = mockRewardProxy_logic;

        Base.setUp();

        principalToken = PrincipalToken(address(new MockPrincipalToken(address(factory))));

        // Deploy the rewardProxy module
        bytes memory customArgs = getCustomArgs();
        cloneRewardProxy(customArgs);
        rewardProxy.initialize();

        // Toy data
        distributor.setRewardToken(rewardTokens[0]);
        distributor.setReward(address(principalToken), 1000);
    }

    function getCustomArgs() public view override returns (bytes memory) {
        return abi.encode(rewardTokens, distributor, siloAsset);
    }

    function test_RevertWhen_RewardTokensEmpty() public {
        bytes memory customArgs = abi.encode(new address[](0), distributor, siloAsset);
        _test_RevertWhen_RewardTokensEmpty(customArgs);
    }

    function test_RevertWhen_DuplicatedRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = rewardTokens[0];
        badRewardTokens[1] = rewardTokens[0]; // Duplicate reward token address
        bytes memory customArgs = abi.encode(badRewardTokens, distributor, siloAsset);
        _test_RevertWhen_DuplicatedRewardTokens(customArgs);
    }

    function test_RevertWhen_BadRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = address(0x02);
        badRewardTokens[1] = address(0x01); // Descending order
        bytes memory customArgs = abi.encode(badRewardTokens, distributor, siloAsset);
        _test_RevertWhen_BadRewardTokens(customArgs);
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
