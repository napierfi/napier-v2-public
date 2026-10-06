// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PrincipalToken} from "../../tokens/PrincipalToken.sol";
import {ContractValidation} from "../../utils/ContractValidation.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";

import "../../Types.sol";
import "../../Errors.sol";
import {NapierV2Immutables} from "./NapierV2Immutables.sol";
import {LibApproval} from "../../utils/LibApproval.sol";
import {V4Permit2Payments} from "./V4Permit2Payments.sol";

abstract contract PrincipalTokenRouter is NapierV2Immutables, V4Permit2Payments, LibApproval {
    using CustomRevert for *;

    function _principalTokenSupply(PrincipalToken principalToken, uint256 shares, address receiver) internal {
        ContractValidation.checkPrincipalToken(_i_factory, address(principalToken));

        address underlying = principalToken.underlying();
        shares = payIfNeeded(underlying, shares);

        approveIfNeeded(underlying, address(principalToken));
        principalToken.supply(shares, receiver);
    }

    function _principalTokenRedeem(PrincipalToken principalToken, uint256 principals, address receiver) internal {
        ContractValidation.checkPrincipalToken(_i_factory, address(principalToken));

        principals = payIfNeeded(address(principalToken), principals);
        principalToken.redeem(principals, receiver, address(this));
    }

    /// @dev Edge case: consider using `SWEEP` commands at the top of the sequence where this command receives PTs and YTs on behalf of the user from previous commands.
    ///      It's possible for an external actor to grief the user's transaction by sending at least 1 wei of PT to the router contract ahead of the user's transaction.
    function _principalTokenCombine(PrincipalToken principalToken, uint256 principals, address receiver) internal {
        ContractValidation.checkPrincipalToken(_i_factory, address(principalToken));

        address yt = address(principalToken.i_yt());
        uint256 actualPrincipals = payIfNeeded(address(principalToken), principals);
        uint256 actualYts = payIfNeeded(yt, principals);

        if (actualYts < actualPrincipals) Errors.Zap_InsufficientYieldTokenBalance.selector.revertWith();
        principalToken.combine(actualPrincipals, receiver);
    }

    struct PermitCollectInput {
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /// @notice Collect interest and rewards from a principal token
    /// @param permit Permit input - If the `deadline` in input is zero, we skip the permit call
    function _principalTokenCollect(PrincipalToken principalToken, address receiver, PermitCollectInput calldata permit)
        internal
    {
        ContractValidation.checkPrincipalToken(_i_factory, address(principalToken));

        address sender = msgSender();

        if (permit.deadline > 0) {
            // Permit signature might be consumed by fruntrun.
            // https://www.trust-security.xyz/post/permission-denied
            try principalToken.permitCollector(sender, address(this), permit.deadline, permit.v, permit.r, permit.s) {}
            catch {
                // Permit potentially got fruntrun. If the Zap is not approved, collect() will revert.
            }
        }

        principalToken.collect({receiver: receiver, owner: sender});
    }
}
