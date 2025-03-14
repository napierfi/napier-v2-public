// SPDX-License-Identifier: GPL-3.0
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

    function initialize() external override initializer {
        (, bytes memory args) = abi.decode(LibClone.argsOnClone(address(this)), (address, bytes));
        s_depositCap = abi.decode(args, (uint256));
    }

    function setDepositCap(uint256 cap) external restricted {
        s_depositCap = cap;
    }

    function depositCap() public view override returns (uint256 maxShares) {
        maxShares = s_depositCap;
    }
}
