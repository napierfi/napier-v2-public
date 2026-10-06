// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {LibClone} from "solady/src/utils/LibClone.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {VerificationStatus} from "../Types.sol";
import {BaseModule} from "./BaseModule.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";

/// @notice VerifierModule is used to restrict access to certain functions based on account and deposit cap.
/// @dev Integrators can extend this module to implement custom verification logic.
abstract contract VerifierModule is BaseModule {
    bytes4 constant SUPPLY_SELECTOR = 0x674032b8;
    bytes4 constant SUPPLY_WITH_CALLBACK_SELECTOR = 0x5f04dfe2;
    bytes4 constant ISSUE_SELECTOR = 0xb696a6ad;
    bytes4 constant ISSUE_WITH_CALLBACK_SELECTOR = 0x6d4b055c;

    /// @dev MUST NOT revert.
    /// @dev Key points: to distinguish between verification failure and unexpected error, the function
    /// must return verification status to indicate whether the transaction is allowed or not.
    /// @dev The function MUST return VerificationStatus.Success if the transaction is allowed.
    function verify(bytes4 sig, address caller, uint256 shares, uint256 principal, address receiver)
        external
        view
        virtual
        returns (VerificationStatus code)
    {
        sig;
        principal;
        caller; // silence the warning

        // If the balance reaches the cap, revert
        if (
            (
                sig == SUPPLY_SELECTOR || sig == SUPPLY_WITH_CALLBACK_SELECTOR || sig == ISSUE_SELECTOR
                    || sig == ISSUE_WITH_CALLBACK_SELECTOR
            ) && shares > maxSupply(receiver)
        ) {
            return VerificationStatus.SupplyMoreThanMax;
        }
        return VerificationStatus.Success;
    }

    /// @notice Returns the global maximum amount of shares that can PT can have.
    /// @notice The cap includes the deposits from users, fees, unclaimed yield, etc.
    /// MUST return 2 ** 256 - 1 if there is no limit on the maximum amount that may be deposited.
    /// MUST NOT revert.
    function depositCap() public view virtual returns (uint256 maxShares) {
        maxShares = type(uint256).max;
    }

    /// @notice Similar to `ERC4626.maxDeposit`, returns the maximum amount of the underlying token that can be deposited for `to`.
    /// Note: It doesn't account for pause state or expiry.
    /// MUST return a limited value if receiver is subject to some deposit limit.
    /// MUST return 2 ** 256 - 1 if there is no limit on the maximum amount that may be deposited.
    /// MUST NOT revert.
    function maxSupply(address to) public view virtual returns (uint256 maxShares) {
        to; // silence the warning

        uint256 cap = depositCap();
        if (cap == type(uint256).max) return type(uint256).max;

        address pt = i_principalToken();
        uint256 balance = SafeTransferLib.balanceOf(PrincipalToken(pt).underlying(), pt);
        maxShares = FixedPointMathLib.zeroFloorSub(cap, balance); // max(0, cap - balance)
    }
}

/// @notice Simple implementation of VerifierModule with deposit cap defined by permissioned roles.
contract DepositCapVerifierModule is VerifierModule {
    bytes32 public constant override VERSION = "2.0.0";

    /// @notice Global deposit cap in unit of the underlying token.
    uint256 internal s_depositCap;

    /// @notice Emitted when the module's deposit cap state changes.
    /// @dev During `initialize()` on a newly deployed clone, `oldDepositCap` is always `0`
    /// because clone storage starts empty on module replacement.
    event DepositCapUpdated(uint256 oldDepositCap, uint256 newDepositCap);

    /// @dev Upgrade behavior note:
    /// - `Factory.updateModules()` deploys a fresh clone and calls `initialize()`.
    /// - This module reads cap only from clone immutable args.
    /// - It does NOT read prior module storage or emit a cap-change continuity event during upgrades.
    /// Curators should pass the intended cap in `immutableData` when replacing this module.
    function initialize() external override initializer {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(address(this)), (address, bytes));
        uint256 cap = abi.decode(args, (uint256));
        s_depositCap = cap;

        emit DepositCapUpdated(0, cap);
    }

    function setDepositCap(uint256 cap) external restricted {
        uint256 oldDepositCap = s_depositCap;
        s_depositCap = cap;
        emit DepositCapUpdated(oldDepositCap, cap);
    }

    function depositCap() public view override returns (uint256 maxShares) {
        maxShares = s_depositCap;
    }
}
