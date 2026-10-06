// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;
import {Events} from "src/Events.sol";
import {ITokiHook} from "src/interfaces/ITokiHook.sol";
import {MockMaliciousERC4626} from "../mocks/MockMaliciousERC4626.sol";

import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title UnwindVaultTest
/// @notice Test suite for TokiHook.unwindVault function
contract UnwindVaultTest is LiquidityHookBase {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    PHASE 1: FOUNDATION TESTS               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public override {
        // Enable rehypothecation for currency0 vault
        _setUp(true);

        // Setup vault0 with initial assets
        _setupVault0();

        // Grant permissions for unwindVault function
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = tokiHook.unwindVault.selector;
        _grantRoles({account: curator, roles: Constants.DEV_ROLE, callee: address(tokiHook), selectors: selectors});

        // Add initial liquidity to create reserves
        vm.startPrank(alice);
        uint256 amount0 = 100_000e18;
        uint256 amount1 = 100_000e18;
        tokiHook.addLiquidity(poolKey, amount0, amount1, alice, alice);
        vm.stopPrank();

        require(address(vault0) != address(0), "TEST: Vault0 must be set");
        require(address(vault1) == address(0), "TEST: Vault1 must be set to 0");

        vault0.setEntryFeeBasisPoints(529);
        vault0.setExitFeeBasisPoints(312);
    }

    /// @notice Happy path - unwind vault shares with valid inputs
    /// @dev Tests unwinding a portion of vault shares successfully
    function test_UnwindVault() public {
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        uint256 reservesBefore0 = stateBefore.reserves.value0();

        uint256 sharesToUnwind = reservesBefore0 / 2;
        testFuzz_UnwindVault(sharesToUnwind);
    }

    /// @dev Tests unwinding a portion of vault shares successfully
    function testFuzz_UnwindVault(uint256 sharesToUnwind) public {
        // Arrange
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        uint256 reservesBefore = stateBefore.reserves.value0();
        uint256 rawBalancesBefore = stateBefore.rawBalances.value0();

        sharesToUnwind = bound(sharesToUnwind, 0, reservesBefore);
        uint256 expectedAssets = vault0.previewRedeem(sharesToUnwind);
        // Act
        vm.prank(curator);
        if (sharesToUnwind > 0 || expectedAssets > 0) {
            vm.expectEmit(true, true, true, false);
            emit Events.VaultWithdraw(
                PoolId.unwrap(poolKey.toId()),
                uint256(ITokiHook.CurrencyIndex.CURRENCY_0),
                address(vault0),
                Events.VAULT_WITHDRAW_FLOW_UNWIND,
                0,
                0
            );
        }
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, sharesToUnwind, expectedAssets);

        // Assert
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());

        uint256 reservesAfter = stateAfter.reserves.value0();
        uint256 rawBalancesAfter = stateAfter.rawBalances.value0();

        assertEq(reservesAfter, reservesBefore - sharesToUnwind, "Reserves should decrease");
        assertApproxEqAbs(
            rawBalancesAfter,
            rawBalancesBefore + expectedAssets,
            1, // Allow 1 wei difference due to rounding
            "Raw balances should increase by assets received"
        );
    }

    /// @notice Unwind with type(uint256).max to redeem all shares
    function test_MaxShares() public {
        // Arrange
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        uint256 allShares = stateBefore.reserves.value0();
        uint256 expectedAssets = vault0.previewRedeem(allShares);

        // Act
        vm.prank(curator);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, type(uint256).max, expectedAssets);

        // Assert
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertEq(stateAfter.reserves.value0(), 0, "All reserves should be unwound");
        assertApproxEqAbs(
            stateAfter.rawBalances.value0(),
            stateBefore.rawBalances.value0() + expectedAssets,
            1,
            "Raw balances should increase by all assets"
        );
    }

    /// @notice Unwind with type(uint256).max redeems all shares the vault can currently serve
    function test_MaxShares_WhenRedeemCapped() public {
        // Arrange
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        vault0.setWithdrawCap(vault0.previewRedeem(stateBefore.reserves.value0()) / 4);
        uint256 redeemableShares = vault0.maxRedeem(address(tokiHook));

        // Act
        vm.prank(curator);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, type(uint256).max, 0);

        // Assert
        ITokiHook.PoolStorage memory stateAfter = stateOf(poolKey.toId());
        assertEq(
            stateBefore.reserves.value0() - stateAfter.reserves.value0(),
            redeemableShares,
            "Redeem should be clamped to the vault capacity"
        );
        assertGt(stateAfter.reserves.value0(), 0, "Remaining reserves should be left in the vault");
    }

    function test_RevertWhen_NoRedeemCapacity() public {
        vault0.setWithdrawCap(0);

        vm.expectRevert(Errors.TokiHook_NoVaultRedeemCapacity.selector);
        vm.prank(curator);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, type(uint256).max, 0);
    }

    function test_RevertWhen_NoVaultSet() public {
        vm.expectRevert(Errors.TokiHook_VaultNotSet.selector);
        vm.prank(curator);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_1, type(uint256).max, 0);
    }

    /// @notice Revert when unwinding more shares than available in reserves
    function test_RevertWhen_VaultWithdrawMoreThanReserves() public {
        // Arrange
        ITokiHook.PoolStorage memory state = stateOf(poolKey.toId());
        uint256 reserves = state.reserves.value0();
        uint256 excessiveShares = reserves + 1;

        // Act & Assert
        vm.prank(curator);
        vm.expectRevert(Errors.TokiHook_VaultWithdrawMoreThanReserves.selector);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, excessiveShares, 0);
    }

    function test_RevertWhen_VaultRedeemMoreThanRequested() public {
        uint256 reserve = stateOf(poolKey.toId()).reserves.value0();
        deal(address(vault0), address(tokiHook), reserve + 1);

        // Arrange
        MockMaliciousERC4626 maliciousVault0 = new MockMaliciousERC4626(target, true);
        vm.etch(address(vault0), address(maliciousVault0).code);
        MockMaliciousERC4626(address(vault0)).setUpAttack(true, address(0xbad));

        // Act & Assert
        vm.prank(curator);
        vm.expectRevert(Errors.Rehypothecation_VaultRedeemMoreThanRequested.selector);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, reserve / 2, 0);
    }

    function test_RevertWhen_SlippageTooHigh() public {
        // Arrange
        ITokiHook.PoolStorage memory state = stateOf(poolKey.toId());
        uint256 sharesToUnwind = state.reserves.value0() / 2;
        uint256 expectedAssets = vault0.previewRedeem(sharesToUnwind);
        uint256 unrealisticMinAssets = expectedAssets * 2; // Require more than possible

        // Act & Assert
        vm.prank(curator);
        vm.expectRevert(Errors.TokiHook_InsufficientAssetsWithdrawn.selector);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_0, sharesToUnwind, unrealisticMinAssets);
    }

    function test_RevertWhen_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        tokiHook.unwindVault(poolKey, ITokiHook.CurrencyIndex.CURRENCY_1, 0, 0);
    }

    function test_RevertWhen_BadPool() public {
        PoolKey memory invalidKey = _createInvalidPoolKey();

        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(curator);
        tokiHook.unwindVault(invalidKey, ITokiHook.CurrencyIndex.CURRENCY_1, 100e18, 0);
    }
}
