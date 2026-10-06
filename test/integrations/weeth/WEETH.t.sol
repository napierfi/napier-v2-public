// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {Factory} from "src/Factory.sol";

import {FeePctsLib} from "src/utils/FeePctsLib.sol";
import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract WEETHForkTest is TwoCryptoIntegrationTest {
    address constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant PRICE_FEED = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21942620);
    }

    function setUp() public override {
        super.setUp();

        deal(WEETH, alice, 1000 * tOne);
        deal(WEETH, bob, 1000 * tOne);
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, WEETH)
            sstore(base.slot, WETH)
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
