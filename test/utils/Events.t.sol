// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Brutalizer} from "../Brutalizer.sol";

import "src/Types.sol";
import {Events} from "src/Events.sol";

contract EventsTest is Brutalizer, Test {
    function testFuzz_YieldFeeAccrued(uint256 fee) public brutalizeMemory {
        vm.expectEmit(true, true, true, true);
        emit Events.YieldFeeAccrued(fee);
        Events.emitYieldFeeAccrued(fee);
    }

    function testFuzz_YieldAccrued(address account, uint256 interest, uint256 maxscale) public brutalizeMemory {
        vm.expectEmit(true, true, true, true);
        emit Events.YieldAccrued(account, interest, maxscale);
        Events.emitYieldAccrued(account, interest, maxscale);
    }

    function testFuzz_Supply(address by, address receiver, uint256 shares, uint256 principal) public brutalizeMemory {
        vm.expectEmit(true, true, true, true);
        emit Events.Supply(by, receiver, shares, principal);
        Events.emitSupply(by, receiver, shares, principal);
    }

    function testFuzz_Unite(address by, address receiver, uint256 shares, uint256 principal) public brutalizeMemory {
        vm.expectEmit(true, true, true, true);
        emit Events.Unite(by, receiver, shares, principal);
        Events.emitUnite(by, receiver, shares, principal);
    }

    function testFuzz_Redeem(address by, address receiver, address owner, uint256 shares, uint256 principal)
        public
        brutalizeMemory
    {
        vm.expectEmit(true, true, true, true);
        emit Events.Redeem(by, receiver, owner, shares, principal);
        Events.emitRedeem(by, receiver, owner, shares, principal);
    }

    function testFuzz_InterestCollected(address by, address receiver, address owner, uint256 shares)
        public
        brutalizeMemory
    {
        vm.expectEmit(true, true, true, true);
        emit Events.InterestCollected(by, receiver, owner, shares);
        Events.emitInterestCollected(by, receiver, owner, shares);
    }

    function testFuzz_RewardsCollected(address by, address receiver, address owner, address token, uint256 rewards)
        public
        brutalizeMemory
    {
        vm.expectEmit(true, true, true, true);
        emit Events.RewardsCollected(by, receiver, owner, token, rewards);
        Events.emitRewardsCollected(by, receiver, owner, token, rewards);
    }

    function testFuzz_SetApprovalCollector(address collector, address owner, uint256 approved) public brutalizeMemory {
        vm.expectEmit(true, true, true, true);
        emit Events.SetApprovalCollector(owner, collector, approved != 0);
        bool approvedDirty;
        assembly {
            approvedDirty := approved
        }
        Events.emitSetApprovalCollector(owner, collector, approvedDirty);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            Hooks                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_HookAddLiquidity(
        bytes32 poolId,
        address sender,
        address receiver,
        uint256 liquidity,
        uint256 amount0Spent,
        uint256 amount1Spent
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            sender := or(dirtyUpperBits, sender)
            receiver := or(dirtyUpperBits, receiver)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.HookAddLiquidity(poolId, sender, receiver, liquidity, amount0Spent, amount1Spent);
        Events.emitHookAddLiquidity({
            poolId: poolId,
            sender: sender,
            receiver: receiver,
            liquidity: liquidity,
            amount0Spent: amount0Spent,
            amount1Spent: amount1Spent
        });
    }

    function testFuzz_HookRemoveLiquidity(
        bytes32 poolId,
        address sender,
        address receiver,
        uint256 liquidity,
        uint256 amount0,
        uint256 amount1
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            sender := or(dirtyUpperBits, sender)
            receiver := or(dirtyUpperBits, receiver)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.HookRemoveLiquidity(poolId, sender, receiver, liquidity, amount0, amount1);
        Events.emitHookRemoveLiquidity({
            poolId: poolId,
            sender: sender,
            receiver: receiver,
            liquidity: liquidity,
            amount0: amount0,
            amount1: amount1
        });
    }

    function testFuzz_HookSwap(
        bytes32 poolId,
        address sender,
        int128 amount0,
        int128 amount1,
        uint128 hookLPfeeAmount0,
        uint128 hookLPfeeAmount1
    ) public brutalizeMemory {
        uint256 rnd = random();
        assembly {
            sender := or(shl(160, rnd), sender)
            amount0 := or(shl(128, rnd), amount0)
            amount1 := or(shl(128, rnd), amount1)
            hookLPfeeAmount0 := or(shl(128, rnd), hookLPfeeAmount0)
            hookLPfeeAmount1 := or(shl(128, rnd), hookLPfeeAmount1)
        }

        vm.expectEmit(true, true, true, true);
        emit Events.HookSwap(poolId, sender, amount0, amount1, hookLPfeeAmount0, hookLPfeeAmount1);
        Events.emitHookSwap({
            poolId: poolId,
            sender: sender,
            amount0: amount0,
            amount1: amount1,
            hookLPfeeAmount0: hookLPfeeAmount0,
            hookLPfeeAmount1: hookLPfeeAmount1
        });
    }

    function testFuzz_HookFeesAccrued(bytes32 poolId, uint128 curatorFee, uint128 protocolFee) public brutalizeMemory {
        uint256 rnd = random();
        assembly {
            curatorFee := or(shl(128, rnd), curatorFee)
            protocolFee := or(shl(128, rnd), protocolFee)
        }

        vm.expectEmit(true, true, true, true);
        emit Events.HookFeesAccrued(poolId, curatorFee, protocolFee);
        Events.emitHookFeesAccrued(poolId, curatorFee, protocolFee);
    }

    function testFuzz_HookCollectCuratorFeeCollected(bytes32 poolId, address receiver, uint256 fee)
        public
        brutalizeMemory
    {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            receiver := or(dirtyUpperBits, receiver)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.HookCollectCuratorFeeCollected(poolId, receiver, fee);
        Events.emitHookCollectCuratorFeeCollected(poolId, receiver, fee);
    }

    function testFuzz_HookProtocolFeeCollected(bytes32 poolId, address receiver, uint256 fee) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            receiver := or(dirtyUpperBits, receiver)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.HookProtocolFeeCollected(poolId, receiver, fee);
        Events.emitHookProtocolFeeCollected(poolId, receiver, fee);
    }

    function testFuzz_VaultRatiosUpdated(
        bytes32 poolId,
        bool updateCurrency0,
        uint16 targetRawTokenRatio,
        uint16 maxRawTokenRatio,
        uint16 minRawTokenRatio
    ) public brutalizeMemory {
        uint256 currencyIndex = updateCurrency0 ? 0 : 1;
        vm.expectEmit(true, true, true, true);
        emit Events.VaultRatiosUpdated(poolId, currencyIndex, targetRawTokenRatio, maxRawTokenRatio, minRawTokenRatio);
        Events.emitVaultRatiosUpdated(poolId, currencyIndex, targetRawTokenRatio, maxRawTokenRatio, minRawTokenRatio);
    }

    function testFuzz_VaultUpdated(bytes32 poolId, bool updateCurrency0, address oldVault, address newVault)
        public
        brutalizeMemory
    {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            oldVault := or(dirtyUpperBits, oldVault)
            newVault := or(dirtyUpperBits, newVault)
        }
        uint256 currencyIndex = updateCurrency0 ? 0 : 1;
        vm.expectEmit(true, true, true, true);
        emit Events.VaultUpdated(poolId, currencyIndex, oldVault, newVault);
        Events.emitVaultUpdated(poolId, currencyIndex, oldVault, newVault);
    }

    function testFuzz_VaultRatiosFrozen(bytes32 poolId, bool updateCurrency0) public brutalizeMemory {
        uint256 currencyIndex = updateCurrency0 ? 0 : 1;
        vm.expectEmit(true, true, true, true);
        emit Events.VaultRatiosFrozen(poolId, currencyIndex);
        Events.emitVaultRatiosFrozen(poolId, currencyIndex);
    }

    function testFuzz_VaultFrozen(bytes32 poolId, bool updateCurrency0) public brutalizeMemory {
        uint256 currencyIndex = updateCurrency0 ? 0 : 1;
        vm.expectEmit(true, true, true, true);
        emit Events.VaultFrozen(poolId, currencyIndex);
        Events.emitVaultFrozen(poolId, currencyIndex);
    }

    function testFuzz_VaultDeposit(bytes32 poolId, bool updateCurrency0, address vault, uint256 assets, uint256 shares)
        public
        brutalizeMemory
    {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            vault := or(dirtyUpperBits, vault)
        }
        uint256 currencyIndex = updateCurrency0 ? 0 : 1;
        vm.expectEmit(true, true, true, true);
        emit Events.VaultDeposit(poolId, currencyIndex, vault, assets, shares);
        Events.emitVaultDeposit(poolId, currencyIndex, vault, assets, shares);
    }

    function testFuzz_VaultWithdraw(
        bytes32 poolId,
        bool updateCurrency0,
        address vault,
        uint8 flowType,
        uint256 assets,
        uint256 shares
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            vault := or(dirtyUpperBits, vault)
        }
        uint256 currencyIndex = updateCurrency0 ? 0 : 1;
        vm.expectEmit(true, true, true, true);
        emit Events.VaultWithdraw(poolId, currencyIndex, vault, flowType, assets, shares);
        Events.emitVaultWithdraw(poolId, currencyIndex, vault, flowType, assets, shares);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            Zap                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_ZapAddLiquidity(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 shares,
        uint256 principal
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            by := or(dirtyUpperBits, by)
            receiver := or(dirtyUpperBits, receiver)
            twoCrypto := or(dirtyUpperBits, twoCrypto)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.ZapAddLiquidity(by, receiver, twoCrypto, liquidity, shares, principal);
        Events.emitZapAddLiquidity({
            by: by,
            receiver: receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            shares: shares,
            principal: principal
        });
    }

    function testFuzz_ZapAddLiquidityOneToken(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 ytOut,
        Token tokenIn,
        uint256 amountIn
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            by := or(dirtyUpperBits, by)
            receiver := or(dirtyUpperBits, receiver)
            twoCrypto := or(dirtyUpperBits, twoCrypto)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.ZapAddLiquidityOneToken(by, receiver, twoCrypto, liquidity, ytOut, tokenIn, amountIn);
        Events.emitZapAddLiquidityOneToken({
            by: by,
            receiver: receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            ytOut: ytOut,
            tokenIn: tokenIn,
            amountIn: amountIn
        });
    }

    function testFuzz_ZapRemoveLiquidity(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        uint256 shares,
        uint256 principal
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            by := or(dirtyUpperBits, by)
            receiver := or(dirtyUpperBits, receiver)
            twoCrypto := or(dirtyUpperBits, twoCrypto)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.ZapRemoveLiquidity(by, receiver, twoCrypto, liquidity, shares, principal);
        Events.emitZapRemoveLiquidity({
            by: by,
            receiver: receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            shares: shares,
            principal: principal
        });
    }

    function testFuzz_ZapRemoveLiquidityOneToken(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        uint256 liquidity,
        Token tokenOut,
        uint256 amountOut
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            by := or(dirtyUpperBits, by)
            receiver := or(dirtyUpperBits, receiver)
            twoCrypto := or(dirtyUpperBits, twoCrypto)
            tokenOut := or(dirtyUpperBits, tokenOut)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.ZapRemoveLiquidityOneToken(by, receiver, twoCrypto, liquidity, tokenOut, amountOut);
        Events.emitZapRemoveLiquidityOneToken({
            by: by,
            receiver: receiver,
            twoCrypto: twoCrypto,
            liquidity: liquidity,
            tokenOut: tokenOut,
            amountOut: amountOut
        });
    }

    function testFuzz_ZapSwap(
        address by,
        address receiver,
        TwoCrypto twoCrypto,
        Token tokenIn,
        uint256 amountIn,
        Token tokenOut,
        uint256 amountOut
    ) public brutalizeMemory {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            by := or(dirtyUpperBits, by)
            receiver := or(dirtyUpperBits, receiver)
            twoCrypto := or(dirtyUpperBits, twoCrypto)
            tokenIn := or(dirtyUpperBits, tokenIn)
            tokenOut := or(dirtyUpperBits, tokenOut)
        }
        vm.expectEmit(true, true, true, true);
        emit Events.ZapSwap(by, receiver, twoCrypto, tokenIn, amountIn, tokenOut, amountOut);
        Events.emitZapSwap({
            by: by,
            receiver: receiver,
            twoCrypto: twoCrypto,
            tokenIn: tokenIn,
            amountIn: amountIn,
            tokenOut: tokenOut,
            amountOut: amountOut
        });
    }

    enum ZapPrincipalTokenEvent {
        ZapSupply,
        ZapRedeem,
        ZapUnite
    }

    function testFuzz_ZapSupply(
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token token,
        uint256 amount
    ) public brutalizeMemory {
        _testFuzz_ZapPrincipalTokenEvent(ZapPrincipalTokenEvent.ZapSupply, by, receiver, pt, principal, token, amount);
    }

    function testFuzz_ZapRedeem(
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token token,
        uint256 amount
    ) public brutalizeMemory {
        _testFuzz_ZapPrincipalTokenEvent(ZapPrincipalTokenEvent.ZapRedeem, by, receiver, pt, principal, token, amount);
    }

    function testFuzz_ZapCombine(
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token token,
        uint256 amount
    ) public brutalizeMemory {
        _testFuzz_ZapPrincipalTokenEvent(ZapPrincipalTokenEvent.ZapUnite, by, receiver, pt, principal, token, amount);
    }

    function _testFuzz_ZapPrincipalTokenEvent(
        ZapPrincipalTokenEvent eventId,
        address by,
        address receiver,
        address pt,
        uint256 principal,
        Token token,
        uint256 amount
    ) internal {
        uint256 dirtyUpperBits = random() << 160;
        assembly {
            by := or(dirtyUpperBits, by)
            receiver := or(dirtyUpperBits, receiver)
            pt := or(dirtyUpperBits, pt)
            token := or(dirtyUpperBits, token)
        }

        vm.expectEmit(true, true, true, true);
        if (eventId == ZapPrincipalTokenEvent.ZapSupply) {
            emit Events.ZapSupply(by, receiver, pt, principal, token, amount);
            Events.emitZapSupply({
                by: by,
                receiver: receiver,
                pt: pt,
                principal: principal,
                tokenIn: token,
                amountIn: amount
            });
        } else if (eventId == ZapPrincipalTokenEvent.ZapRedeem) {
            emit Events.ZapRedeem(by, receiver, pt, principal, token, amount);
            Events.emitZapRedeem({
                by: by,
                receiver: receiver,
                pt: pt,
                principal: principal,
                tokenOut: token,
                amountOut: amount
            });
        } else if (eventId == ZapPrincipalTokenEvent.ZapUnite) {
            emit Events.ZapUnite(by, receiver, pt, principal, token, amount);
            Events.emitZapUnite({
                by: by,
                receiver: receiver,
                pt: pt,
                principal: principal,
                tokenOut: token,
                amountOut: amount
            });
        }
    }

    function random() internal pure returns (uint256) {
        return uint256(keccak256(msg.data));
    }
}
