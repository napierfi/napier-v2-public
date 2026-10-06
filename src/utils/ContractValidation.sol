// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {Factory} from "../Factory.sol";
import {Errors} from "../Errors.sol";
import {CustomRevert} from "./CustomRevert.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TokiPoolDeployer} from "../modules/deployers/TokiPoolDeployer.sol";

library ContractValidation {
    using CustomRevert for bytes4;

    function checkTwoCrypto(Factory factory, address twoCrypto, address canonicalTwoCryptoDeployer) internal view {
        if (factory.s_pools(twoCrypto) != canonicalTwoCryptoDeployer) Errors.Zap_BadTwoCrypto.selector.revertWith();
    }

    function checkPrincipalToken(Factory factory, address principalToken) internal view {
        if (factory.s_principalTokens(principalToken) == address(0)) Errors.Zap_BadPrincipalToken.selector.revertWith();
    }

    function checkTokiPoolExists(address immutableParamsPointer) internal pure {
        if (immutableParamsPointer == address(0)) Errors.BadTokiPool.selector.revertWith();
    }

    function checkTokiPoolExists(PoolId poolId, TokiPoolDeployer deployer) internal view {
        if (deployer.hookOf(poolId) == address(0)) Errors.BadTokiPool.selector.revertWith();
    }

    function hasCode(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }
}
