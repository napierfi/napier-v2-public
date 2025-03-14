// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {IntegrationTest} from "../Integration.t.sol";

import {Factory} from "src/Factory.sol";

import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract USRForkTest is IntegrationTest {
    address constant USR = 0x66a1E37c9b0eAddca17d3662D6c05F4DECf3e110;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function setUp() public override {
        super.setUp();

        deal(USR, alice, 1_000 * tOne);
        deal(USR, bob, 1_000 * tOne);
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, USR)
            sstore(base.slot, USR)
        }
    }

    function getDeploymentParams()
        public
        view
        override
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
        bytes memory resolverArgs = abi.encode(target, base);
        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: constant_price_resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }
}
