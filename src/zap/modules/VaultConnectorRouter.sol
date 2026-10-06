// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "../../Types.sol";
import "../../Errors.sol";
import {CustomRevert} from "../../utils/CustomRevert.sol";

import {VaultConnector} from "../../modules/connectors/VaultConnectorRegistry.sol";
import {NapierV2Immutables} from "./NapierV2Immutables.sol";
import {LibApproval} from "../../utils/LibApproval.sol";
import {V4Permit2Payments} from "./V4Permit2Payments.sol";

/// @dev A contract inheriting from this contract MUST implement receive() function to allow receiving ETH from vault connectors
abstract contract VaultConnectorRouter is NapierV2Immutables, V4Permit2Payments, LibApproval {
    using CustomRevert for *;

    function _getConnectorOrDefault(address target, address asset) internal returns (VaultConnector) {
        return _i_vaultConnectorRegistry.getConnector(target, asset);
    }

    /// @notice Deposit `amount` of `token` from `payer` and mint `shares` of underlying token to `receiver`
    function _connectorDeposit(address target, address asset, Token token, uint256 amountIn, address receiver)
        internal
        returns (uint256 shares)
    {
        VaultConnector vaultConnector = _getConnectorOrDefault(target, asset);

        amountIn = payIfNeeded(Token.unwrap(token), amountIn);

        uint256 value;
        if (token.isNative()) {
            value = amountIn;
        } else {
            approveIfNeeded(Token.unwrap(token), address(vaultConnector));
        }
        shares = vaultConnector.deposit{value: value}(token, amountIn, receiver);
    }

    function _connectorRedeem(address target, address asset, Token tokenOut, uint256 shares, address receiver)
        internal
        returns (uint256 amountOut)
    {
        VaultConnector vaultConnector = _getConnectorOrDefault(target, asset);

        shares = payIfNeeded(target, shares);

        approveIfNeeded(target, address(vaultConnector));
        amountOut = vaultConnector.redeem(tokenOut, shares, receiver);
    }
}
