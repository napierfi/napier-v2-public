// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "src/Constants.sol" as Constants;
import {Vm} from "forge-std/src/Vm.sol";

import {ERC20} from "solady/src/tokens/ERC4626.sol";

import {Events} from "src/Events.sol";
import {ITokiHook, ImmutableParamsLib} from "src/interfaces/ITokiHook.sol";

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";
import {MockERC4626Fees} from "../mocks/MockERC4626Fees.sol";
import {MockResyncingERC4626} from "../mocks/MockResyncingERC4626.sol";

/// @notice `PoolManager.sync` is permissionless and `settle` credits the balance change since the last sync,
/// so a vault that touches Uniswap v4 while paying out used to void the hook's settlement.
/// The rebalance leg committed that loss: it debited `reserves` and credited nothing.
contract VaultSettlementWindowHookTest is LiquidityHookBase {
    function setUp() public override {
        _setUp({enableRehypothecation0: true});
        _setupVault0();
    }

    function _deployRehypothecationVaults(address asset) internal override returns (MockERC4626Fees vault) {
        vault = new MockResyncingERC4626(ERC20(asset), true, vaultFeeRecipient, poolManager);
    }

    function test_Swap_RebalanceCreditsAssetsWhenVaultSyncsSameCurrency() public {
        _addInitialLiquidity(alice, alice);
        _forceWithdrawToTargetOnSwap();

        uint256 sharesBefore = stateOf(poolKey.toId()).reserves.value0();

        vm.recordLogs();
        _swap({user: alice, zeroForOne: false, amount: -int256(bOne), timeJump: 0});

        (uint256 assets, uint256 shares) = _rebalanceWithdrawal();

        assertEq(shares, sharesBefore - stateOf(poolKey.toId()).reserves.value0(), "shares debited from the book");
        assertGt(shares, 0, "swap should have rebalanced out of the vault");
        assertGt(stateOf(poolKey.toId()).rawBalances.value0(), 0, "the pool must hold the withdrawn assets");
        assertApproxEqAbs(
            assets, vault0.previewRedeem(shares), 1, "a vault's own sync must not void the rebalance credit"
        );
    }

    /// @dev Decodes the `VaultWithdraw` the rebalance leg emitted for currency0.
    function _rebalanceWithdrawal() internal returns (uint256 assets, uint256 shares) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 signature = keccak256("VaultWithdraw(bytes32,uint256,address,uint8,uint256,uint256)");

        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(tokiHook) || logs[i].topics[0] != signature) continue;
            if (uint256(logs[i].topics[2]) != uint256(ITokiHook.CurrencyIndex.CURRENCY_0)) continue;

            (uint8 flowType, uint256 assets_, uint256 shares_) = abi.decode(logs[i].data, (uint8, uint256, uint256));
            if (flowType != Events.VAULT_WITHDRAW_FLOW_REBALANCE) continue;

            return (assets_, shares_);
        }

        revert("no rebalance withdrawal emitted");
    }

    /// @dev Pushes the raw ratio below `minRawTokenRatio0` so the next swap rebalances by withdrawing from vault0.
    function _forceWithdrawToTargetOnSwap() internal {
        address pointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(pointer);
        params.minRawTokenRatio0 = 9_000;
        params.targetRawTokenRatio0 = 9_500;
        params.maxRawTokenRatio0 = 9_900;
        cheat_setImmutableParamsPointer(pointer, params);
    }
}
