// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {ConvexTwoCryptoIntegrationTest} from "./Convex.t.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract RSUP_WETH_Test is ConvexTwoCryptoIntegrationTest {
    uint256 constant RSUPWETH_POOL_ID = 441;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
    }

    function setUp() public override {
        poolId = RSUPWETH_POOL_ID;
        convexRewardTokens = [CVX, CRV];
        super.setUp();
    }
}
