// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {ZapBase} from "../Base.t.sol";

import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";

import {ConstantPriceResolver} from "src/modules/resolvers/ConstantPriceResolver.sol";
import {CustomConversionResolver} from "src/modules/resolvers/CustomConversionResolver.sol";
import {ERC4626InfoResolver} from "src/modules/resolvers/ERC4626InfoResolver.sol";
import {ExternalPriceResolver} from "src/modules/resolvers/ExternalPriceResolver.sol";
import {SharePriceResolver} from "src/modules/resolvers/SharePriceResolver.sol";

import {LibBlueprint} from "src/utils/LibBlueprint.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import "src/Constants.sol" as Constants;
import "src/Types.sol";

using {TokenType.intoToken} for address;

abstract contract IntegrationTest is ZapBase {
    using LibTwoCryptoNG for TwoCrypto;

    // forgefmt: disable-start
    address constant_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(ConstantPriceResolver).creationCode);
    address erc4626_resolver_blueprint = LibBlueprint.deployBlueprint(type(ERC4626InfoResolver).creationCode);
    address custom_conversion_resolver_blueprint = LibBlueprint.deployBlueprint(type(CustomConversionResolver).creationCode);
    address share_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(SharePriceResolver).creationCode);
    address external_price_resolver_blueprint = LibBlueprint.deployBlueprint(type(ExternalPriceResolver).creationCode);
    // forgefmt: disable-end

    function _deployTokens() internal virtual override {}

    function getDeploymentParams()
        public
        view
        virtual
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params);

    function getParamsForERC4626Resolver()
        public
        view
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        FeePcts feePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183);

        bytes memory poolArgs = abi.encode(twocryptoParams);
        params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
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

    function setUp() public virtual override {
        assembly {
            sstore(weth.slot, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
        }
        super.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();
    }

    /// @dev Add new resolver deployment here
    function _setUpModules() internal override {
        super._setUpModules();
        vm.startPrank(admin);
        factory.setResolverBlueprint(erc4626_resolver_blueprint, true);
        factory.setResolverBlueprint(share_price_resolver_blueprint, true);
        factory.setResolverBlueprint(external_price_resolver_blueprint, true);
        factory.setResolverBlueprint(custom_conversion_resolver_blueprint, true);
        factory.setResolverBlueprint(constant_price_resolver_blueprint, true);
        vm.stopPrank();
    }

    function _deployInstance() internal override {
        (Factory.Suite memory suite, Factory.ModuleParam[] memory params) = getDeploymentParams();

        (address _pt,, address _twocrypto) =
            factory.deploy({suite: suite, params: params, expiry: expiry, curator: curator});
        // Store instances
        principalToken = PrincipalToken(_pt);
        yt = principalToken.i_yt();
        twocrypto = TwoCrypto.wrap(_twocrypto);
        resolver = principalToken.i_resolver();
        accessManager = principalToken.i_accessManager();
    }

    function testFork_PrincipalTokenLifecycle() public {
        uint256 initialUnderlyingBalance = target.balanceOf(alice);

        uint256 shares = 100 * tOne;
        _approve(target, alice, address(zap), type(uint256).max);
        vm.prank(alice);
        uint256 principal = zap.supply(principalToken, address(target).intoToken(), shares, alice, 0);

        assertEq(yt.balanceOf(alice), principal, "yt balance");
        assertEq(principalToken.balanceOf(alice), principal, "principal token balance");

        uint256 prevUnderlyingBalance = target.balanceOf(alice);
        vm.prank(alice);
        principalToken.collect(alice, alice);
        assertEq(target.balanceOf(alice), prevUnderlyingBalance, "No interest should be collected");

        vm.warp(expiry);

        _approve(principalToken, alice, address(zap), principal);
        vm.prank(alice);
        zap.redeem(principalToken, address(target).intoToken(), principal, alice, 0);

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        assertApproxEqRel(
            target.balanceOf(alice) + curatorFee + protocolFee,
            initialUnderlyingBalance,
            0.000001e18,
            "Principal token should be redeemed for underlying"
        );
    }

    function testFork_AddLiquidityOneToken() public {
        // First deposit
        uint256 amount = 1_000 * tOne;
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: address(target).intoToken(),
            amountIn: amount,
            receiver: alice,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        _approve(target, alice, address(zap), amount);
        vm.prank(alice);
        (uint256 liquidity, uint256 principal) = zap.addLiquidityOneToken(params);

        assertEq(twocrypto.balanceOf(alice), liquidity, "liquidity balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");
        assertNoFundLeft();
    }

    function testFork_CreateAndAddLiquidity() public {
        uint256 initialLiquidity = 1_000 * tOne;
        _approve(target, alice, address(zap), initialLiquidity);

        (Factory.Suite memory suite, Factory.ModuleParam[] memory m) = getDeploymentParams();
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = TwoCryptoZap.CreateAndAddLiquidityParams({
            suite: suite,
            modules: m,
            expiry: expiry,
            curator: curator,
            shares: initialLiquidity,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        vm.prank(alice);
        ( /* address pt */ , /* address yt */, address twoCrypto, uint256 liquidity, uint256 principal) =
            zap.createAndAddLiquidity(params);

        twocrypto = TwoCrypto.wrap(twoCrypto);
        principalToken = PrincipalToken(twocrypto.coins(Constants.PT_INDEX));
        yt = principalToken.i_yt();
        resolver = principalToken.i_resolver();
        accessManager = principalToken.i_accessManager();

        assertEq(twocrypto.balanceOf(alice), liquidity, "liquidity balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");

        (uint256 underlyingReserve, uint256 principalReserve) =
            (twocrypto.balances(Constants.TARGET_INDEX), twocrypto.balances(Constants.PT_INDEX));

        // reserve ratio should be close to initial price
        assertApproxEqRel(
            underlyingReserve * 1e18 / tOne, // to 18 decimals
            twocryptoParams.initial_price * principalReserve / bOne, // to 18 decimals
            0.000001e18,
            "price impact should be negligible"
        );
    }
}
