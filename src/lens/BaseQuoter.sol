// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

// Interfaces

import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {Factory} from "../Factory.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {VaultConnector, VaultConnectorRegistry} from "../modules/connectors/VaultConnectorRegistry.sol";

// Internal
import "../Types.sol";
import "../Constants.sol" as Constants;
import "../Errors.sol";
import {ContractValidation} from "../utils/ContractValidation.sol";
import {RewardLensLib} from "./RewardLensLib.sol";

abstract contract BaseQuoter {
    function factory() public view virtual returns (Factory);

    function vaultConnectorRegistry() public view virtual returns (VaultConnectorRegistry);

    function WETH() public view virtual returns (address);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Token List                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getTokenInList(PrincipalToken pt) internal view returns (Token[] memory) {
        address underlying = pt.underlying();
        address asset = address(pt.i_asset());

        VaultConnector connector = vaultConnectorRegistry().s_connectors(underlying, asset);
        bool isERC4626 = _isERC4626Depositable(underlying, asset);

        if (connector != VaultConnector(address(0))) {
            // Connector is present
            return connector.getTokenInList();
        } else if (underlying == asset) {
            // Underlying is same as asset. Handle the edge case to avoid duplicate tokens in the list.
            Token[] memory tokens = new Token[](1);
            tokens[0] = Token.wrap(underlying);
            return tokens;
        } else if (isERC4626) {
            // Underlying is like an ERC4626
            bool isWETH = asset == WETH();
            Token[] memory tokens = new Token[](isWETH ? 3 : 2);
            tokens[0] = Token.wrap(underlying);
            tokens[1] = Token.wrap(asset);
            if (isWETH) tokens[2] = Token.wrap(Constants.NATIVE_ETH);
            return tokens;
        } else {
            // None of the above
            Token[] memory tokens = new Token[](1);
            tokens[0] = Token.wrap(underlying);
            return tokens;
        }
    }

    function _getTokenOutList(PrincipalToken pt) internal view returns (Token[] memory) {
        address underlying = pt.underlying();
        address asset = address(pt.i_asset());

        VaultConnector connector = vaultConnectorRegistry().s_connectors(underlying, asset);
        if (connector != VaultConnector(address(0))) {
            return connector.getTokenOutList();
        } else {
            // Regardless of ERC4626 or not, the token out list is always the underlying token because some ERC4626 have cooldown period for redeeming.
            Token[] memory tokens = new Token[](1);
            tokens[0] = Token.wrap(underlying);
            return tokens;
        }
    }

    function _isERC4626Depositable(address erc4626Like, address asset) internal view returns (bool) {
        if (!ContractValidation.hasCode(erc4626Like)) return false; // No code
        // Calls may fail due to a non-existent function selector
        try ERC4626(erc4626Like).asset() returns (address _asset) {
            if (_asset != asset) return false; // Asset mismatch
        } catch {
            return false;
        }
        try ERC4626(erc4626Like).maxDeposit(address(this)) returns (uint256 maxDeposit) {
            if (maxDeposit == 0) return false; // Deposit limit reached
        } catch {
            return false;
        }
        try ERC4626(erc4626Like).previewDeposit(1) {}
        catch {
            return false;
        }
        return true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                PrincipalToken Preview                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Preview the amount of `pt` minted for a given amount `amountIn` of `tokenIn`
    /// @dev If `pt` is expired, the preview will return 0
    function previewSupply(PrincipalToken pt, Token tokenIn, uint256 amountIn)
        public
        view
        checkPrincipalToken(pt)
        returns (uint256)
    {
        uint256 shares = vaultPreviewDeposit(pt, tokenIn, amountIn);
        return pt.previewSupply(shares);
    }

    /// @notice Preview the amount of `tokenOut` that will be received in return for `principal` amount of `pt`
    /// @dev If `pt` is not expired, the preview will return 0
    function previewRedeem(PrincipalToken pt, Token tokenOut, uint256 principal)
        public
        view
        checkPrincipalToken(pt)
        returns (uint256)
    {
        uint256 shares = pt.previewRedeem(principal);
        return vaultPreviewRedeem(pt, tokenOut, shares);
    }

    /// @notice Preview the amount of `tokenOut` that will be received in return for `principal` amount of `pt`
    function previewCombine(PrincipalToken pt, Token tokenOut, uint256 principal)
        public
        view
        checkPrincipalToken(pt)
        returns (uint256)
    {
        uint256 shares = pt.previewCombine(principal);
        return vaultPreviewRedeem(pt, tokenOut, shares);
    }

    struct PreviewCollectResult {
        uint256 interest;
        TokenReward[] rewards;
    }

    function previewCollect(PrincipalToken pt, address account)
        public
        view
        checkPrincipalToken(pt)
        returns (PreviewCollectResult memory result)
    {
        result.interest = pt.previewCollect(account);
        result.rewards = RewardLensLib.getTokenRewards(pt, account);
    }

    function previewCollects(PrincipalToken[] calldata pts, address account)
        public
        view
        returns (PreviewCollectResult[] memory result)
    {
        result = new PreviewCollectResult[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            result[i] = previewCollect(pts[i], account);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       Vault Preview                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Preview the amount of shares minted for a given amount `amountIn` of `tokenIn`
    /// @dev Reverts if the token is not supported by the vault connector or ERC4626
    function vaultPreviewDeposit(PrincipalToken principalToken, Token tokenIn, uint256 amountIn)
        public
        view
        checkPrincipalToken(principalToken)
        returns (uint256)
    {
        address underlying = principalToken.underlying();
        address asset = address(principalToken.i_asset());
        return _previewDeposit(underlying, asset, tokenIn, amountIn);
    }

    /// @notice Preview the amount of `tokenOut` that will be received for `shares` shares of `principalToken.underlying()`
    /// @dev Reverts if the token is not supported by the vault connector or ERC4626
    function vaultPreviewRedeem(PrincipalToken principalToken, Token tokenOut, uint256 shares)
        public
        view
        checkPrincipalToken(principalToken)
        returns (uint256)
    {
        address underlying = principalToken.underlying();
        address asset = address(principalToken.i_asset());
        return _previewRedeem(underlying, asset, tokenOut, shares);
    }

    function _previewDeposit(address underlying, address asset, Token tokenIn, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (tokenIn.eq(underlying)) return amountIn; // No need to convert.

        VaultConnector connector = vaultConnectorRegistry().s_connectors(underlying, asset);

        if (connector != VaultConnector(address(0))) return connector.previewDeposit(tokenIn, amountIn);
        // Fall back to ERC4626 if the connector is not found
        if (tokenIn.eq(asset) || (tokenIn.isNative() && asset == WETH())) {
            (bool s, bytes memory ret) = underlying.staticcall(abi.encodeCall(ERC4626.previewDeposit, (amountIn)));
            if (s && underlying.code.length > 0) return abi.decode(ret, (uint256));
            revert Errors.Quoter_ERC4626FallbackCallFailed();
        }
        revert Errors.Quoter_ConnectorInvalidToken();
    }

    function _previewRedeem(address underlying, address asset, Token tokenOut, uint256 shares)
        internal
        view
        returns (uint256)
    {
        if (tokenOut.eq(underlying)) return shares; // No need to convert.

        VaultConnector connector = vaultConnectorRegistry().s_connectors(underlying, asset);

        if (connector != VaultConnector(address(0))) return connector.previewRedeem(tokenOut, shares);
        // Fall back to ERC4626 if the connector is not found
        if (tokenOut.eq(asset) || (tokenOut.isNative() && asset == WETH())) {
            (bool s, bytes memory ret) = underlying.staticcall(abi.encodeCall(ERC4626.previewRedeem, (shares)));
            if (s && underlying.code.length > 0) return abi.decode(ret, (uint256));
            revert Errors.Quoter_ERC4626FallbackCallFailed();
        }
        revert Errors.Quoter_ConnectorInvalidToken();
    }

    modifier checkPrincipalToken(PrincipalToken principalToken) {
        ContractValidation.checkPrincipalToken(factory(), address(principalToken));
        _;
    }
}
