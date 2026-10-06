// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {ConvexTwoCryptoIntegrationTest} from "./Convex.t.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

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
