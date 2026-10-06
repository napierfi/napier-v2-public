// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {ERC4626, ERC20} from "solady/src/tokens/ERC4626.sol";

contract MockERC4626 is ERC4626 {
    uint8 immutable i_decimalsOffset;
    bool i_useVirtualShares;
    ERC20 s_asset;

    constructor(ERC20 _asset, bool useVirtualShares) {
        s_asset = _asset;
        if (useVirtualShares) {
            i_useVirtualShares = true;
            i_decimalsOffset = 18 - s_asset.decimals();
        }
    }

    function name() public view override returns (string memory) {}

    function symbol() public view override returns (string memory) {}

    function asset() public view override returns (address) {
        return address(s_asset);
    }

    function _useVirtualShares() internal view override returns (bool) {
        return i_useVirtualShares;
    }

    function _underlyingDecimals() internal view override returns (uint8) {
        return s_asset.decimals();
    }

    function _decimalsOffset() internal view override returns (uint8) {
        return i_decimalsOffset;
    }
}

contract MockERC4626Decimals is MockERC4626 {
    uint8 immutable i_decimals;

    constructor(ERC20 _asset, bool useVirtualShares, uint8 _decimals) MockERC4626(_asset, useVirtualShares) {
        i_decimals = _decimals;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function assetsPerShare() public view returns (uint256) {
        return convertToAssets(10 ** i_decimals);
    }
}
