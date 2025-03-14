// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import "../../Types.sol";
import "../../Errors.sol";

import {StandardERC4626Wrapper} from "../../wrapper/StandardERC4626Wrapper.sol";
import {LibApproval} from "../../utils/LibApproval.sol";
import {VaultConnector} from "./VaultConnector.sol";

/// @dev This contract is meant to be deployed via clone with the following immutable args:
/// abi.encodePacked(address wrapper, address weth)
/// - address wrapper: the address of the Napier ERC4626 Wrapper
/// - address weth: the address of the WETH
contract ERC4626WrapperConnector is VaultConnector, LibApproval {
    uint256 constant CWIA_ARGS_OFFSET = 0x00;

    function i_wrapper() public view returns (StandardERC4626Wrapper) {
        bytes memory args = LibClone.argsOnClone(address(this));
        return StandardERC4626Wrapper(address(uint160(uint256(LibClone.argLoad(args, CWIA_ARGS_OFFSET)))));
    }

    function asset() public view override returns (address) {
        return i_wrapper().asset();
    }

    /// @notice The address of the wrapper vault.
    function target() public view override returns (address) {
        return address(i_wrapper());
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return i_wrapper().convertToAssets(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return i_wrapper().convertToShares(assets);
    }

    function previewDeposit(Token token, uint256 tokens) public view override returns (uint256 shares) {
        return i_wrapper().previewDeposit(token, tokens);
    }

    function previewRedeem(Token token, uint256 shares) public view override returns (uint256 tokens) {
        return i_wrapper().previewRedeem(token, shares);
    }

    function deposit(Token token, uint256 tokens, address receiver) public payable override returns (uint256 shares) {
        if (token.isNative()) {
            if (msg.value != tokens) revert Errors.WrapperConnector_InvalidETHAmount();
        } else {
            if (msg.value > 0) revert Errors.WrapperConnector_UnexpectedETH();
            SafeTransferLib.safeTransferFrom(token.unwrap(), msg.sender, address(this), tokens);
            approveIfNeeded(token.unwrap(), address(i_wrapper()));
        }
        shares = i_wrapper().deposit{value: msg.value}(token, tokens, receiver);
    }

    function redeem(Token token, uint256 shares, address receiver) public override returns (uint256 tokens) {
        SafeTransferLib.safeTransferFrom(address(i_wrapper()), msg.sender, address(this), shares);
        tokens = i_wrapper().redeem(token, shares, receiver);
    }

    function getTokenInList() public view override returns (Token[] memory) {
        return i_wrapper().getTokenInList();
    }

    function getTokenOutList() public view override returns (Token[] memory) {
        return i_wrapper().getTokenOutList();
    }

    function _getWETHAddress() internal view override returns (address weth) {
        bytes memory args = LibClone.argsOnClone(address(this));
        weth = address(uint160(uint256(LibClone.argLoad(args, CWIA_ARGS_OFFSET + 0x20))));
    }
}
