// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ITokiHook, ImmutableParamsLib} from "src/interfaces/ITokiHook.sol";
import {TokiHook} from "src/hooks/TokiHook.sol";

/**
 * @title VaultConfigurationTest
 * @notice Comprehensive tests for vault configuration management including freeze functionality
 */
contract VaultConfigurationTest is LiquidityHookBase {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        TEST SETUP                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    ERC4626 newVault0;
    ERC4626 newVault1;
    ERC4626 newVault12;
    ERC4626 incompatibleVault0;
    ERC4626 incompatibleVault1;

    // Test ratio values
    uint16 constant VALID_TARGET_RATIO = 7000; // 70%
    uint16 constant VALID_MAX_RATIO = 8000; // 80%
    uint16 constant VALID_MIN_RATIO = 6000; // 60%

    uint16 constant INVALID_TARGET_RATIO = 9000; // 90% - invalid because > max
    uint16 constant INVALID_MAX_RATIO = 5000; // 50% - invalid because < target
    uint16 constant INVALID_MIN_RATIO = 8000; // 80% - invalid because > target

    constructor() {
        vault0Flags = 0;
        vault1Flags = 0;
    }

    function setUp() public override {
        // Deploy with rehypothecation enabled to test configuration updates
        _setUp({enableRehypothecation0: true});

        // Deploy new vaults for testing
        newVault0 = new MockERC4626(target, true);
        newVault1 = new MockERC4626(principalToken, true);
        newVault12 = new MockERC4626(principalToken, true);

        // Deploy incompatible vaults (wrong assets)
        incompatibleVault0 = new MockERC4626(principalToken, true); // Wrong asset for vault0
        incompatibleVault1 = new MockERC4626(target, true); // Wrong asset for vault1

        vault1 = _deployRehypothecationVaults(address(principalToken));

        // Enable rehypothecation for vault1
        _setRehypothecationVaults(poolKey, address(0), address(vault1));

        // Grant necessary permissions to curator
        _grantVaultConfigurationRole(curator);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    RATIO UPDATE TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_UpdateRatios_Currency0() public {
        _test_UpdateRatios(ITokiHook.CurrencyIndex.CURRENCY_0, VALID_TARGET_RATIO, VALID_MAX_RATIO, VALID_MIN_RATIO);
    }

    function test_UpdateRatios_Currency1() public {
        _test_UpdateRatios(ITokiHook.CurrencyIndex.CURRENCY_1, VALID_TARGET_RATIO, VALID_MAX_RATIO, VALID_MIN_RATIO);
    }

    function testFuzz_UpdateRatios(bool updateCurrency0, uint16 targetRatio, uint16 maxRatio, uint16 minRatio) public {
        ITokiHook.CurrencyIndex currencyIndex = _getCurrencyIndex(updateCurrency0);

        // Bound parameters to valid ranges
        targetRatio = uint16(bound(targetRatio, 1000, 9000));
        maxRatio = uint16(bound(maxRatio, targetRatio, Constants.BASIS_POINTS));
        minRatio = uint16(bound(minRatio, 0, targetRatio));

        _test_UpdateRatios(currencyIndex, targetRatio, maxRatio, minRatio);
    }

    function _test_UpdateRatios(
        ITokiHook.CurrencyIndex currencyIndex,
        uint16 targetRatio,
        uint16 maxRatio,
        uint16 minRatio
    ) internal {
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(currencyIndex, targetRatio, maxRatio, minRatio);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        // Verify ratios were updated
        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            assertEq(immutableParams.targetRawTokenRatio0, targetRatio, "target ratio");
            assertEq(immutableParams.maxRawTokenRatio0, maxRatio, "max ratio");
            assertEq(immutableParams.minRawTokenRatio0, minRatio, "min ratio");
        } else {
            assertEq(immutableParams.targetRawTokenRatio1, targetRatio, "target ratio");
            assertEq(immutableParams.maxRawTokenRatio1, maxRatio, "max ratio");
            assertEq(immutableParams.minRawTokenRatio1, minRatio, "min ratio");
        }
    }

    function test_RevertWhen_UpdateRatios_InvalidBounds() public {
        // Test min > target
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] =
            abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, VALID_TARGET_RATIO, VALID_MAX_RATIO, INVALID_MIN_RATIO);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        // Test target > max
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        vm.prank(curator);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        configParams[0] =
            abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, INVALID_TARGET_RATIO, INVALID_MAX_RATIO, VALID_MIN_RATIO);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        // Test max > 100%
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        vm.prank(curator);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, VALID_TARGET_RATIO, 11000, VALID_MIN_RATIO); // 110% max ratio
        tokiHook.updateConfiguration(poolKey, actions, configParams);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     VAULT UPDATE TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_UpdateVault(bool updateCurrency0) public {
        ITokiHook.CurrencyIndex currencyIndex = _getCurrencyIndex(updateCurrency0);
        _test_UpdateVault(
            currencyIndex, currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0 ? address(newVault0) : address(newVault1)
        );
    }

    function test_UpdateVault_WhenNoVault() public {
        // [Assumption]: Vault1 is not set. No need to withdraw from vault1
        require(vault1.balanceOf(address(tokiHook)) == 0, "No deposit to vault1");

        address immutableParamsPointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory params = ImmutableParamsLib.parse(immutableParamsPointer);
        params.vault1 = ERC4626(address(0));
        cheat_setImmutableParamsPointer(immutableParamsPointer, params);

        _test_UpdateVault(ITokiHook.CurrencyIndex.CURRENCY_1, address(newVault1));
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_UpdateVault(bool updateCurrency0, bool removeVault) public {
        ITokiHook.CurrencyIndex currencyIndex = _getCurrencyIndex(updateCurrency0);
        address newVault;
        if (removeVault) {
            newVault = address(0);
        } else {
            newVault = updateCurrency0 ? address(newVault0) : address(newVault1);
        }

        _test_UpdateVault(currencyIndex, newVault);
    }

    function _test_UpdateVault(ITokiHook.CurrencyIndex currencyIndex, address newVault) public {
        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());

        require(
            currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0 && stateBefore.reserves.value0() == 0
                || currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_1 && stateBefore.reserves.value1() == 0,
            "vault reserve must be 0"
        );

        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(currencyIndex, newVault);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            assertEq(address(immutableParams.vault0), newVault, "vault0 should be updated");
            if (newVault == address(0)) {
                assertEq(immutableParams.targetRawTokenRatio0, Constants.BASIS_POINTS, "target ratio should be 100%");
                assertEq(immutableParams.maxRawTokenRatio0, Constants.BASIS_POINTS, "max ratio should be 100%");
                assertEq(immutableParams.minRawTokenRatio0, Constants.BASIS_POINTS, "min ratio should be 100%");
            }
            // Check vaults are updated
            (ERC4626 poolVault0, ERC4626 poolVault1) = vaultsOf(poolKey.toId());
            assertEq(address(poolVault0), newVault);
            assertEq(address(poolVault1), address(vault1));

            // Check reserves are zero
            assertEq(stateOf(poolKey.toId()).reserves.value0(), 0, "reserves0");
            assertEq(stateOf(poolKey.toId()).rawBalances.value0(), stateBefore.rawBalances.value0(), "rawBalances0");
            assertEq(stateOf(poolKey.toId()).reserves.value1(), stateBefore.reserves.value1(), "reserves1");
            assertEq(stateOf(poolKey.toId()).rawBalances.value1(), stateBefore.rawBalances.value1(), "rawBalances1");
            assertEq(vault0.balanceOf(address(tokiHook)), 0, "vault0 balance");
        } else {
            assertEq(address(immutableParams.vault1), newVault, "vault1 should be updated");
            if (newVault == address(0)) {
                assertEq(immutableParams.targetRawTokenRatio1, Constants.BASIS_POINTS, "target ratio should be 100%");
                assertEq(immutableParams.maxRawTokenRatio1, Constants.BASIS_POINTS, "max ratio should be 100%");
                assertEq(immutableParams.minRawTokenRatio1, Constants.BASIS_POINTS, "min ratio should be 100%");
            }
            // Check vaults are updated
            (ERC4626 poolVault0, ERC4626 poolVault1) = vaultsOf(poolKey.toId());
            assertEq(address(poolVault0), address(vault0));
            assertEq(address(poolVault1), newVault);

            assertEq(stateOf(poolKey.toId()).reserves.value0(), stateBefore.reserves.value0(), "reserves0");
            assertEq(stateOf(poolKey.toId()).rawBalances.value0(), stateBefore.rawBalances.value0(), "rawBalances0");
            assertEq(stateOf(poolKey.toId()).reserves.value1(), 0, "reserves1");
            assertEq(stateOf(poolKey.toId()).rawBalances.value1(), stateBefore.rawBalances.value1(), "rawBalances1");
            assertEq(vault1.balanceOf(address(tokiHook)), 0, "vault1 balance");
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_UpdateVault_RevertWhen_AssetMismatch(bool updateCurrency0) public {
        ITokiHook.CurrencyIndex currencyIndex = _getCurrencyIndex(updateCurrency0);

        vm.expectRevert(Errors.Rehypothecation_VaultAssetMismatch.selector);
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        bytes[] memory params = new bytes[](1);
        params[0] =
            abi.encode(currencyIndex, updateCurrency0 ? address(incompatibleVault0) : address(incompatibleVault1));
        tokiHook.updateConfiguration(poolKey, actions, params);
    }

    function test_UpdateVault_RevertWhen_VaultHasAssets() public {
        _addInitialLiquidity(alice, alice);

        vm.expectRevert(Errors.TokiHook_VaultHasAssets.selector);
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        bytes[] memory params = new bytes[](1);
        params[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, address(newVault0));
        tokiHook.updateConfiguration(poolKey, actions, params);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      FREEZE TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_FreezeRatios(bool updateCurrency0, uint256 count) public {
        ITokiHook.CurrencyIndex currencyIndex =
            updateCurrency0 ? ITokiHook.CurrencyIndex.CURRENCY_0 : ITokiHook.CurrencyIndex.CURRENCY_1;
        count = bound(count, 1, 8);

        uint256 oldVaultFlags;
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            oldVaultFlags = _getImmutableParams().vaultFlags0;
        } else {
            oldVaultFlags = _getImmutableParams().vaultFlags1;
        }

        for (uint256 i = 0; i < count; i++) {
            vm.prank(curator);
            ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
            actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
            bytes[] memory configParams = new bytes[](1);
            configParams[0] = abi.encode(currencyIndex);
            tokiHook.updateConfiguration(poolKey, actions, configParams);
        }

        // Verify ratios are frozen
        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            assertTrue(immutableParams.vaultFlags0 & Constants.REHYPO_RATIOS_FROZEN != 0, "vaultFlag0");
            assertEq(immutableParams.vaultFlags1, oldVaultFlags, "vaultFlag1");
        } else {
            assertTrue(immutableParams.vaultFlags1 & Constants.REHYPO_RATIOS_FROZEN != 0, "vaultFlag1");
            assertEq(immutableParams.vaultFlags0, oldVaultFlags, "vaultFlag0");
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_FreezeVault(bool updateCurrency0, uint256 count) public {
        ITokiHook.CurrencyIndex currencyIndex =
            updateCurrency0 ? ITokiHook.CurrencyIndex.CURRENCY_0 : ITokiHook.CurrencyIndex.CURRENCY_1;
        count = bound(count, 1, 8);

        uint256 oldVaultFlags;
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            oldVaultFlags = _getImmutableParams().vaultFlags0;
        } else {
            oldVaultFlags = _getImmutableParams().vaultFlags1;
        }

        for (uint256 i = 0; i < count; i++) {
            vm.prank(curator);
            ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
            actions[0] = ITokiHook.UpdateConfiguration.FREEZE_VAULT;
            bytes[] memory configParams = new bytes[](1);
            configParams[0] = abi.encode(currencyIndex);
            tokiHook.updateConfiguration(poolKey, actions, configParams);
        }

        // Verify vault is frozen
        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        if (currencyIndex == ITokiHook.CurrencyIndex.CURRENCY_0) {
            assertTrue(immutableParams.vaultFlags0 & Constants.REHYPO_VAULT_FROZEN != 0, "vaultFlag0");
            assertEq(immutableParams.vaultFlags1, oldVaultFlags, "vaultFlag1");
        } else {
            assertTrue(immutableParams.vaultFlags1 & Constants.REHYPO_VAULT_FROZEN != 0, "vaultFlag1");
            assertEq(immutableParams.vaultFlags0, oldVaultFlags, "vaultFlag0");
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_UpdateRatios_RevertWhen_Frozen(bool updateCurrency0) public {
        ITokiHook.CurrencyIndex currencyIndex =
            updateCurrency0 ? ITokiHook.CurrencyIndex.CURRENCY_0 : ITokiHook.CurrencyIndex.CURRENCY_1;
        // First freeze ratios
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(currencyIndex);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        // Try to update ratios - should revert
        vm.expectRevert(Errors.Rehypothecation_ParamsFrozen.selector);
        vm.prank(curator);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        configParams[0] = abi.encode(currencyIndex, VALID_TARGET_RATIO, VALID_MAX_RATIO, VALID_MIN_RATIO);
        tokiHook.updateConfiguration(poolKey, actions, configParams);
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_UpdateVault_RevertWhen_Frozen(bool updateCurrency0) public {
        ITokiHook.CurrencyIndex currencyIndex =
            updateCurrency0 ? ITokiHook.CurrencyIndex.CURRENCY_0 : ITokiHook.CurrencyIndex.CURRENCY_1;
        // First freeze vault
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_VAULT;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(currencyIndex);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        // Try to update vault - should revert
        vm.expectRevert(Errors.Rehypothecation_VaultFrozen.selector);
        vm.prank(curator);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        configParams[0] = abi.encode(currencyIndex, updateCurrency0 ? address(newVault0) : address(newVault1));
        tokiHook.updateConfiguration(poolKey, actions, configParams);
    }

    /// @notice Frozen ratios must survive a net-zero `UPDATE_VAULT` batch that removes and restores the same vault
    function test_FreezeRatios_BatchRemoveAndRestoreVault_PreservesRatios() public {
        _addInitialLiquidity(alice, alice);
        assertGt(stateOf(poolKey.toId()).reserves.value0(), 0, "reserves0 must be live");

        vm.startPrank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        // Net vault change is zero, so the vault-has-assets invariant passes
        ITokiHook.UpdateConfiguration[] memory batch = new ITokiHook.UpdateConfiguration[](2);
        batch[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        batch[1] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        bytes[] memory batchParams = new bytes[](2);
        batchParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, address(0));
        batchParams[1] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, address(vault0));
        tokiHook.updateConfiguration(poolKey, batch, batchParams);
        vm.stopPrank();

        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        assertEq(address(immutableParams.vault0), address(vault0), "vault0");
        assertEq(
            immutableParams.targetRawTokenRatio0, rehypothecationConfig0.targetRawTokenRatio, "target ratio unchanged"
        );
        assertEq(immutableParams.maxRawTokenRatio0, rehypothecationConfig0.maxRawTokenRatio, "max ratio unchanged");
        assertEq(immutableParams.minRawTokenRatio0, rehypothecationConfig0.minRawTokenRatio, "min ratio unchanged");

        // The frozen split is still enforced: the next swap must not unwind the vault position
        _swap({user: alice, zeroForOne: true, amount: -int256(INITIAL_AMOUNT0 / 113), timeJump: 1 hours});
        assertGt(stateOf(poolKey.toId()).reserves.value0(), 0, "reserves0 must survive the next swap");
    }

    /// @notice Frozen ratios must not block vault removal: the two freeze flags are independent
    function test_FreezeRatios_RemoveVault_PreservesRatios() public {
        assertEq(stateOf(poolKey.toId()).reserves.value1(), 0, "reserves1 must be empty");

        vm.startPrank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_1);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_1, address(0));
        tokiHook.updateConfiguration(poolKey, actions, configParams);
        vm.stopPrank();

        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        assertEq(address(immutableParams.vault1), address(0), "vault1 removed");
        assertEq(
            immutableParams.targetRawTokenRatio1, rehypothecationConfig1.targetRawTokenRatio, "target ratio unchanged"
        );
        assertEq(immutableParams.maxRawTokenRatio1, rehypothecationConfig1.maxRawTokenRatio, "max ratio unchanged");
        assertEq(immutableParams.minRawTokenRatio1, rehypothecationConfig1.minRawTokenRatio, "min ratio unchanged");
    }

    function test_RevertWhen_NotAuthorized() public {
        // Test all actions with unauthorized user
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        bytes[] memory configParams = new bytes[](1);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        configParams[0] =
            abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, VALID_TARGET_RATIO, VALID_MAX_RATIO, VALID_MIN_RATIO);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, address(newVault0));
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0);
        tokiHook.updateConfiguration(poolKey, actions, configParams);

        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(bob);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_VAULT;
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0);
        tokiHook.updateConfiguration(poolKey, actions, configParams);
    }

    function test_RevertWhen_PoolDoesNotExist() public {
        PoolKey memory invalidKey = _createInvalidPoolKey();

        vm.expectRevert(Errors.BadTokiPool.selector);
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] =
            abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, VALID_TARGET_RATIO, VALID_MAX_RATIO, VALID_MIN_RATIO);
        tokiHook.updateConfiguration(invalidKey, actions, configParams);
    }

    function test_RevertWhen_CurrencyIndexOutOfBounds() public {
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);

        vm.startPrank(curator);

        {
            actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
            bytes[] memory configParams = new bytes[](1);
            configParams[0] = abi.encode(
                2, // out of bounds
                VALID_TARGET_RATIO,
                VALID_MAX_RATIO,
                VALID_MIN_RATIO
            );
            vm.expectRevert();
            tokiHook.updateConfiguration(poolKey, actions, configParams);
        }

        {
            actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
            bytes[] memory configParams = new bytes[](1);
            configParams[0] = abi.encode(
                3, // out of bounds
                address(newVault0)
            );
            vm.expectRevert();
            tokiHook.updateConfiguration(poolKey, actions, configParams);
        }
        {
            actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
            bytes[] memory configParams = new bytes[](1);
            configParams[0] = abi.encode(2); // out of bounds
            vm.expectRevert();
            tokiHook.updateConfiguration(poolKey, actions, configParams);
        }
        {
            actions[0] = ITokiHook.UpdateConfiguration.FREEZE_VAULT;
            bytes[] memory configParams = new bytes[](1);
            configParams[0] = abi.encode(2); // out of bounds
            vm.expectRevert();
            tokiHook.updateConfiguration(poolKey, actions, configParams);
        }
        vm.stopPrank();
    }

    function test_RevertWhen_PoolPaused() public {
        // Set pausable flags
        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        immutableParams.pausableFlags =
            Flags16.wrap(immutableParams.pausableFlags.unwrap() | Constants.PAUSABLE_CONFIGURATION_UPDATE);
        cheat_setImmutableParamsPointer(stateOf(poolKey.toId()).immutableParamsPointer, immutableParams);

        // Grant pause/unpause roles to curator
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = principalToken.pause.selector;
        selectors[1] = principalToken.unpause.selector;
        _grantRoles({account: curator, roles: Constants.DEV_ROLE, callee: address(principalToken), selectors: selectors});

        // Pause
        vm.prank(curator);
        principalToken.pause();

        vm.expectRevert(Errors.LibPauseGuard_Paused.selector);
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](1);
        actions[0] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
        bytes[] memory configParams = new bytes[](1);
        configParams[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0);
        tokiHook.updateConfiguration(poolKey, actions, configParams);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     BATCH UPDATE TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_BatchUpdate_Vaults() public {
        // Test batch update of ratios for both currencies
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](2);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        actions[1] = ITokiHook.UpdateConfiguration.UPDATE_VAULT;
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_1, address(newVault1)); // Currency1
        params[1] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_1, address(newVault12)); // Currency1
        tokiHook.updateConfiguration(poolKey, actions, params);

        // Verify both currencies were updated
        ITokiHook.ImmutableParams memory immutableParams = _getImmutableParams();
        assertEq(address(immutableParams.vault1), address(newVault12), "vault1");
        assertEq(address(immutableParams.vault0), address(vault0), "vault0");
    }

    function test_RevertWhen_ArrayLengthMismatch() public {
        // Test that mismatched array lengths revert
        vm.expectRevert(); // Should revert with array length mismatch
        vm.prank(curator);
        ITokiHook.UpdateConfiguration[] memory actions = new ITokiHook.UpdateConfiguration[](2);
        actions[0] = ITokiHook.UpdateConfiguration.UPDATE_RATIOS;
        actions[1] = ITokiHook.UpdateConfiguration.FREEZE_RATIOS;
        bytes[] memory params = new bytes[](1); // Mismatched length!
        params[0] = abi.encode(ITokiHook.CurrencyIndex.CURRENCY_0, VALID_TARGET_RATIO, VALID_MAX_RATIO, VALID_MIN_RATIO);
        tokiHook.updateConfiguration(poolKey, actions, params);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       HELPERS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getCurrencyIndex(bool updateCurrency0) internal pure returns (ITokiHook.CurrencyIndex) {
        return updateCurrency0 ? ITokiHook.CurrencyIndex.CURRENCY_0 : ITokiHook.CurrencyIndex.CURRENCY_1;
    }

    function _grantVaultConfigurationRole(address user) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiHook.updateConfiguration.selector;
        _grantRoles({account: user, roles: Constants.DEV_ROLE, callee: address(tokiHook), selectors: selectors});
    }

    function _getImmutableParams() internal view returns (ITokiHook.ImmutableParams memory) {
        address pointer = stateOf(poolKey.toId()).immutableParamsPointer;
        return ImmutableParamsLib.parse(pointer);
    }
}
