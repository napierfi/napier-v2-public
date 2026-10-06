// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {ERC4626, ERC20} from "solady/src/tokens/ERC4626.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import {LibRehypothecation} from "src/utils/LibRehypothecation.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockMaliciousERC4626} from "../mocks/MockMaliciousERC4626.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract LibRehypothecationTest is Test {
    using SafeCastLib for *;
    using FixedPointMathLib for uint256;

    address alice = makeAddr("alice");

    MockERC20 asset;
    MockERC4626 vault;
    MockERC4626 vault2;
    MockERC4626 vaultDifferentAsset;
    MockMaliciousERC4626 maliciousVault;

    function setUp() public {
        asset = new MockERC20(18);
        vault = new MockERC4626(ERC20(address(asset)), false);
        vault2 = new MockERC4626(ERC20(address(asset)), false);
        maliciousVault = new MockMaliciousERC4626(ERC20(address(asset)), false);

        MockERC20 differentAsset = new MockERC20(18);
        vaultDifferentAsset = new MockERC4626(ERC20(address(differentAsset)), false);

        asset.mint(address(this), 1_000e18);

        // Setup vaults
        vm.startPrank(alice);
        asset.mint(alice, 1_000e18);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, alice);
        asset.mint(address(vault), 100e18); // Donate to vaut
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VALIDATE VAULT                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ValidateVault() public view {
        LibRehypothecation.validateVault(ERC4626(address(0)), address(asset));
        LibRehypothecation.validateVault(vault, address(asset));
    }

    function test_RevertWhen_VaultAssetMismatch() public {
        vm.expectRevert(Errors.Rehypothecation_VaultAssetMismatch.selector);
        this.validateVault(vaultDifferentAsset, address(asset));
    }

    function validateVault(ERC4626 v, address a) external view {
        LibRehypothecation.validateVault(v, a);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              VALIDATE REHYPOTHECATION PARAMS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// forge-config: default.allow_internal_expect_revert = true
    function test_ValidateRehypothecationParams() public {
        // Valid params: min <= target <= max <= BASIS_POINTS
        LibRehypothecation.validateRehypothecationParams(5000, 8000, 2000);
        LibRehypothecation.validateRehypothecationParams(5000, 5000, 5000);
        LibRehypothecation.validateRehypothecationParams(0, Constants.BASIS_POINTS, 0);

        // Invalid: min > target
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        LibRehypothecation.validateRehypothecationParams(5000, 8000, 6000);

        // Invalid: target > max
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        LibRehypothecation.validateRehypothecationParams(8000, 7000, 2000);

        // Invalid: max > BASIS_POINTS
        vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
        LibRehypothecation.validateRehypothecationParams(5000, Constants.BASIS_POINTS + 1, 2000);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testFuzz_ValidateRehypothecationParams(uint256 target, uint256 max, uint256 min) public {
        if (min > target || target > max || max > Constants.BASIS_POINTS) {
            vm.expectRevert(Errors.Rehypothecation_InvalidRawTokenRatioBounds.selector);
            LibRehypothecation.validateRehypothecationParams(target, max, min);
        } else {
            LibRehypothecation.validateRehypothecationParams(target, max, min);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         GET BALANCES                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ReservesInUnderlying() public view {
        assertEq(LibRehypothecation.getReservesInUnderlying(ERC4626(address(0)), 100), 0);
        assertEq(LibRehypothecation.getReservesInUnderlying(ERC4626(address(0)), 219999999), 0);
        assertEq(LibRehypothecation.getReservesInUnderlying(ERC4626(address(0)), 1e21), 0);
        assertEq(LibRehypothecation.getReservesInUnderlying(vault, 100), vault.previewRedeem(100));
        assertEq(LibRehypothecation.getReservesInUnderlying(vault, 219999999), vault.previewRedeem(219999999));
        assertEq(LibRehypothecation.getReservesInUnderlying(vault, 212e18), vault.previewRedeem(212e18));
    }

    function testFuzz_GetTotalBalances(
        uint128 shares0,
        uint128 shares1,
        uint128 raw0,
        uint128 raw1,
        uint128 redeemValue0,
        uint128 redeemValue1
    ) public {
        vm.assume(uint256(redeemValue0) + raw0 <= type(uint128).max);
        vm.assume(uint256(redeemValue1) + raw1 <= type(uint128).max);

        vm.mockCall(
            address(vault),
            abi.encodeWithSelector(ERC4626.previewRedeem.selector, shares0),
            abi.encode(uint256(redeemValue0))
        );
        vm.mockCall(
            address(vault2),
            abi.encodeWithSelector(ERC4626.previewRedeem.selector, shares1),
            abi.encode(uint256(redeemValue1))
        );

        Uint128x2 reserves = Packing.pack_uint128x2(shares0, shares1);
        Uint128x2 rawBalances = Packing.pack_uint128x2(raw0, raw1);
        Uint128x2 result = LibRehypothecation.getTotalBalances(vault, vault2, reserves, rawBalances);

        assertEq(result.value0(), redeemValue0 + raw0);
        assertEq(result.value1(), redeemValue1 + raw1);
        vm.clearMockedCalls();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  CALCULATE DEPOSIT AMOUNT                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_CalculateDepositAmount(uint256 amount, uint256 targetRatio) public pure {
        amount = bound(amount, 0, type(uint128).max);
        targetRatio = bound(targetRatio, 0, Constants.BASIS_POINTS);
        assertLe(LibRehypothecation.calculateDepositAmount(amount, targetRatio), amount);
    }

    function testFuzz_CalculateDepositAmount(uint256 amount, uint256 targetRatio, uint256 maxDeposit) public {
        amount = bound(amount, 0, type(uint128).max);
        targetRatio = bound(targetRatio, 0, Constants.BASIS_POINTS);

        vm.mockCall(
            address(vault), abi.encodeWithSelector(ERC4626.maxDeposit.selector, address(this)), abi.encode(maxDeposit)
        );
        uint256 result = LibRehypothecation.calculateDepositAmount(vault, amount, targetRatio);
        assertEq(
            result, FixedPointMathLib.min(LibRehypothecation.calculateDepositAmount(amount, targetRatio), maxDeposit)
        );
        vm.clearMockedCalls();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               CALCULATE RAW BALANCE BOUNDS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_CalculateRawBalanceBounds() public pure {
        // Basic calculation
        (uint256 target, uint256 min, uint256 max) =
            LibRehypothecation.calculateRawBalanceBounds(10000, 7000, 8000, 6000);
        assertEq(target, 7000); // 10000 * 70%
        assertEq(min, 6000); // 10000 * 60%
        assertEq(max, 8000); // 10000 * 80%

        // Zero balance
        (target, min, max) = LibRehypothecation.calculateRawBalanceBounds(0, 7000, 8000, 6000);
        assertEq(target, 0);
        assertEq(min, 0);
        assertEq(max, 0);

        // Boundary ratios (100%)
        (target, min, max) = LibRehypothecation.calculateRawBalanceBounds(
            10000, Constants.BASIS_POINTS, Constants.BASIS_POINTS, Constants.BASIS_POINTS
        );
        assertEq(target, 10000);
        assertEq(min, 10000);
        assertEq(max, 10000);

        // Boundary ratios (0%)
        (target, min, max) = LibRehypothecation.calculateRawBalanceBounds(10000, 0, 0, 0);
        assertEq(target, 0);
        assertEq(min, 0);
        assertEq(max, 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VAULT OPERATIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_Deposit(uint256 amount) public {
        uint256 balanceBefore = asset.balanceOf(address(this));

        amount = bound(amount, 0, balanceBefore);

        (uint256 shares,, uint256 assetsSpent) = LibRehypothecation.depositToVault(vault, address(asset), amount);

        assertEq(vault.balanceOf(address(this)), shares, "shares");
        assertEq(asset.balanceOf(address(this)), balanceBefore - assetsSpent, "assetsSpent");
        assertEq(amount, assetsSpent, "assetsSpent");
        assertEq(asset.allowance(address(this), address(vault)), 0, "allowance");
    }

    function test_Deposit_RevertWhen_VaultDepositMoreThanRequested() public {
        uint256 amount = 219021;
        bytes[] memory returnData = new bytes[](2);
        returnData[0] = abi.encode(asset.balanceOf(address(this)));
        returnData[1] = abi.encode(asset.balanceOf(address(this)) - (amount + 1)); // Spend more than it's allowed

        vm.mockCalls(address(asset), abi.encodeCall(asset.balanceOf, (address(this))), returnData);
        vm.expectRevert(Errors.Rehypothecation_VaultDepositMoreThanRequested.selector);
        this.depositToVault(vault, address(asset), amount);
    }

    function depositToVault(ERC4626 v, address a, uint256 amount) external {
        LibRehypothecation.depositToVault(v, a, amount);
    }

    function test_RedeemFromVault_HappyPath() public {
        uint256 depositAssets = 500 ether;
        asset.approve(address(vault), type(uint256).max);
        uint256 mintedShares = vault.deposit(depositAssets, address(this));

        uint256 sharesToRedeem = mintedShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);

        uint256 assetBefore = asset.balanceOf(alice);
        uint256 sharesBefore = vault.balanceOf(address(this));

        (uint256 sharesRedeemed, uint256 assetsWithdrawn) =
            LibRehypothecation.redeemFromVault(vault, address(asset), sharesToRedeem, alice);

        uint256 assetAfter = asset.balanceOf(alice);
        uint256 sharesAfter = vault.balanceOf(address(this));

        assertEq(sharesRedeemed, sharesToRedeem, "sharesRedeemed");
        assertEq(assetsWithdrawn, expectedAssets, "assetsWithdrawn");
        assertEq(sharesAfter, sharesBefore - sharesToRedeem, "sharesAfter");
        assertEq(assetAfter, assetBefore + expectedAssets, "assetAfter");
    }

    function test_RedeemFromVault_RevertsWhenVaultBurnsTooManyShares() public {
        uint256 depositAssets = 600 ether;
        asset.approve(address(maliciousVault), type(uint256).max);
        maliciousVault.deposit(depositAssets, address(this));

        maliciousVault.setUpAttack(true, address(0xbad));

        uint256 sharesToRedeem = 1234;

        vm.expectRevert(Errors.Rehypothecation_VaultRedeemMoreThanRequested.selector);
        this.redeemFromVault(maliciousVault, address(asset), sharesToRedeem, address(this));
    }

    /// @dev External wrapper: `vm.expectRevert` does not attach to an internal library call whose first
    /// external interaction is a raw assembly staticcall.
    function redeemFromVault(ERC4626 v, address a, uint256 shares, address receiver) external {
        LibRehypothecation.redeemFromVault(v, a, shares, receiver);
    }
}
