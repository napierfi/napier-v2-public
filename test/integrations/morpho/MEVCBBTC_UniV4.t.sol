// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {V4IntegrationTest} from "../V4Integration.t.sol";

import {Factory} from "src/Factory.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract MEVCBBTC_UniV4ForkTest is V4IntegrationTest {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant MORPHO_VAULT_MEVCBBTC = 0x98cF0B67Da0F16E1F8f1a1D23ad8Dc64c0c70E0b;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 23150000);
    }

    function setUp() public override {
        super.setUp();
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, MORPHO_VAULT_MEVCBBTC)
            sstore(base.slot, CBBTC)
        }
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
