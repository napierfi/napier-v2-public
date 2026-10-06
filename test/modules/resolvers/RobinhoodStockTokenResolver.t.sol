// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/src/Test.sol";

import {Errors} from "../../../src/Errors.sol";
import {
    IScaledUIAmount,
    RobinhoodStockTokenResolver
} from "../../../src/modules/resolvers/RobinhoodStockTokenResolver.sol";

contract RobinhoodStockTokenResolverTest is Test {
    address internal constant STOCK_TOKEN = 0xd95B44124e475743a7589e68F3D74008A5536D44;
    uint256 internal constant FORK_BLOCK_NUMBER = 69_490_000;

    RobinhoodStockTokenResolver internal resolver;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK_NUMBER);
    }

    function setUp() public {
        resolver = new RobinhoodStockTokenResolver(STOCK_TOKEN);
    }

    function testFork_Constructor() public view {
        assertEq(resolver.asset(), STOCK_TOKEN);
        assertEq(resolver.target(), STOCK_TOKEN);
        assertEq(resolver.assetDecimals(), 18);
        assertEq(resolver.decimals(), 18);
        assertEq(resolver.label(), "RobinhoodStockTokenResolver");
    }

    function test_Constructor_RevertWhen_StockTokenIsZeroAddress() public {
        vm.expectRevert(Errors.Resolver_ZeroAddress.selector);
        new RobinhoodStockTokenResolver(address(0));
    }

    function testFork_ScaleReturnsPinnedOnchainMultiplier() public view {
        uint256 multiplierSnapshot = IScaledUIAmount(STOCK_TOKEN).uiMultiplier();
        assertEq(resolver.scale(), multiplierSnapshot);
    }
}
