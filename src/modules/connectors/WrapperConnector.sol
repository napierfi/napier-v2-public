// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";

import "../../Types.sol";
import "../../Errors.sol";
import "../../Constants.sol" as Constants;

import {IWrapper} from "../../wrapper/IWrapper.sol";
import {LibApproval} from "../../utils/LibApproval.sol";
import {VaultConnector} from "./VaultConnector.sol";

/// @dev This contract is meant to be deployed via clone with the following immutable args:
/// abi.encodePacked(address wrapper, address weth)
/// - address wrapper: the address of the Napier ERC4626 Wrapper
/// - address weth: the address of the WETH
/// @dev Auto native token support:
/// - Only if wrapper supports WETH as token{In,out}, automatically native token is supported as token{In,out}
contract WrapperConnector is VaultConnector, LibApproval {
    using DynamicArrayLib for DynamicArrayLib.DynamicArray;

    uint256 constant CWIA_ARGS_OFFSET = 0x00;

    receive() external payable {}

    function i_wrapper() public view returns (IWrapper) {
        bytes memory args = LibClone.argsOnClone(address(this));
        return IWrapper(address(uint160(uint256(LibClone.argLoad(args, CWIA_ARGS_OFFSET)))));
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
        IWrapper wrapper = i_wrapper();
        // Check if we need to fallback to WETH
        DynamicArrayLib.DynamicArray memory tokenList = toDynamicArray(wrapper.getTokenInList());
        if (token.isNative() && !tokenList.contains(Constants.NATIVE_ETH)) {
            token = Token.wrap(_getWETHAddress());
        }
        return wrapper.previewDeposit(token, tokens);
    }

    function previewRedeem(Token token, uint256 shares) public view override returns (uint256 tokens) {
        IWrapper wrapper = i_wrapper();
        // Check if we need to fallback to WETH
        DynamicArrayLib.DynamicArray memory tokenList = toDynamicArray(wrapper.getTokenOutList());
        if (token.isNative() && !tokenList.contains(Constants.NATIVE_ETH)) {
            token = Token.wrap(_getWETHAddress());
        }
        return wrapper.previewRedeem(token, shares);
    }

    function deposit(Token token, uint256 tokens, address receiver) public payable override returns (uint256 shares) {
        IWrapper wrapper = i_wrapper();

        if (token.isNative()) {
            // Handle native ETH deposit
            if (msg.value != tokens) revert Errors.WrapperConnector_InvalidETHAmount();

            // Check if we need to fallback to WETH
            DynamicArrayLib.DynamicArray memory tokenList = toDynamicArray(wrapper.getTokenInList());
            if (!tokenList.contains(Constants.NATIVE_ETH)) {
                // Wrapper doesn't support native ETH directly, try WETH
                address WETH = _getWETHAddress();
                token = Token.wrap(WETH);
                _wrapETH(msg.value);
                approveIfNeeded(WETH, address(wrapper));
            }
        } else {
            // Handle ERC20 token deposit
            if (msg.value > 0) revert Errors.WrapperConnector_UnexpectedETH();

            address tokenAddr = token.unwrap();
            SafeTransferLib.safeTransferFrom(tokenAddr, msg.sender, address(this), tokens);
            approveIfNeeded(tokenAddr, address(wrapper));
        }

        shares = wrapper.deposit{value: token.isNative() ? msg.value : 0}(token, tokens, receiver);
    }

    function redeem(Token token, uint256 shares, address receiver) public override returns (uint256) {
        IWrapper wrapper = i_wrapper();
        address WETH = _getWETHAddress();

        SafeTransferLib.safeTransferFrom(address(wrapper), msg.sender, address(this), shares);

        // Check if we need to handle native ETH redemption via WETH
        DynamicArrayLib.DynamicArray memory tokenList = toDynamicArray(wrapper.getTokenOutList());
        if (token.isNative() && !tokenList.contains(Constants.NATIVE_ETH)) {
            // Redeem for WETH and unwrap to native ETH
            uint256 wethAmount = wrapper.redeem(Token.wrap(WETH), shares, address(this));
            _unwrapWETH(receiver, wethAmount);
            return wethAmount;
        }

        // Standard redemption path
        return wrapper.redeem(token, shares, receiver);
    }

    function getTokenInList() public view override returns (Token[] memory) {
        Token[] memory tokens = i_wrapper().getTokenInList();
        address WETH = _getWETHAddress();

        DynamicArrayLib.DynamicArray memory tokenList = toDynamicArray(tokens);

        // If WETH is supported but native ETH isn't, add native ETH support
        if (tokenList.contains(WETH) && !tokenList.contains(Constants.NATIVE_ETH)) {
            return asTokenArray(tokenList.p(Constants.NATIVE_ETH));
        }

        return tokens;
    }

    function getTokenOutList() public view override returns (Token[] memory) {
        Token[] memory tokens = i_wrapper().getTokenOutList();
        address WETH = _getWETHAddress();

        DynamicArrayLib.DynamicArray memory tokenList = toDynamicArray(tokens);

        // If WETH is supported but native ETH isn't, add native ETH support
        if (tokenList.contains(WETH) && !tokenList.contains(Constants.NATIVE_ETH)) {
            return asTokenArray(tokenList.p(Constants.NATIVE_ETH));
        }

        return tokens;
    }

    function _getWETHAddress() internal view override returns (address weth) {
        bytes memory args = LibClone.argsOnClone(address(this));
        weth = address(uint160(uint256(LibClone.argLoad(args, CWIA_ARGS_OFFSET + 0x20))));
    }
}

function toDynamicArray(Token[] memory tokens) pure returns (DynamicArrayLib.DynamicArray memory result) {
    result = DynamicArrayLib.wrap(asAddressArray(tokens));
}

function asTokenArray(DynamicArrayLib.DynamicArray memory dynamicArray) pure returns (Token[] memory result) {
    address[] memory addresses = DynamicArrayLib.asAddressArray(dynamicArray);
    assembly {
        result := addresses
    }
}
