// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "../Types.sol";
import {VerifierModule} from "../modules/VerifierModule.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";

library VerifierLensLib {
    function getDepositCap(PrincipalToken pt) internal view returns (uint256 cap) {
        // Verifier is optional.
        try pt.i_factory().moduleFor(address(pt), VERIFIER_MODULE_INDEX) returns (address verifier) {
            cap = VerifierModule(verifier).depositCap();
        } catch {
            // If verifier is not set, no limited cap.
            cap = type(uint256).max;
        }
    }
}
