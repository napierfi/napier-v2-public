// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {IntegrationTest} from "../Integration.t.sol";

import {Factory} from "src/Factory.sol";

contract MEVCBBTCForkTest is IntegrationTest {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant MORPHO_VAULT_MEVCBBTC = 0x98cF0B67Da0F16E1F8f1a1D23ad8Dc64c0c70E0b;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public override {
        super.setUp();

        deal(MORPHO_VAULT_MEVCBBTC, alice, 1_000 * tOne);
        deal(MORPHO_VAULT_MEVCBBTC, bob, 1_000 * tOne);
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, MORPHO_VAULT_MEVCBBTC)
            sstore(base.slot, CBBTC)
        }
    }

    function getDeploymentParams() public view override returns (Factory.Suite memory, Factory.ModuleParam[] memory) {
        return getParamsForERC4626Resolver();
    }
}
