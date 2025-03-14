// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken} from "./PrincipalToken.sol";
import {TokenNameLib} from "../utils/TokenNameLib.sol";
import {Errors} from "../Errors.sol";

contract YieldToken is ERC20 {
    PrincipalToken public immutable i_principalToken;

    constructor(address _pt) {
        i_principalToken = PrincipalToken(_pt);
    }

    function name() public view override returns (string memory) {
        address underlying = _underlying();
        uint256 expiry = _maturity();
        return TokenNameLib.yieldTokenName(underlying, expiry);
    }

    function symbol() public view override returns (string memory) {
        address underlying = _underlying();
        uint256 expiry = _maturity();
        return TokenNameLib.yieldTokenSymbol(underlying, expiry);
    }

    function decimals() public view override returns (uint8) {
        // Same as underlying token decimals
        return i_principalToken.decimals();
    }

    /// @dev No need to call back to PrincipalToken for updating accrued interest. PrincipalToken already does it at this point.
    function mint(address to, uint256 amount) external {
        if (msg.sender != address(i_principalToken)) revert Errors.YieldToken_OnlyPrincipalToken();
        _mint(to, amount);
    }

    /// @dev No need to call back to PrincipalToken for updating accrued interest. PrincipalToken already does it at this point.
    function burn(address from, uint256 amount) public {
        if (msg.sender != address(i_principalToken)) revert Errors.YieldToken_OnlyPrincipalToken();
        _burn(from, amount);
    }

    /// @dev YT holders accrue interest since the last update of `from` and `to` balances.
    /// Since the last update of `from` and `to` balances, the interest may be accrued by `from` and `to`.
    /// So, before updating the balances, we need to record the interest by calling `onYtTransfer`.
    function transfer(address to, uint256 amount) public override returns (bool) {
        i_principalToken.onYtTransfer(msg.sender, to, balanceOf(msg.sender), balanceOf(to));
        return super.transfer(to, amount);
    }

    /// @dev See {YieldToken-transfer}. The same logic is applied here.
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        i_principalToken.onYtTransfer(from, to, balanceOf(from), balanceOf(to));
        return super.transferFrom(from, to, amount);
    }

    function _underlying() internal view returns (address) {
        return i_principalToken.underlying();
    }

    function _maturity() internal view returns (uint256) {
        return i_principalToken.maturity();
    }
}
