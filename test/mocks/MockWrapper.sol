// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {IWETH} from "src/interfaces/IWETH.sol";
import {IERC4626Wrapper} from "src/wrapper/IERC4626Wrapper.sol";

import "src/Types.sol";

/// @dev Mock wrapper for testing purposes 1:1 exchange rate with original ERC4626 vault shares
contract MockWrapper is IERC4626Wrapper, ERC20 {
    ERC4626 s_vault;
    IWETH s_weth;
    bool s_initialized;

    receive() external payable {}

    /// @dev Immutable args is abi encoded as follows: abi.encode(address vault, address weth)
    /// - address vault: the address of the ERC4626 vault
    /// - address weth: the address of the WETH
    function initialize() external {
        require(!s_initialized, "Already initialized");
        s_initialized = true;

        bytes memory args = LibClone.argsOnClone(address(this));
        (s_vault, s_weth) = abi.decode(args, (ERC4626, IWETH));

        ERC20(asset()).approve(address(s_vault), type(uint256).max);
    }

    function totalAssets() public view returns (uint256) {
        return s_vault.convertToAssets(s_vault.balanceOf(address(this)));
    }

    function deposit(Token token, uint256 tokens, address receiver) external payable returns (uint256) {
        if (token.unwrap() == vault()) {
            SafeTransferLib.safeTransferFrom(vault(), msg.sender, address(this), tokens);
            _mint(receiver, tokens);
            return tokens;
        }

        if (token.isNative()) {
            require(asset() == address(s_weth), "Native token not supported");
            require(msg.value == tokens, "Invalid ETH amount");
            s_weth.deposit{value: tokens}();

            uint256 shares = s_vault.deposit(tokens, address(this));
            _mint(receiver, shares);
            return shares;
        }

        if (token.unwrap() == asset()) {
            SafeTransferLib.safeTransferFrom(token.unwrap(), msg.sender, address(this), tokens);
            uint256 shares = s_vault.deposit(tokens, address(this));
            _mint(receiver, shares);
            return shares;
        }

        revert("Invalid token");
    }

    function redeem(Token token, uint256 shares, address receiver) external returns (uint256) {
        _burn(msg.sender, shares);

        if (token.unwrap() == vault()) {
            SafeTransferLib.safeTransfer(vault(), receiver, shares);
            return shares;
        }

        uint256 assets = s_vault.redeem({shares: shares, to: address(this), owner: address(this)});
        if (token.isNative()) {
            require(asset() == address(s_weth), "Native token not supported");
            s_weth.withdraw(assets);
            SafeTransferLib.safeTransferETH(receiver, assets);
        } else if (token.unwrap() == asset()) {
            SafeTransferLib.safeTransfer(token.unwrap(), receiver, assets);
        } else {
            revert("Invalid token");
        }
        return assets;
    }

    function previewDeposit(Token token, uint256 tokens) external view returns (uint256) {
        // No `token` validation
        if (token.unwrap() == vault()) return tokens;
        return s_vault.previewDeposit(tokens);
    }

    function previewRedeem(Token token, uint256 shares) external view returns (uint256) {
        if (token.unwrap() == vault()) return shares;
        return s_vault.previewRedeem(shares);
    }

    function getTokenInList() public view returns (Token[] memory) {
        Token[] memory tokens = new Token[](2);
        tokens[0] = Token.wrap(s_vault.asset());
        tokens[1] = Token.wrap(address(s_weth));
        return tokens;
    }

    function getTokenOutList() external view returns (Token[] memory) {
        return getTokenInList();
    }

    function vault() public view override returns (address) {
        return address(s_vault);
    }

    function asset() public view returns (address) {
        return s_vault.asset();
    }

    function claimRewards() external returns (TokenReward[] memory) {}

    function name() public view override returns (string memory) {}

    function symbol() public view override returns (string memory) {}
}
