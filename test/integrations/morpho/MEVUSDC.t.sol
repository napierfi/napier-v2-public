// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {V4IntegrationTest} from "../V4Integration.t.sol";

import {Factory} from "src/Factory.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract MEVUSDCForkTest is V4IntegrationTest {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MEVUSDC = 0xd63070114470f685b75B74D60EEc7c1113d33a3D;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 23150000);
    }

    function setUp() public override {
        super.setUp();
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, MEVUSDC)
            sstore(base.slot, USDC)
        }
        vm.label(address(target), "MEVUSDC");
        vm.label(address(base), "USDC");
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        return getParamsForERC4626Resolver();
    }
}
