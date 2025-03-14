// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "./Types.sol";

library Events {
    /// @dev `keccak256(bytes("YieldFeeAccrued(uint256)"))`.
    uint256 constant _YIELD_FEE_ACCRUED_EVENT_SIGNATURE =
        0xac693c1b946bcf3ad16baa51b744b990b94ea9c79ac71f2d1b5369a823a7d065;

    /// @dev `keccak256(bytes("YieldAccrued(address,uint256,uint256)"))`.
    uint256 constant _YIELD_ACCRUED_EVENT_SIGNATURE = 0xaced61c86c507aa3c2be43553434c6ff191ea7cbbd812491a6ae59abc99d29dc;

    /// @dev `keccak256(bytes("Supply(address,address,uint256,uint256)"))`.
    uint256 constant _SUPPLY_EVENT_SIGNATURE = 0x69a3ea8e6d6819646fbf2b98e9e8dd6d9cd343852550621038b4d72e4aa6dd37;

    /// @dev `keccak256(bytes("Unite(address,address,uint256,uint256)"))`.
    uint256 constant _UNITE_EVENT_SIGNATURE = 0xc78456d21b5d71405d0daba05157c90a4a412d7379fd21c3bc8a679b65b13b5f;

    /// @dev `keccak256(bytes("Redeem(address,address,address,uint256,uint256)"))`.
    uint256 constant _REDEEM_EVENT_SIGNATURE = 0xaee47cdf925cf525fdae94f9777ee5a06cac37e1c41220d0a8a89ed154f62d1c;

    /// @dev `keccak256(bytes("InterestCollected(address,address,address,uint256)"))`.
    uint256 constant _INTEREST_COLLECTED_EVENT_SIGNATURE =
        0x54affe52c3988f9c9e1d9d4673ffb7b398832c049d65e63b51326c89255e8529;

    /// @dev `keccak256(bytes("RewardsCollected(address,address,address,address,uint256)"))`.
    uint256 constant _REWARDS_COLLECTED_EVENT_SIGNATURE =
        0xc295ddd3f2581ded7ee79ef613567c637f9eabc1c1cf6c107bffaf63461614aa;

    /// @dev `keccak256(bytes("SetApprovalCollector(address,address,bool)"))`.
    uint256 constant _SET_APPROVAL_COLLECTOR_EVENT_SIGNATURE =
        0xa3b5109b351b1b1c9b05310b3176941fadf2a0c23d9bd59f5107f23d888202af;

    // Deployment events
    event Deployed(address indexed pt, address indexed yt, address indexed pool, uint256 expiry, address target);

    // Factory events
    event PrincipalTokenImplementationSet(address indexed ptBlueprint, address indexed ytBlueprint);
    event PoolDeployerSet(address indexed deployer, bool enabled);
    event AccessManagerImplementationSet(address indexed implementation, bool enabled);
    event ResolverBlueprintSet(address indexed resolverBlueprint, bool enabled);
    event TreasurySet(address indexed treasury);
    event ModuleImplementationSet(
        ModuleIndex indexed moduleType, address indexed implementation, bool enableCustomImplementation
    );
    event ModuleUpdated(ModuleIndex indexed moduleType, address indexed instance, address indexed principalToken);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      PrincipalToken                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // Fee accumulation events
    event YieldFeeAccrued(uint256 fee);

    // Fee collection events
    event CuratorFeesCollected(address indexed by, address indexed receiver, uint256 shares, TokenReward[] rewards);
    event ProtocolFeesCollected(address indexed by, address indexed receiver, uint256 shares, TokenReward[] rewards);

    // Yield events
    event YieldAccrued(address indexed account, uint256 interest, uint256 maxscale);

    // User interaction events
    event Supply(address indexed by, address indexed receiver, uint256 shares, uint256 principal);
    event Unite(address indexed by, address indexed receiver, uint256 shares, uint256 principal);
    // Note `Redeem` event doesn't follow EIP55095: https://eips.ethereum.org/EIPS/eip-5095 because the standard lacks the `by` parameter and `underlyingAmount` parameter.
    event Redeem(
        address indexed by, address indexed receiver, address indexed owner, uint256 shares, uint256 principal
    );
    event InterestCollected(address indexed by, address indexed receiver, address indexed owner, uint256 shares);
    event RewardsCollected(
        address indexed by, address indexed receiver, address indexed owner, address rewardToken, uint256 rewards
    );

    // Approval events
    event SetApprovalCollector(address indexed owner, address indexed collector, bool approved);

    function emitYieldFeeAccrued(uint256 fee) internal {
        assembly {
            mstore(0x00, fee)
            log1(0x00, 0x20, _YIELD_FEE_ACCRUED_EVENT_SIGNATURE)
        }
    }

    function emitYieldAccrued(address account, uint256 interest, uint256 globalIndex) internal {
        assembly {
            mstore(0x00, interest)
            mstore(0x20, globalIndex)
            let m := shr(96, not(0))
            log2(0x00, 0x40, _YIELD_ACCRUED_EVENT_SIGNATURE, and(m, account))
        }
    }

    function emitSupply(address by, address receiver, uint256 shares, uint256 principal) internal {
        assembly {
            mstore(0x00, shares)
            mstore(0x20, principal)
            let m := shr(96, not(0))
            log3(0x00, 0x40, _SUPPLY_EVENT_SIGNATURE, and(m, by), and(m, receiver))
        }
    }

    function emitUnite(address by, address receiver, uint256 shares, uint256 principal) internal {
        assembly {
            mstore(0x00, shares)
            mstore(0x20, principal)
            let m := shr(96, not(0))
            log3(0x00, 0x40, _UNITE_EVENT_SIGNATURE, and(m, by), and(m, receiver))
        }
    }

    function emitRedeem(address by, address receiver, address owner, uint256 shares, uint256 principal) internal {
        assembly {
            mstore(0x00, shares)
            mstore(0x20, principal)
            let m := shr(96, not(0))
            log4(0x00, 0x40, _REDEEM_EVENT_SIGNATURE, and(m, by), and(m, receiver), and(m, owner))
        }
    }

    function emitInterestCollected(address by, address receiver, address owner, uint256 shares) internal {
        assembly {
            mstore(0x00, shares)
            let m := shr(96, not(0))
            log4(0x00, 0x20, _INTEREST_COLLECTED_EVENT_SIGNATURE, and(m, by), and(m, receiver), and(m, owner))
        }
    }

    function emitRewardsCollected(address by, address receiver, address owner, address rewardToken, uint256 rewards)
        internal
    {
        assembly {
            let m := shr(96, not(0))
            mstore(0x00, and(m, rewardToken))
            mstore(0x20, rewards)
            log4(0x00, 0x40, _REWARDS_COLLECTED_EVENT_SIGNATURE, and(m, by), and(m, receiver), and(m, owner))
        }
    }

    function emitSetApprovalCollector(address owner, address collector, bool approved) internal {
        assembly {
            mstore(0x00, iszero(iszero(approved))) // Convert to 0 or 1
            let m := shr(96, not(0))
            log3(0x00, 0x20, _SET_APPROVAL_COLLECTOR_EVENT_SIGNATURE, and(m, owner), and(m, collector))
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            Zap                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Zap emits events for subgraph indexing users' transaction history.

    /// @dev `keccak256(bytes("ZapAddLiquidity(address,address,address,uint256,uint256,uint256)"))`.
    uint256 constant _ZAP_ADD_LIQUIDITY_SIGNATURE = 0x9e32f0e680e9faeb02a2fc3e7d2827cda9d3cf5b76c1879471c323bf0eddabce;

    /// @dev `keccak256(bytes("ZapAddLiquidityOneToken(address,address,address,uint256,uint256,address,uint256)"))`.
    uint256 constant _ZAP_ADD_LIQUIDITY_ONE_TOKEN_SIGNATURE =
        0x7cb19c3f09182abfd1d04b62fd55ffc2117c34c5e56ae0611ce778a785db6a05;

    /// @dev `keccak256(bytes("ZapRemoveLiquidity(address,address,address,uint256,uint256,uint256)"))`.
    uint256 constant _ZAP_REMOVE_LIQUIDITY_SIGNATURE =
        0x6d83a83b5c09cc7a964f9410802c001ffcfe3cd20e5bed47d41da364fd73048a;

    /// @dev `keccak256(bytes("ZapRemoveLiquidityOneToken(address,address,address,uint256,address,uint256)"))`.
    uint256 constant _ZAP_REMOVE_LIQUIDITY_ONE_TOKEN_SIGNATURE =
        0x85ff7539ec623e1a79d85fa73fdd19d84b48a2c174ea2573537d31b84218cf49;

    /// @dev `keccak256(bytes("ZapSwap(address,address,address,address,uint256,address,uint256)"))`.
    uint256 constant _ZAP_SWAP_SIGNATURE = 0x6d901733826355a03dd5004731f362a9f053f6476de435133fbff936d04226bf;

    /// @dev `keccak256(bytes("ZapSupply(address,address,address,uint256,address,uint256)"))`.
    uint256 constant _ZAP_SUPPLY_SIGNATURE = 0x9cebfeda04666057d1878b729da376084a1cb1623bafb6107989201b411644a6;

    /// @dev `keccak256(bytes("ZapUnite(address,address,address,uint256,address,uint256)"))`.
    uint256 constant _ZAP_UNITE_SIGNATURE = 0x49000823b8190200215cf672aa160fc7550472c5a70d765fe4f2bd787757b2a4;

    /// @dev `keccak256(bytes("ZapRedeem(address,address,address,uint256,address,uint256)"))`.
    uint256 constant _ZAP_REDEEM_SIGNATURE = 0x9e9c3d8bb36eb5f0ab7e30facf1fd3a018b489e86b105830b6aaa72a1e4d0a6c;

    event ZapAddLiquidity(
        address indexed by,
        address indexed receiver,
        TwoCrypto indexed twoCrypto,
        uint256 liquidity,
        uint256 shares,
        uint256 principal
    );

    event ZapAddLiquidityOneToken(
        address indexed by,
        address indexed receiver,
        TwoCrypto indexed twoCrypto,
        uint256 liquidity,
        uint256 ytOut,
        Token tokenIn,
        uint256 amountIn
    );

    function emitZapAddLiquidity(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 shares,
        uint256 principal
    ) internal {
        assembly {
            let fmp := mload(0x40)
            let m := shr(96, not(0))
            mstore(0x00, liquidity)
            mstore(0x20, shares)
            mstore(0x40, principal)
            log4(0x00, 0x60, _ZAP_ADD_LIQUIDITY_SIGNATURE, and(m, by), and(m, receiver), and(m, twoCrypto))
            mstore(0x40, fmp)
        }
    }

    function emitZapAddLiquidityOneToken(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 ytOut,
        Token tokenIn,
        uint256 amountIn
    ) internal {
        assembly {
            let fmp := mload(0x40)
            let m := shr(96, not(0))
            mstore(0x00, liquidity)
            mstore(0x20, ytOut)
            mstore(0x40, and(m, tokenIn))
            mstore(0x60, amountIn)
            log4(0x00, 0x80, _ZAP_ADD_LIQUIDITY_ONE_TOKEN_SIGNATURE, and(m, by), and(m, receiver), and(m, twoCrypto))
            mstore(0x60, 0) // Restore the zero slot to zero
            mstore(0x40, fmp) // Restore the free memory pointer
        }
    }

    event ZapRemoveLiquidity(
        address indexed by,
        address indexed receiver,
        TwoCrypto indexed twoCrypto,
        uint256 liquidity,
        uint256 shares,
        uint256 principal
    );

    event ZapRemoveLiquidityOneToken(
        address indexed by,
        address indexed receiver,
        TwoCrypto indexed twoCrypto,
        uint256 liquidity,
        Token tokenOut,
        uint256 amountOut
    );

    function emitZapRemoveLiquidity(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 shares,
        uint256 principal
    ) internal {
        assembly {
            let fmp := mload(0x40)
            let m := shr(96, not(0))
            mstore(0x00, liquidity)
            mstore(0x20, shares)
            mstore(0x40, principal)
            log4(0x00, 0x60, _ZAP_REMOVE_LIQUIDITY_SIGNATURE, and(m, by), and(m, receiver), and(m, twoCrypto))
            mstore(0x40, fmp)
        }
    }

    function emitZapRemoveLiquidityOneToken(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        Token tokenOut,
        uint256 amountOut
    ) internal {
        assembly {
            let fmp := mload(0x40)
            let m := shr(96, not(0))
            mstore(0x00, liquidity)
            mstore(0x20, and(m, tokenOut))
            mstore(0x40, amountOut)
            log4(0x00, 0x60, _ZAP_REMOVE_LIQUIDITY_ONE_TOKEN_SIGNATURE, and(m, by), and(m, receiver), and(m, twoCrypto))
            mstore(0x40, fmp)
        }
    }

    event ZapSwap(
        address indexed by,
        address indexed receiver,
        TwoCrypto indexed twoCrypto,
        Token tokenIn,
        uint256 amountIn,
        Token tokenOut,
        uint256 amountOut
    );

    function emitZapSwap(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        Token tokenIn,
        uint256 amountIn,
        Token tokenOut,
        uint256 amountOut
    ) internal {
        assembly {
            let fmp := mload(0x40) // Cache free memory pointer
            let m := shr(96, not(0))
            mstore(0x00, and(m, tokenIn))
            mstore(0x20, amountIn)
            mstore(0x40, and(m, tokenOut))
            mstore(0x60, amountOut)
            log4(0x00, 0x80, _ZAP_SWAP_SIGNATURE, and(m, by), and(m, receiver), and(m, twoCrypto))
            mstore(0x60, 0) // Restore the zero slot to zero
            mstore(0x40, fmp) // Restore the free memory pointer
        }
    }

    event ZapSupply(
        address indexed by,
        address indexed receiver,
        address indexed pt,
        uint256 principal,
        Token tokenIn,
        uint256 amountIn
    );

    event ZapUnite(
        address indexed by,
        address indexed receiver,
        address indexed pt,
        uint256 principal,
        Token tokenOut,
        uint256 amountOut
    );

    event ZapRedeem(
        address indexed by,
        address indexed receiver,
        address indexed pt,
        uint256 principal,
        Token tokenOut,
        uint256 amountOut
    );

    function emitZapSupply(address by, address receiver, address pt, uint256 principal, Token tokenIn, uint256 amountIn)
        internal
    {
        _logZapPrincipalEvent({
            signature: _ZAP_SUPPLY_SIGNATURE,
            by: by,
            receiver: receiver,
            pt: pt,
            principal: principal,
            token: tokenIn,
            amount: amountIn
        });
    }

    function emitZapUnite(
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token tokenOut,
        uint256 amountOut
    ) internal {
        _logZapPrincipalEvent({
            signature: _ZAP_UNITE_SIGNATURE,
            by: by,
            receiver: receiver,
            pt: pt,
            principal: principal,
            token: tokenOut,
            amount: amountOut
        });
    }

    function emitZapRedeem(
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token tokenOut,
        uint256 amountOut
    ) internal {
        _logZapPrincipalEvent({
            signature: _ZAP_REDEEM_SIGNATURE,
            by: by,
            receiver: receiver,
            pt: pt,
            principal: principal,
            token: tokenOut,
            amount: amountOut
        });
    }

    function _logZapPrincipalEvent(
        uint256 signature,
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token token,
        uint256 amount
    ) private {
        assembly {
            let fmp := mload(0x40)
            let m := shr(96, not(0))
            mstore(0x00, principal)
            mstore(0x20, and(m, token))
            mstore(0x40, amount)
            log4(0x00, 0x60, signature, and(m, by), and(m, receiver), and(m, pt))
            mstore(0x40, fmp)
        }
    }
}
