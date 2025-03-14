// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

import {Factory} from "../Factory.sol";
import {AccessManager, AccessManaged} from "./AccessManager.sol";
import {Errors} from "../Errors.sol";

/// @dev Minimal proxy with CWIA implementation for modules. (LibClone.clone(implementation, args))
/// args = abi.encode(principalToken, data) where data is module specific bytes-type data
abstract contract BaseModule is AccessManaged, Initializable {
    uint256 constant CWIA_ARG_OFFSET = 0x00;

    function VERSION() external pure virtual returns (bytes32);

    function i_factory() public view returns (Factory) {
        (bool s, bytes memory ret) = i_principalToken().staticcall(abi.encodeWithSignature("i_factory()"));
        if (!s) revert Errors.Module_CallFailed();
        return Factory(abi.decode(ret, (address)));
    }

    function i_accessManager() public view override returns (AccessManager) {
        (bool s, bytes memory ret) = i_principalToken().staticcall(abi.encodeWithSignature("i_accessManager()"));
        if (!s) revert Errors.Module_CallFailed();
        return AccessManager(abi.decode(ret, (address)));
    }

    function i_principalToken() public view returns (address) {
        bytes memory arg = LibClone.argsOnClone(address(this), CWIA_ARG_OFFSET, CWIA_ARG_OFFSET + 0x20);
        return abi.decode(arg, (address));
    }

    /// @dev This function SHOULD be overridden by inheriting contracts and initializers should be added.
    function initialize() external virtual {
        // Do nothing by default
    }
}
