// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

// Interfaces
import {Factory} from "../Factory.sol";
import {VaultConnectorRegistry} from "../modules/connectors/VaultConnectorRegistry.sol";

// Internal
import "../Types.sol";
import "../Errors.sol";
import "../Constants.sol" as Constants;
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {AccessManaged, AccessManager} from "../modules/AccessManager.sol";
import {BaseQuoter} from "./BaseQuoter.sol";

/// @dev ERC1967I Immutable args: abi.encode(factory, wrappedNativeToken, vaultConnectorRegistry)
contract PrincipalTokenQuoter is AccessManaged, UUPSUpgradeable, Initializable, BaseQuoter {
    constructor() {
        _disableInitializers();
    }

    function _authorizeUpgrade(address newImplementation) internal override restricted {}

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           View                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function i_accessManager() public view override returns (AccessManager) {
        return factory().i_accessManager();
    }

    function factory() public view override returns (Factory i_factory) {
        (i_factory,,) = _parseImmutableArgs();
    }

    function vaultConnectorRegistry() public view override returns (VaultConnectorRegistry i_vaultConnectorRegistry) {
        (,, i_vaultConnectorRegistry) = _parseImmutableArgs();
    }

    function WETH() public view override returns (address i_WETH) {
        (, i_WETH,) = _parseImmutableArgs();
    }

    function getTokenInList(PrincipalToken pt) public view returns (Token[] memory) {
        return _getTokenInList(pt);
    }

    function getTokenOutList(PrincipalToken pt) public view returns (Token[] memory) {
        return _getTokenOutList(pt);
    }

    function _parseImmutableArgs()
        internal
        view
        returns (Factory i_factory, address i_WETH, VaultConnectorRegistry i_vaultConnectorRegistry)
    {
        (i_factory, i_WETH, i_vaultConnectorRegistry) =
            abi.decode(LibClone.argsOnERC1967I(address(this)), (Factory, address, VaultConnectorRegistry));
    }
}
