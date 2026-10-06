// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {TwoCryptoIntegrationTest} from "../TwoCryptoIntegration.t.sol";

import {MorphoRewardProxy} from "src/modules/reward-proxies/MorphoRewardProxy.sol";
import {Factory} from "src/Factory.sol";
import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

contract MEVCBBTCForkTest is TwoCryptoIntegrationTest {
    address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    address constant MORPHO_VAULT_MEVCBBTC = 0x98cF0B67Da0F16E1F8f1a1D23ad8Dc64c0c70E0b;
    address constant MERKLE_DISTRIBUTOR = 0x678dDC1d07eaa166521325394cDEb1E4c086DF43;
    /// @notice Morpho has legacy and wrapped token.
    address constant LEGACY_MORPHO = 0x9994E35Db50125E0DF82e4c2dde62496CE330999;
    address constant WRAPPED_MORPHO = 0x58D97B57BB95320F9a05dC918Aef65434969c2B2; // Deployed: November 10, 2024

    address morphoRewardProxy_logic;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21942620);
    }

    function setUp() public override {
        morphoRewardProxy_logic = address(new MorphoRewardProxy());
        super.setUp();
        deal(MORPHO_VAULT_MEVCBBTC, alice, 1_000 * tOne);
        deal(MORPHO_VAULT_MEVCBBTC, bob, 1_000 * tOne);

        vm.label(MERKLE_DISTRIBUTOR, "distributor");
        vm.label(WRAPPED_MORPHO, "wrapped morpho");
    }

    function _deployTokens() internal override {
        assembly {
            sstore(target.slot, MORPHO_VAULT_MEVCBBTC)
            sstore(base.slot, CBBTC)
        }
    }

    function _setUpModules() internal override {
        super._setUpModules();
        vm.startPrank(admin);
        factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, morphoRewardProxy_logic, true);
        vm.stopPrank();
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        FeePcts feePcts = FeePctsLib.pack(Constants.DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183);

        bytes memory poolArgs = abi.encode(twocryptoParams);
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = WRAPPED_MORPHO;
        params = new Factory.ModuleParam[](2);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        params[1] = Factory.ModuleParam({
            moduleType: REWARD_PROXY_MODULE_INDEX,
            implementation: morphoRewardProxy_logic,
            immutableData: abi.encode(rewardTokens, MERKLE_DISTRIBUTOR)
        });
        bytes memory resolverArgs = abi.encode(address(target)); // Change based on the resolver blueprint
        suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            resolverBlueprint: erc4626_resolver_blueprint,
            ptBlueprint: pt_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }
}
