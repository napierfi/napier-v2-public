// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {MockERC4626Fees} from "./MockERC4626Fees.sol";
import {ERC20} from "solady/src/tokens/ERC4626.sol";

/// @dev Vault that lies about what it moved in the ERC-4626 return value, or burns more shares than requested.
contract MockMisreportingERC4626 is MockERC4626Fees {
    bool public s_underreportBurn;
    bool public s_overreportMint;
    bool public s_overburnRedeem;

    constructor(ERC20 asset_, bool useVirtualShares, address feeRecipient)
        MockERC4626Fees(asset_, useVirtualShares, 0, 0, feeRecipient)
    {}

    function setUnderreportBurn(bool enabled) external {
        s_underreportBurn = enabled;
    }

    function setOverreportMint(bool enabled) external {
        s_overreportMint = enabled;
    }

    function setOverburnRedeem(bool enabled) external {
        s_overburnRedeem = enabled;
    }

    function deposit(uint256 assets, address to) public override returns (uint256 shares) {
        shares = super.deposit(assets, to);
        if (s_overreportMint) shares *= 2;
    }

    function withdraw(uint256 assets, address to, address owner) public override returns (uint256 shares) {
        shares = super.withdraw(assets, to, owner);
        if (s_underreportBurn) shares /= 2;
    }

    function redeem(uint256 shares, address to, address owner) public override returns (uint256 assets) {
        assets = super.redeem(shares, to, owner);
        if (s_overburnRedeem) _burn(owner, 1);
    }
}
