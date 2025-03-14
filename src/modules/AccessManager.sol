// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {OwnableRoles} from "solady/src/auth/OwnableRoles.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {Multicallable} from "solady/src/utils/Multicallable.sol";

import "../Constants.sol" as Constants;
import {Errors} from "../Errors.sol";

/// @notice Access Manager module for managing single owner and multiple roles for multiple contracts and functions.
/// @dev Each PrincipalToken instance will have its own AccessManager instance to manage access control.
/// @dev AccessManager is a minimal proxy implementation to reduce deployment costs.
/// @dev Note: AccessManager must be initialized after deployment to set initial owner.
contract AccessManager is OwnableRoles, Initializable, Multicallable {
    /// @notice Mapping of target contracts to their function selectors and roles that are allowed to call the function
    mapping(address target => mapping(bytes4 selector => uint256 roles)) private s_targets;

    /// @notice Emitted when roles are granted for a target function
    /// @param target The address of the target contract
    /// @param selector The function selector
    /// @param roles The roles being granted
    event TargetFunctionRolesGranted(address indexed target, bytes4 indexed selector, uint256 indexed roles);

    /// @notice Emitted when roles are revoked for a target function
    /// @param target The address of the target contract
    /// @param selector The function selector
    /// @param roles The roles being revoked
    event TargetFunctionRolesRevoked(address indexed target, bytes4 indexed selector, uint256 indexed roles);

    /// @notice Initializes the contract by setting the initial owner
    /// @param curator The address of the initial owner
    function initializeOwner(address curator) external initializer {
        _initializeOwner(curator);
    }

    /// @dev Allows the owner to grant `user` `roles`.
    /// If the `user` already has a role, then it will be an no-op for the role.
    function grantRoles(address user, uint256 roles) public payable override onlyOwnerOrCanCall {
        _grantRoles(user, roles);
    }

    /// @dev Allows the owner to remove `user` `roles`.
    /// If the `user` does not have a role, then it will be an no-op for the role.
    function revokeRoles(address user, uint256 roles) public payable override onlyOwnerOrCanCall {
        _removeRoles(user, roles);
    }

    /// @notice Grants roles for multiple function selectors on a target contract
    /// @param target The address of the target contract
    /// @param selectors An array of function selectors
    /// @param roles The roles to grant
    function grantTargetFunctionRoles(address target, bytes4[] calldata selectors, uint256 roles)
        public
        payable
        onlyOwnerOrCanCall
    {
        uint256 length = selectors.length;
        for (uint256 i = 0; i != length;) {
            _grantTargetFunctionRoles(target, selectors[i], roles);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Revokes roles for multiple function selectors on a target contract
    /// @param target The address of the target contract
    /// @param selectors An array of function selectors
    /// @param roles The roles to revoke
    function revokeTargetFunctionRoles(address target, bytes4[] calldata selectors, uint256 roles)
        public
        payable
        onlyOwnerOrCanCall
    {
        uint256 length = selectors.length;
        for (uint256 i = 0; i != length;) {
            _revokeTargetFunctionRoles(target, selectors[i], roles);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal function to grant a role for a specific function on a target contract
    /// @param target The address of the target contract
    /// @param selector The function selector
    /// @param roles The role to grant
    function _grantTargetFunctionRoles(address target, bytes4 selector, uint256 roles) internal {
        s_targets[target][selector] = s_targets[target][selector] | roles;
        emit TargetFunctionRolesGranted(target, selector, roles);
    }

    /// @notice Internal function to revoke a role for a specific function on a target contract
    /// @param target The address of the target contract
    /// @param selector The function selector
    /// @param roles The roles to revoke
    function _revokeTargetFunctionRoles(address target, bytes4 selector, uint256 roles) internal {
        s_targets[target][selector] = s_targets[target][selector] & ~roles;
        emit TargetFunctionRolesRevoked(target, selector, roles);
    }

    /// @notice Checks if a caller has permission to call a specific function on a target contract
    /// @param caller The address of the caller
    /// @param target The address of the target contract
    /// @param selector The function selector
    /// @return bool True if the caller has permission, false otherwise
    function canCall(address caller, address target, bytes4 selector) public view returns (bool) {
        return hasAnyRole(caller, s_targets[target][selector]);
    }

    /// @dev Marks a function as only callable by the owner or by the caller with any role allowed to call the function
    modifier onlyOwnerOrCanCall() {
        _checkOwnerOrRoles({roles: s_targets[address(this)][bytes4(msg.data[0:4])]});
        _;
    }
}

abstract contract AccessManaged {
    function i_accessManager() public view virtual returns (AccessManager);

    modifier restricted() {
        _checkRestricted(i_accessManager());
        _;
    }

    modifier restrictedBy(AccessManager accessManager) {
        _checkRestricted(accessManager);
        _;
    }

    function _checkRestricted(AccessManager accessManager) internal view {
        if (!accessManager.canCall(msg.sender, address(this), bytes4(msg.data[0:4]))) {
            revert Errors.AccessManaged_Restricted();
        }
    }
}
