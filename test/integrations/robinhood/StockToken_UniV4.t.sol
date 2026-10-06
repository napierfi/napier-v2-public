// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {V4IntegrationTest} from "../V4Integration.t.sol";

import {Factory} from "src/Factory.sol";
import {IScaledUIAmount, RobinhoodStockTokenResolver} from "src/modules/resolvers/RobinhoodStockTokenResolver.sol";
import {LibBlueprint} from "src/utils/LibBlueprint.sol";

contract RobinhoodStockTokenUniV4ForkTest is V4IntegrationTest {
    address constant STOCK_TOKEN = 0xd95B44124e475743a7589e68F3D74008A5536D44;
    uint256 constant FORK_BLOCK_NUMBER = 69_490_000;

    address stock_token_resolver_blueprint =
        LibBlueprint.deployBlueprint(type(RobinhoodStockTokenResolver).creationCode);

    constructor() {
        vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK_NUMBER);
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, STOCK_TOKEN)
            sstore(base.slot, STOCK_TOKEN)
        }
    }

    function _setUpModules() internal override {
        super._setUpModules();
        vm.prank(admin);
        factory.setResolverBlueprint(stock_token_resolver_blueprint, true);
    }

    function testFork_MultiplierHighWatermarkAccruesYieldWithoutReversal() public {
        uint256 shares = 137 * tOne;
        deal(STOCK_TOKEN, alice, shares);

        vm.startPrank(alice);
        target.approve(address(principalToken), shares);
        principalToken.supply(shares, alice);
        vm.stopPrank();

        uint256 initialScale = IScaledUIAmount(STOCK_TOKEN).uiMultiplier();
        vm.mockCall(
            STOCK_TOKEN, abi.encodeCall(IScaledUIAmount.uiMultiplier, ()), abi.encode(initialScale + initialScale / 10)
        );

        uint256 balanceBefore = target.balanceOf(alice);
        vm.prank(alice);
        (uint256 collected,) = principalToken.collect(alice, alice);
        assertGt(collected, 0, "yield");
        assertEq(target.balanceOf(alice), balanceBefore + collected, "collected balance");

        vm.mockCall(STOCK_TOKEN, abi.encodeCall(IScaledUIAmount.uiMultiplier, ()), abi.encode(initialScale));
        assertEq(principalToken.previewCollect(alice), 0, "yield after scale decrease");

        vm.prank(alice);
        (collected,) = principalToken.collect(alice, alice);
        assertEq(collected, 0, "collected after scale decrease");
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        (suite, params) = getParamsForERC4626Resolver();
        suite.resolverBlueprint = stock_token_resolver_blueprint;
    }
}
