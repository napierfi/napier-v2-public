// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import "../../Constants.sol" as Constants;
import {Token} from "../../Types.sol";
import {Errors} from "../../Errors.sol";

import {VaultConnector} from "./VaultConnector.sol";

contract ERC4626Connector is VaultConnector {
    ERC20 private immutable _i_asset;
    ERC4626 private immutable _i_target;
    address private immutable _i_WETH;
    bool private immutable _i_isNativeTokenSupported;

    modifier checkAsset(Token token) {
        bool isValidToken = token.unwrap() == asset() || (_i_isNativeTokenSupported && token.isNative());
        if (!isValidToken) revert Errors.ERC4626Connector_InvalidToken();
        _;
    }

    receive() external payable {}

    constructor(address _target, address _WETH) {
        _i_target = ERC4626(_target);
        _i_asset = ERC20(_i_target.asset());
        SafeTransferLib.safeApprove(address(_i_asset), address(_i_target), type(uint256).max);

        _i_WETH = _WETH;
        _i_isNativeTokenSupported = _i_asset == ERC20(_getWETHAddress());
    }

    function asset() public view override returns (address) {
        return address(_i_asset);
    }

    function target() public view override returns (address) {
        return address(_i_target);
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        return _i_target.convertToAssets(shares);
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        return _i_target.convertToShares(assets);
    }

    function previewDeposit(Token token, uint256 assets)
        public
        view
        override
        checkAsset(token)
        returns (uint256 shares)
    {
        return _i_target.previewDeposit(assets);
    }

    function previewRedeem(Token token, uint256 shares)
        public
        view
        override
        checkAsset(token)
        returns (uint256 assets)
    {
        return _i_target.previewRedeem(shares);
    }

    function deposit(Token token, uint256 amount, address receiver)
        public
        payable
        override
        checkAsset(token)
        returns (uint256 shares)
    {
        if (token.isNative()) {
            if (msg.value != amount) {
                revert Errors.ERC4626Connector_InvalidETHAmount();
            }
            _wrapETH(amount);
        } else if (msg.value > 0) {
            revert Errors.ERC4626Connector_UnexpectedETH();
        } else {
            SafeTransferLib.safeTransferFrom(token.unwrap(), msg.sender, address(this), amount);
        }
        return _i_target.deposit(amount, receiver);
    }

    function redeem(Token token, uint256 shares, address receiver)
        public
        override
        checkAsset(token)
        returns (uint256 assets)
    {
        bool isNativeToken = token.isNative();
        address _receiver = isNativeToken ? address(this) : receiver;
        assets = _i_target.redeem(shares, _receiver, msg.sender);
        if (isNativeToken) _unwrapWETH(receiver, assets);
    }

    function _getWETHAddress() internal view virtual override returns (address) {
        return _i_WETH;
    }

    function getTokenInList() public view virtual override returns (Token[] memory tokens) {
        bool depositable = _i_target.maxDeposit(address(this)) > 0;
        if (!depositable) {
            tokens = new Token[](1);
            tokens[0] = Token.wrap(target());
            return tokens;
        }

        return _defaultTokenList();
    }

    function getTokenOutList() public view virtual override returns (Token[] memory tokens) {
        // The list doesn't include `asset()` because some ERC4626 have cooldown period for redeeming.
        tokens = new Token[](1);
        tokens[0] = Token.wrap(target());
    }

    /// @dev Default token list for ERC4626 if depositable or redeemable are true.
    function _defaultTokenList() internal view returns (Token[] memory tokens) {
        bool isWETH = asset() == _i_WETH;
        tokens = new Token[](isWETH ? 3 : 2);
        tokens[0] = Token.wrap(target());
        tokens[1] = Token.wrap(asset());
        if (isWETH) tokens[2] = Token.wrap(Constants.NATIVE_ETH);
    }
}
