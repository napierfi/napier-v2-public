// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {Factory} from "../../Factory.sol";
import {VaultConnectorRegistry} from "../../modules/connectors/VaultConnectorRegistry.sol";
import {AggregationRouter} from "../../modules/aggregator/AggregationRouter.sol";
import {WrapperFactory} from "../../wrapper/WrapperFactory.sol";
import {TokiPoolDeployer} from "../../modules/deployers/TokiPoolDeployer.sol";
import {TokiSwapBinSearch} from "../../utils/TokiSwapBinSearch.sol";

abstract contract NapierV2Immutables {
    Factory immutable _i_factory;
    VaultConnectorRegistry immutable _i_vaultConnectorRegistry;
    AggregationRouter immutable _i_aggregationRouter;
    WrapperFactory immutable _i_wrapperFactory;
    TokiPoolDeployer immutable _i_tokiPoolDeployer;
    TokiSwapBinSearch immutable _i_tokiSwapBinSearch;

    struct NapierV2Parameters {
        Factory factory;
        VaultConnectorRegistry vaultConnectorRegistry;
        AggregationRouter aggregationRouter;
        WrapperFactory wrapperFactory;
        TokiPoolDeployer tokiPoolDeployer;
        TokiSwapBinSearch tokiSwapBinSearch;
    }

    constructor(NapierV2Parameters memory params) {
        _i_factory = params.factory;

        _i_vaultConnectorRegistry = params.vaultConnectorRegistry;
        _i_aggregationRouter = params.aggregationRouter;
        _i_wrapperFactory = params.wrapperFactory;
        _i_tokiPoolDeployer = params.tokiPoolDeployer;
        _i_tokiSwapBinSearch = params.tokiSwapBinSearch;
    }
}
