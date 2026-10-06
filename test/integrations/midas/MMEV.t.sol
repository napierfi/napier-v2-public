// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {Factory} from "src/Factory.sol";

import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract MMEVForkTest is TwoCryptoIntegrationTest {
    address constant MMEV = 0x030b69280892c888670EDCDCD8B69Fd8026A0BF3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant PRICE_FEED = 0x5f09Aff8B9b1f488B7d1bbaD4D89648579e55d61;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21942620);
    }

    function setUp() public override {
        super.setUp();

        deal(MMEV, alice, 1000 * tOne);
        deal(MMEV, bob, 1000 * tOne);
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, MMEV)
            sstore(base.slot, USDC)
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
        bytes memory resolverArgs = abi.encode(target, base, PRICE_FEED);
        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: chainlink_price_resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }
}
