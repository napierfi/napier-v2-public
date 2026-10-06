// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {Factory} from "src/Factory.sol";

import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract FBTCForkTest is TwoCryptoIntegrationTest {
    address constant FBTC = 0xC96dE26018A54D51c097160568752c4E3BD6C364;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant PRICE_FEED = 0xe5346a4Fd329768A99455d969724768a00CA63FB;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21942620);
    }

    function setUp() public override {
        super.setUp();

        deal(FBTC, alice, 1000 * tOne);
        deal(FBTC, bob, 1000 * tOne);
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, FBTC)
            sstore(base.slot, WBTC)
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
