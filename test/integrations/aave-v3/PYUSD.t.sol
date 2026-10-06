// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {Factory} from "src/Factory.sol";
import {AccessManager} from "src/modules/AccessManager.sol";
import {WrapperConnector} from "src/modules/connectors/WrapperConnector.sol";
import {WrapperFactory} from "src/wrapper/WrapperFactory.sol";
import {ATokenWrapper} from "src/wrapper/aave-v3/ATokenWrapper.sol";
import {IAToken} from "src/wrapper/aave-v3/interfaces/IAToken.sol";
import {IPool} from "src/wrapper/aave-v3/interfaces/IPool.sol";
import {TwoCryptoZap} from "src/zap/twocrypto/TwoCryptoZap.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract PYUSDTest is TwoCryptoIntegrationTest {
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant APYUSD = 0x0C0d01AbF3e6aDfcA0989eBbA9d6e85dD58EaB1E;
    IPool aavePool; // Aave V3 Pool

    WrapperFactory wrapperFactory;
    ATokenWrapper wrapper;
    bytes32 salt = bytes32(uint256(123));

    address donor = makeAddr("donor");

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21942620);
    }

    function setUp() public override {
        vm.label(PYUSD, "pyUSD");
        vm.label(APYUSD, "apyUSD");

        aavePool = IAToken(APYUSD).POOL();

        expiry = block.timestamp + 365 days;

        napierAccessManager = new AccessManager();
        napierAccessManager.initializeOwner(admin);
        address factoryImplementation = address(new Factory());
        bytes memory args = abi.encode(napierAccessManager);
        factory = Factory(LibClone.deployERC1967(factoryImplementation, args));

        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        bOne = 10 ** ERC20(PYUSD).decimals();
        tOne = 10 ** wrapper.decimals();

        // Account setup

        // apyUSD
        deal(PYUSD, donor, 1000e6);
        _approve(PYUSD, donor, address(aavePool), type(uint256).max);
        vm.prank(donor);
        aavePool.supply(PYUSD, 1000e6, alice, 0);

        // Wrapper
        deal(PYUSD, donor, 100_000e6);
        _approve(PYUSD, donor, address(wrapper), type(uint256).max);
        vm.prank(donor);
        uint256 shares = wrapper.deposit(Token.wrap(PYUSD), 10_000e6, donor);

        vm.prank(donor);
        wrapper.transfer(alice, shares / 2);

        vm.prank(donor);
        wrapper.transfer(bob, shares / 2);

        // pyUSD
        deal(PYUSD, alice, 1_000e6);

        // Alice has 5_000 np-apyUSD, 1000 apyUSD and 1_000 pyUSD
        // Bob has 5_000 np-apyUSD, 1000 apyUSD
        _label();
    }

    function _deployPeriphery() internal override {
        super._deployPeriphery();

        address wrapperConnectorImplementation = address(new WrapperConnector());
        wrapperFactory = new WrapperFactory(
            address(napierAccessManager), address(weth), address(connectorRegistry), wrapperConnectorImplementation
        );
    }

    function _deployInstance() internal override {
        address implementation = address(new ATokenWrapper());

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = WrapperFactory.setWrapperImplementation.selector;
        factory.i_accessManager().grantTargetFunctionRoles(address(wrapperFactory), selectors, Constants.DEV_ROLE);

        factory.i_accessManager().grantRoles(address(wrapperFactory), Constants.CONNECTOR_REGISTRY_ROLE);
        selectors = new bytes4[](1);
        selectors[0] = connectorRegistry.setConnector.selector;
        factory.i_accessManager().grantTargetFunctionRoles(
            address(connectorRegistry), selectors, Constants.CONNECTOR_REGISTRY_ROLE
        );

        wrapperFactory.setWrapperImplementation(implementation, true);
        wrapper = ATokenWrapper(wrapperFactory.createWrapper(implementation, abi.encode(APYUSD), salt));
        vm.stopPrank();

        assembly {
            sstore(target.slot, sload(wrapper.slot))
            sstore(base.slot, PYUSD)
        }
        super._deployInstance();
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        return getParamsForERC4626Resolver();
    }

    function testFork_PrincipalTokenLifecycle() public override {
        uint256 assets = 100 * 10 * ERC20(APYUSD).decimals();
        _approve(APYUSD, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        uint256 principal = zap.supply(principalToken, Token.wrap(APYUSD), assets, alice, 0);

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
        zap.redeem(principalToken, Token.wrap(APYUSD), principal, alice, 0);

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        assertGe(wrapper.balanceOf(address(principalToken)), curatorFee + protocolFee, "apyUSD balance");

        assertEq(principalToken.balanceOf(alice), 0, "Zero principal token balance");
        assertEq(principalToken.totalSupply(), 0, "Zero principal token supply");
    }

    function testFork_AddLiquidityOneToken() public override {
        // First deposit
        uint256 assets = 1_000 * tOne;
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: Token.wrap(PYUSD),
            amountIn: assets,
            receiver: alice,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        _approve(PYUSD, alice, address(zap), assets);
        vm.prank(alice);
        (uint256 liquidity, uint256 principal) = zap.addLiquidityOneToken(params);

        assertEq(ERC20(twocrypto.unwrap()).balanceOf(alice), liquidity, "liquidity balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");
        assertNoFundLeft();
    }
}
