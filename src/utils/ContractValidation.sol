// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {Factory} from "../Factory.sol";
import {Errors} from "../Errors.sol";
import {CustomRevert} from "./CustomRevert.sol";

library ContractValidation {
    using CustomRevert for bytes4;

    function checkTwoCrypto(Factory factory, address twoCrypto, address canonicalTwoCryptoDeployer) internal view {
        if (factory.s_pools(twoCrypto) != canonicalTwoCryptoDeployer) Errors.Zap_BadTwoCrypto.selector.revertWith();
    }

    function checkPrincipalToken(Factory factory, address principalToken) internal view {
        if (factory.s_principalTokens(principalToken) == address(0)) Errors.Zap_BadPrincipalToken.selector.revertWith();
    }

    function hasCode(address addr) internal view returns (bool) {
        return addr.code.length > 0;
    }
}
