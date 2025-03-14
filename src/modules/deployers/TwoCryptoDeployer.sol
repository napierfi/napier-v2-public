// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {EIP5095} from "../../interfaces/EIP5095.sol";
import {IPoolDeployer} from "../../interfaces/IPoolDeployer.sol";

import {TwoCryptoNGParams} from "../../Types.sol";
import {TokenNameLib} from "../../utils/TokenNameLib.sol";
import {Errors} from "../../Errors.sol";

type TwoCryptoFactory is address;

/// @notice Wrapper for TwoCryptoFactory
/// @dev Separate external library to downsize Factory contract.
contract TwoCryptoDeployer is IPoolDeployer {
    /// @notice https://etherscan.io/address/0x98EE851a00abeE0d95D08cF4CA2BdCE32aeaAF7F
    TwoCryptoFactory public immutable factory;

    uint256 constant IMPLEMENTATION_IDX = 0;
    bytes4 constant DEPLOY_SELECTOR = 0xc955fa04;

    constructor(address _factory) {
        factory = TwoCryptoFactory.wrap(_factory);
    }

    function deploy(address underlying, address principalToken, bytes calldata params)
        external
        payable
        returns (address)
    {
        bytes memory data = _encodeDeployData(underlying, principalToken, params);
        (bool success, bytes memory ret) = TwoCryptoFactory.unwrap(factory).call(data);
        if (!success) revert Errors.PoolDeployer_FailedToDeployPool();
        return abi.decode(ret, (address));
    }

    function _encodeDeployData(address underlying, address principalToken, bytes calldata params)
        internal
        view
        returns (bytes memory)
    {
        uint256 maturity = EIP5095(principalToken).maturity();
        /// Note: There is a limit on the length of the name and symbol of TwoCrypto LP token.
        /// Too long name and symbol cause deployment to fail.
        string memory name = TokenNameLib.lpTokenName(underlying, maturity);
        string memory symbol = TokenNameLib.lpTokenSymbol(underlying, maturity);
        return abi.encodeWithSelector(
            DEPLOY_SELECTOR,
            name,
            symbol,
            [underlying, principalToken],
            IMPLEMENTATION_IDX,
            // Avoid stack too deep error by passing params as a struct instead of individual parameters
            // Note: the order of members in the struct must match the order of the parameters in the function
            abi.decode(params, (TwoCryptoNGParams))
        );
    }
}
