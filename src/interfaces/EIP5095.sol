// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

/// @notice Principal tokens (zero-coupon tokens) are redeemable for a single underlying EIP-20 token at a future timestamp.
/// https://eips.ethereum.org/EIPS/eip-5095
interface EIP5095 {
    /// @dev We think EIP-5095 `Redeem` event lacks `by` and `principal` fields.
    /// So we emit our own `Redeem` event instead of EIP-5095 `Redeem` event.
    event Redeem(address indexed owner, address indexed receiver, uint256 underlyings);

    /// @notice The address of the underlying token used by the Principal Token for accounting, and redeeming.
    function underlying() external view returns (address);

    /// @notice The unix timestamp (uint256) at or after which Principal Tokens can be redeemed for their underlying deposit.
    function maturity() external view returns (uint256 timestamp);

    /// @notice The amount of underlying that would be exchanged for the amount of PTs provided, in an ideal scenario where all the conditions are met.
    /// @notice Before maturity, the amount of underlying returned is as if the PTs would be at maturity.
    /// @notice MUST NOT be inclusive of any fees that are charged against redemptions.
    /// @notice MUST NOT show any variations depending on the caller.
    /// @notice MUST NOT reflect slippage or other on-chain conditions, when performing the actual redemption.
    /// @notice MUST NOT revert unless due to integer overflow caused by an unreasonably large input.
    /// @notice MUST round down towards 0.
    /// @notice This calculation MAY NOT reflect the “per-user” price-per-principal-token, and instead should reflect the “average-user’s” price-per-principal-token, meaning what the average user should expect to see when exchanging to and from.
    function convertToUnderlying(uint256 principal) external view returns (uint256 underlyings);

    /// @notice The amount of principal tokens that the principal token contract would request for redemption in order to provide the amount of underlying specified, in an ideal scenario where all the conditions are met.
    /// @notice MUST NOT be inclusive of any fees.
    /// @notice MUST NOT show any variations depending on the caller.
    /// @notice MUST NOT reflect slippage or other on-chain conditions, when performing the actual exchange.
    /// @notice MUST NOT revert unless due to integer overflow caused by an unreasonably large input.
    /// @notice MUST round down towards 0.
    /// @notice This calculation MAY NOT reflect the “per-user” price-per-principal-token, and instead should reflect the “average-user’s” price-per-principal-token, meaning what the average user should expect to see when redeeming.
    function convertToPrincipal(uint256 underlyings) external view returns (uint256 principal);

    /// @notice Maximum amount of principal tokens that can be redeemed from the holder balance, through a redeem call.
    /// @notice MUST return the maximum amount of principal tokens that could be transferred from holder through redeem and not cause a revert, which MUST NOT be higher than the actual maximum that would be accepted (it should underestimate if necessary).
    /// @notice MUST factor in both global and user-specific limits, like if redemption is entirely disabled (even temporarily) it MUST return 0.
    /// @notice MUST NOT revert.
    function maxRedeem(address owner) external view returns (uint256);

    /// @notice Allows an on-chain or off-chain user to simulate the effects of their redeemption at the current block, given current on-chain conditions.
    /// @notice MUST return as close to and no more than the exact amount of underliyng that would be obtained in a redeem call in the same transaction. I.e. redeem should return the same or more assets as previewRedeem if called in the same transaction.
    /// @notice MUST NOT account for redemption limits like those returned from maxRedeem and should always act as though the redemption would be accepted, regardless if the user has enough principal tokens, etc.
    /// @notice MUST be inclusive of redemption fees. Integrators should be aware of the existence of redemption fees.
    /// @notice MUST NOT revert due to principal token contract specific user/global limits. MAY revert due to other conditions that would also cause redeem to revert.
    /// Note that any unfavorable discrepancy between convertToUnderlying and previewRedeem SHOULD be considered slippage in price-per-principal-token or some other type of condition.
    function previewRedeem(uint256 principal) external view returns (uint256 underlyings);

    /// @notice At or after maturity, burns exactly principal of Principal Tokens from from and sends assets of underlying tokens to to.
    /// @notice Interfaces and other contracts MUST NOT expect fund custody to be present. While custodial redemption of Principal Tokens through the Principal Token contract is extremely useful for integrators, some protocols may find giving the Principal Token itself custody breaks their backwards compatibility.
    /// @notice MUST emit the Redeem event.
    /// @notice MUST support a redeem flow where the Principal Tokens are burned from holder directly where holder is msg.sender or msg.sender has EIP-20 approval over the principal tokens of holder. MAY support an additional flow in which the principal tokens are transferred to the Principal Token contract before the redeem execution, and are accounted for during redeem.
    /// @notice MUST revert if all of principal cannot be redeemed (due to withdrawal limit being reached, slippage, the holder not having enough Principal Tokens, etc).
    /// @notice Note that some implementations will require pre-requesting to the Principal Token before a withdrawal may be performed. Those methods should be performed separately.
    function redeem(uint256 principal, address receiver, address owner) external returns (uint256 underlyings);

    /// @notice Maximum amount of the underlying asset that can be redeemed from the holder principal token balance, through a withdraw call.
    function maxWithdraw(address owner) external view returns (uint256 underlyings);

    /// @dev Allows an on-chain or off-chain user to simulate the effects of their withdrawal at the current block, given current on-chain conditions.
    function previewWithdraw(uint256 underlyings) external view returns (uint256 principal);

    /// @notice Burns principal from holder and sends exactly assets of underlying tokens to receiver.
    /// @notice MUST emit the Redeem event.
    /// @notice MUST support a withdraw flow where the principal tokens are burned from holder directly where holder is msg.sender or msg.sender has EIP-20 approval over the principal tokens of holder. MAY support an additional flow in which the principal tokens are transferred to the principal token contract before the withdraw execution, and are accounted for during withdraw.
    /// @notice MUST revert if all of assets cannot be withdrawn (due to withdrawal limit being reached, slippage, the holder not having enough principal tokens, etc).
    /// @notice Note that some implementations will require pre-requesting to the principal token contract before a withdrawal may be performed. Those methods should be performed separately.
    function withdraw(uint256 underlyings, address receiver, address owner) external returns (uint256 principal);
}
