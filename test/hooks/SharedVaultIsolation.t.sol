// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "src/Constants.sol" as Constants;
import "src/Errors.sol";

import {ERC20} from "solady/src/tokens/ERC4626.sol";

import {ITokiHook, ImmutableParamsLib} from "src/interfaces/ITokiHook.sol";
import {LiquidityAmounts} from "src/utils/LiquidityAmounts.sol";

import {LiquidityHookBase} from "./LiquidityHookBase.t.sol";
import {MockERC4626Fees} from "../mocks/MockERC4626Fees.sol";
import {MockMisreportingERC4626} from "../mocks/MockMisreportingERC4626.sol";

/// @notice The singleton hook holds one share balance per vault for every pool that selected it.
/// `reserves` is the only partition, so `Σ_pools reserves <= vault.balanceOf(hook)` must hold on every path.
/// Here a sibling pool's shares sit in the same balance while this pool's vault misreports what it moved.
contract SharedVaultIsolationHookTest is LiquidityHookBase {
    MockMisreportingERC4626 misreportingVault0;

    function setUp() public override {
        _setUp({enableRehypothecation0: true});
        _setupVault0();
        _seedSiblingPoolShares();
    }

    function _deployRehypothecationVaults(address asset) internal override returns (MockERC4626Fees vault) {
        misreportingVault0 = new MockMisreportingERC4626(ERC20(asset), true, vaultFeeRecipient);
        vault = misreportingVault0;
    }

    /// @dev Shares held by the hook on behalf of another pool that selected the same vault.
    function _seedSiblingPoolShares() internal {
        vm.startPrank(chika);
        deal(address(base), chika, 100_000 * bOne);
        base.approve(address(target), type(uint256).max);
        uint256 assets = target.deposit(100_000 * bOne, chika);
        target.approve(address(vault0), type(uint256).max);
        vault0.deposit(assets, address(tokiHook));
        vm.stopPrank();

        assertGt(_siblingShares(), 0, "sibling pool shares should be seeded");
    }

    function _siblingShares() internal view returns (uint256) {
        return vault0.balanceOf(address(tokiHook)) - stateOf(poolKey.toId()).reserves.value0();
    }

    function test_RemoveLiquidity_UnderreportedBurnStaysInPool() public {
        uint256 liquidity = _addInitialLiquidity(alice, alice);
        misreportingVault0.setUnderreportBurn(true);

        ITokiHook.PoolStorage memory stateBefore = stateOf(poolKey.toId());
        uint256 siblingBefore = _siblingShares();
        uint256 exitLiquidity = liquidity / 2;
        (uint256 shares0,) =
            LiquidityAmounts.getAmountsForLiquidity(exitLiquidity, stateBefore.totalLiquidity, stateBefore.reserves);
        assertGt(shares0, 0, "exit should touch the vault");

        vm.prank(alice);
        tokiHook.removeLiquidity(poolKey, exitLiquidity, alice);

        assertEq(
            stateBefore.reserves.value0() - stateOf(poolKey.toId()).reserves.value0(),
            shares0,
            "book must be debited by the position's proportional shares"
        );
        assertGe(_siblingShares(), siblingBefore, "sibling pool's shares must not back this pool's exit");
    }

    function test_RemoveLiquidity_RevertsWhenRedeemBurnsMoreThanTheClaim() public {
        uint256 liquidity = _addInitialLiquidity(alice, alice);
        misreportingVault0.setOverburnRedeem(true);

        vm.expectRevert(Errors.Rehypothecation_VaultRedeemMoreThanRequested.selector);
        vm.prank(alice);
        tokiHook.removeLiquidity(poolKey, liquidity / 2, alice);
    }

    function test_Swap_UnderreportedBurnStaysInPool() public {
        _addInitialLiquidity(alice, alice);
        _forceWithdrawToTargetOnSwap();
        misreportingVault0.setUnderreportBurn(true);

        uint256 potBefore = vault0.balanceOf(address(tokiHook));
        uint256 bookBefore = stateOf(poolKey.toId()).reserves.value0();
        uint256 siblingBefore = _siblingShares();

        _swap({user: alice, zeroForOne: false, amount: -int256(bOne), timeJump: 0});

        uint256 potBurned = potBefore - vault0.balanceOf(address(tokiHook));
        assertGt(potBurned, 0, "swap should have withdrawn from the vault");
        assertEq(
            bookBefore - stateOf(poolKey.toId()).reserves.value0(),
            potBurned,
            "book must be debited by the shares that actually left the hook"
        );
        assertGe(_siblingShares(), siblingBefore, "sibling pool's shares must not fund this pool's swap");
    }

    function test_AddLiquidity_OverreportedMintIsNotCredited() public {
        misreportingVault0.setOverreportMint(true);

        uint256 potBefore = vault0.balanceOf(address(tokiHook));
        uint256 bookBefore = stateOf(poolKey.toId()).reserves.value0();
        uint256 siblingBefore = _siblingShares();

        _addInitialLiquidity(alice, alice);

        uint256 potMinted = vault0.balanceOf(address(tokiHook)) - potBefore;
        assertGt(potMinted, 0, "deposit should have minted shares");
        assertEq(
            stateOf(poolKey.toId()).reserves.value0() - bookBefore,
            potMinted,
            "book must be credited only with the shares the vault actually minted"
        );
        assertEq(_siblingShares(), siblingBefore, "sibling pool's shares must stay untouched");
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
