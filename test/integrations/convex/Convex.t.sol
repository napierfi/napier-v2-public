// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {Factory} from "src/Factory.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {WrapperConnector} from "src/modules/connectors/WrapperConnector.sol";
import {WrapperFactory} from "src/wrapper/WrapperFactory.sol";
import {ConvexWrapper} from "src/wrapper/convex/ConvexWrapper.sol";
import {WrapperRewardProxy} from "src/modules/reward-proxies/WrapperRewardProxy.sol";
import {IBooster} from "src/wrapper/convex/interfaces/IBooster.sol";
import {TwoCryptoZap} from "src/zap/twocrypto/TwoCryptoZap.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

abstract contract ConvexTwoCryptoIntegrationTest is TwoCryptoIntegrationTest {
    IBooster constant BOOSTER = IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    address constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;
    address constant CRV = 0xD533a949740bb3306d119CC777fa900bA034cd52;

    address[] convexRewardTokens;
    uint256 poolId;

    address donor = makeAddr("donor");
    address wrapperImplementation;
    address rewardProxyImplementation;
    WrapperFactory wrapperFactory;
    ConvexWrapper wrapper;

    function setUp() public virtual override {
        expiry = block.timestamp + 365 days;

        (address lpToken,,,,,) = BOOSTER.poolInfo(poolId);

        base = ERC20(lpToken);

        napierAccessManager = new AccessManager();
        napierAccessManager.initializeOwner(admin);
        address factoryImplementation = address(new Factory());
        bytes memory args = abi.encode(napierAccessManager);
        factory = Factory(LibClone.deployERC1967(factoryImplementation, args));

        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        bOne = 10 ** ERC20(base).decimals();
        tOne = 10 ** wrapper.decimals();

        // Account setup

        deal(address(base), alice, 1_000e18);

        // Wrapper
        deal(address(base), donor, 10_000e18);
        _approve(address(base), donor, address(wrapper), type(uint256).max);
        vm.prank(donor);
        uint256 shares = wrapper.deposit(Token.wrap(address(base)), 2_000e18, donor);

        vm.prank(donor);
        wrapper.transfer(alice, shares / 2);

        vm.prank(donor);
        wrapper.transfer(bob, shares / 2);

        // Alice has 1000 np-LP tokens, 1000 LP tokens
        // Bob has 1000 np-LP tokens, 1000 LP tokens

        _label();

        require(ConvexWrapper(address(wrapper)).s_principalToken() == address(principalToken), "TEST: principal token");
    }

    function _deployPeriphery() internal override {
        super._deployPeriphery();

        address wrapperConnectorImplementation = address(new WrapperConnector());
        wrapperFactory = new WrapperFactory(
            address(napierAccessManager), address(weth), address(connectorRegistry), wrapperConnectorImplementation
        );
    }

    function _deployInstance() internal override {
        {
            address implementation = address(new ConvexWrapper());

            vm.startPrank(admin);
            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = WrapperFactory.setWrapperImplementation.selector;
            factory.i_accessManager().grantTargetFunctionRoles(address(wrapperFactory), selectors, Constants.DEV_ROLE);
            wrapperFactory.setWrapperImplementation(implementation, true);

            factory.i_accessManager().grantRoles(address(wrapperFactory), Constants.CONNECTOR_REGISTRY_ROLE);
            selectors = new bytes4[](1);
            selectors[0] = connectorRegistry.setConnector.selector;
            factory.i_accessManager().grantTargetFunctionRoles(
                address(connectorRegistry), selectors, Constants.CONNECTOR_REGISTRY_ROLE
            );

            rewardProxyImplementation = address(new WrapperRewardProxy());
            factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, rewardProxyImplementation, true);

            bytes32 salt = bytes32(uint256(123));
            wrapper = ConvexWrapper(wrapperFactory.createWrapper(implementation, abi.encode(poolId, BOOSTER), salt));
        }

        vm.stopPrank();

        assembly {
            sstore(target.slot, sload(wrapper.slot))
        }
        super._deployInstance();

        // Set principal token
        {
            vm.startPrank(admin);

            bytes4[] memory selectors = new bytes4[](1);
            selectors[0] = ConvexWrapper.setPrincipalToken.selector;
            factory.i_accessManager().grantTargetFunctionRoles(address(wrapper), selectors, Constants.DEV_ROLE);

            wrapper.setPrincipalToken(address(principalToken));
            vm.stopPrank();
        }
    }

    function test_RewardTokens() public {
        vm.expectRevert();
        vm.prank(admin);
        wrapper.setPrincipalToken(address(principalToken));

        vm.prank(address(principalToken));
        TokenReward[] memory rewards = wrapper.claimRewards();
        assertEq(rewards.length, convexRewardTokens.length, "rewards length mismatch");
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        FeePcts feePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183);

        bytes memory poolArgs = abi.encode(twocryptoParams);
        params = new Factory.ModuleParam[](2);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        params[1] = Factory.ModuleParam({
            moduleType: REWARD_PROXY_MODULE_INDEX,
            implementation: rewardProxyImplementation,
            immutableData: abi.encode(convexRewardTokens)
        });
        bytes memory resolverArgs = abi.encode(address(target)); // Change based on the resolver blueprint
        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: erc4626_resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }

    function testFork_PrincipalTokenLifecycle() public override {
        uint256 assets = 100 * 10 * ERC20(base).decimals();
        _approve(base, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        uint256 principal = zap.supply(principalToken, Token.wrap(address(base)), assets, alice, 0);

        assertEq(yt.balanceOf(alice), principal, "yt balance");
        assertEq(principalToken.balanceOf(alice), principal, "principal token balance");

        uint256 prevUnderlyingBalance = target.balanceOf(alice);
        vm.prank(alice);
        principalToken.collect(alice, alice);
        assertEq(target.balanceOf(alice), prevUnderlyingBalance, "No interest should be collected");

        vm.warp(expiry); // Some interest may be accrued by skipping the time

        vm.prank(alice);
        principalToken.collect(alice, alice);

        _approve(principalToken, alice, address(zap), principal);
        vm.prank(alice);
        zap.redeem(principalToken, Token.wrap(address(base)), principal, alice, 0);

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        assertGe(wrapper.balanceOf(address(principalToken)), curatorFee + protocolFee, "balance");

        assertEq(principalToken.balanceOf(alice), 0, "Zero principal token balance");
        assertEq(principalToken.totalSupply(), 0, "Zero principal token supply");
    }

    function testFork_AddLiquidityOneToken() public override {
        // First deposit
        uint256 assets = 31323143421339098;
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: Token.wrap(address(base)),
            amountIn: assets,
            receiver: alice,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        _approve(base, alice, address(zap), assets);
        vm.prank(alice);
        (uint256 liquidity, uint256 principal) = zap.addLiquidityOneToken(params);

        assertEq(ERC20(twocrypto.unwrap()).balanceOf(alice), liquidity, "liquidity balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");
        assertNoFundLeft();
    }
}

contract PXETH_STETH_Test is ConvexTwoCryptoIntegrationTest {
    uint256 constant PXETHSTETH_POOL_ID = 273;
    address constant DINERO = 0x6DF0E641FC9847c0c6Fde39bE6253045440c14d3;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
    }

    function setUp() public override {
        poolId = PXETHSTETH_POOL_ID;
        convexRewardTokens = [CVX, DINERO, CRV];
        super.setUp();
    }
}
