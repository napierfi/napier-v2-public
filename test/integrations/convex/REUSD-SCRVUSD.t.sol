// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {ConvexTwoCryptoIntegrationTest} from "./Convex.t.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract REUSD_SCRVUSD_Test is ConvexTwoCryptoIntegrationTest {
    uint256 constant REUSDSCRVUSD_POOL_ID = 440;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22229742);
    }

    function setUp() public override {
        poolId = REUSDSCRVUSD_POOL_ID;
        convexRewardTokens = [CVX, CRV];
        super.setUp();
    }
}
