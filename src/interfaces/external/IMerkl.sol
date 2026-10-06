// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

/// @notice Merkl Distributor by Angle Protocol
/// @dev https://github.com/AngleProtocol/merkl-contracts/blob/f6f9a6385977546ebe9d753667a7393066f5a173/contracts/Distributor.sol
interface IMerkl {
    struct Claim {
        uint208 amount;
        uint48 timestamp;
        bytes32 merkleRoot;
    }

    function claimed(address account, address token) external view returns (Claim memory);

    /// @notice Claim rewards from Angle Merkl distributor
    /// @dev If caller is not users, the caller must be approved by the user. Rewards are sent to the eligible user.
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;

    function toggleOperator(address user, address operator) external;

    function operators(address user, address operator) external view returns (uint256);
}
