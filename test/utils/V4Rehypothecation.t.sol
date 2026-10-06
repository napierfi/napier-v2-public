// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {ERC4626, ERC20} from "solady/src/tokens/ERC4626.sol";

import {MockERC20} from "test/mocks/MockERC20.sol";
import {MockERC4626} from "test/mocks/MockERC4626.sol";
import {MockERC4626Fees} from "test/mocks/MockERC4626Fees.sol";
import {MockERC4626TakeLess} from "test/mocks/MockERC4626TakeLess.sol";
import {MockMaliciousERC4626} from "test/mocks/MockMaliciousERC4626.sol";
import {MockResyncingERC4626} from "test/mocks/MockResyncingERC4626.sol";

import "src/Errors.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {V4Rehypothecation} from "src/utils/V4Rehypothecation.sol";

contract V4RehypothecationTest is Test, IUnlockCallback {
    // Test constants
    uint256 constant INITIAL_BALANCE = 1000 ether;

    // Test contracts
    IPoolManager poolManager;
    MockERC20 asset;
    MockERC4626Fees vault;
    MockResyncingERC4626 resyncingVault;
    Currency currency;

    // Test accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        // Deploy real PoolManager (as per codebase pattern)
        poolManager = new PoolManager(address(this));

        // Deploy mock contracts
        asset = new MockERC20(18);
        vault = new MockERC4626Fees(ERC20(address(asset)), false, 0, 0, address(0xcafe));
        currency = Currency.wrap(address(asset));

        // Set up balances
        asset.mint(address(this), type(uint96).max);

        // Initialize PoolManager with some tokens
        poolManager.unlock(abi.encode("setUp"));

        vault.setEntryFeeBasisPoints(311);
        vault.setExitFeeBasisPoints(210);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       HELPER FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _testDepositClaimTokens(uint256 amount) internal returns (bytes memory) {
        (uint256 shares, uint256 assetsSpent) =
            V4Rehypothecation.depositClaimTokensToVault(poolManager, vault, currency, amount);
        return abi.encode(shares, assetsSpent);
    }

    function _testWithdrawClaimTokens(uint256 amount) internal returns (bytes memory) {
        (uint256 shares, uint256 assetsWithdrawn) =
            V4Rehypothecation.withdrawClaimTokensFromVault(poolManager, vault, currency, amount);
        return abi.encode(shares, assetsWithdrawn);
    }

    function _testRedeemClaimTokens(uint256 shares) internal returns (bytes memory) {
        (uint256 sharesRedeemed, uint256 assetsWithdrawn) =
            V4Rehypothecation.redeemClaimTokensFromVault(poolManager, vault, currency, shares);
        return abi.encode(sharesRedeemed, assetsWithdrawn);
    }

    function setMaxDeposit(MockERC4626Fees v, uint256 maxDeposit) public {
        vm.mockCall(
            address(v), abi.encodeWithSelector(ERC4626.maxDeposit.selector, address(this)), abi.encode(maxDeposit)
        );
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        string memory action = abi.decode(data, (string));

        if (keccak256(bytes(action)) == keccak256(bytes("setUp"))) {
            poolManager.sync(currency);
            asset.mint(address(poolManager), INITIAL_BALANCE);
            poolManager.settle();
            poolManager.mint(address(this), currency.toId(), INITIAL_BALANCE);
            return "";
        }

        if (keccak256(bytes(action)) == keccak256(bytes("depositTest"))) {
            (, uint256 amount) = abi.decode(data, (string, uint256));
            return _testDepositClaimTokens(amount);
        }

        if (keccak256(bytes(action)) == keccak256(bytes("withdrawTest"))) {
            (, uint256 amount) = abi.decode(data, (string, uint256));
            return _testWithdrawClaimTokens(amount);
        }

        if (keccak256(bytes(action)) == keccak256(bytes("redeemTest"))) {
            (, uint256 shares) = abi.decode(data, (string, uint256));
            return _testRedeemClaimTokens(shares);
        }

        if (keccak256(bytes(action)) == keccak256(bytes("withdrawResync"))) {
            (, uint256 amount) = abi.decode(data, (string, uint256));
            (uint256 shares, uint256 assetsWithdrawn) =
                V4Rehypothecation.withdrawClaimTokensFromVault(poolManager, resyncingVault, currency, amount);
            return abi.encode(shares, assetsWithdrawn);
        }

        if (keccak256(bytes(action)) == keccak256(bytes("redeemResync"))) {
            (, uint256 shares) = abi.decode(data, (string, uint256));
            (uint256 sharesRedeemed, uint256 assets) =
                V4Rehypothecation.redeemClaimTokensFromVault(poolManager, resyncingVault, currency, shares);
            return abi.encode(sharesRedeemed, assets);
        }

        return "";
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    DEPOSIT CLAIM TOKENS TESTS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_DepositClaimTokens_HappyPath(uint256 assets) public {
        assets = bound(assets, 0, INITIAL_BALANCE);

        // Ensure vault has capacity and this contract has approval
        uint256 preview = vault.previewDeposit(assets);

        bytes memory result = poolManager.unlock(abi.encode("depositTest", assets));
        (uint256 shares, uint256 assetsSpent) = abi.decode(result, (uint256, uint256));

        assertEq(shares, preview, "shares");
        assertEq(assetsSpent, assets, "assetsSpent");
    }

    function test_DepositClaimTokens_WhenPoolManagerBalanceIsLessThanAssets() public {
        uint256 max = asset.balanceOf(address(poolManager));
        uint256 assets = max + 1;

        uint256 preview = vault.previewDeposit(max);

        bytes memory result = poolManager.unlock(abi.encode("depositTest", assets));
        (uint256 shares, uint256 assetsSpent) = abi.decode(result, (uint256, uint256));

        assertEq(shares, preview, "shares");
        assertEq(assetsSpent, max, "assetsSpent");
    }

    function test_DepositClaimTokens_WhenVaultMaxDepositIsReached() public {
        uint256 maxDeposit = 12121;
        uint256 assets = maxDeposit + 12120190;

        setMaxDeposit(vault, maxDeposit);

        uint256 preview = vault.previewDeposit(maxDeposit);

        bytes memory result = poolManager.unlock(abi.encode("depositTest", assets));
        (uint256 shares, uint256 assetsSpent) = abi.decode(result, (uint256, uint256));

        assertEq(shares, preview, "shares");
        assertEq(assetsSpent, maxDeposit, "assetsSpent");
    }

    function test_DepositClaimTokens_WhenVaultTakesLessThanRequested() public {
        MockERC4626TakeLess vaultTakeLess = new MockERC4626TakeLess(ERC20(address(asset)), false);
        vm.etch(address(vault), address(vaultTakeLess).code);

        uint256 assets = 100 ether;
        uint256 preview = vault.previewDeposit(assets);

        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency.toId());

        bytes memory result = poolManager.unlock(abi.encode("depositTest", assets));
        (uint256 shares, uint256 assetsSpent) = abi.decode(result, (uint256, uint256));

        uint256 poolBalanceAfter = poolManager.balanceOf(address(this), currency.toId());

        assertLt(assetsSpent, assets, "assets");
        assertLe(shares, preview, "preview");
        assertEq(shares, vault.previewDeposit(assetsSpent), "shares");
        assertEq(poolBalanceAfter, poolBalanceBefore - assetsSpent, "poolBalanceAfter");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 WITHDRAW CLAIM TOKENS TESTS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_WithdrawClaimTokens_HappyPath() public {
        // First deposit some tokens to the vault so we can withdraw
        uint256 initialDeposit = 22121280;
        asset.approve(address(vault), initialDeposit);
        vault.deposit(initialDeposit, address(this));

        uint256 assets = 894329;

        uint256 preview = vault.previewWithdraw(assets);

        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency.toId());

        bytes memory result = poolManager.unlock(abi.encode("withdrawTest", assets));
        (uint256 shares, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        uint256 poolBalanceAfter = poolManager.balanceOf(address(this), currency.toId());

        assertEq(shares, preview, "shares");
        assertEq(assetsWithdrawn, assets, "assetsWithdrawn");
        assertEq(poolBalanceAfter, poolBalanceBefore + assetsWithdrawn, "poolBalanceAfter");
    }

    function testFuzz_WithdrawClaimTokens_HappyPath(uint256 assets) public {
        // Arrange: seed vault with shares owned by this contract
        uint256 initialDeposit = 22121280;
        asset.approve(address(vault), initialDeposit);
        vault.deposit(initialDeposit, address(this));

        assets = bound(assets, 0, vault.previewRedeem(vault.balanceOf(address(this))));

        uint256 preview = vault.previewWithdraw(assets);

        bytes memory result = poolManager.unlock(abi.encode("withdrawTest", assets));
        (uint256 shares, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        assertEq(shares, preview, "shares");
        assertEq(assetsWithdrawn, assets, "assetsWithdrawn");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   REDEEM CLAIM TOKENS TESTS                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_RedeemClaimTokens_HappyPath() public {
        // Arrange: seed vault with shares owned by this contract
        uint256 depositAssets = 400 ether;
        asset.approve(address(vault), depositAssets);
        uint256 mintedShares = vault.deposit(depositAssets, address(this));
        uint256 sharesToRedeem = mintedShares / 2;
        uint256 expectedAssets = vault.previewRedeem(sharesToRedeem);
        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency.toId());

        // Act
        bytes memory result = poolManager.unlock(abi.encode("redeemTest", sharesToRedeem));
        (uint256 sharesRedeemed, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        // Assert
        uint256 poolBalanceAfter = poolManager.balanceOf(address(this), currency.toId());
        assertEq(sharesRedeemed, sharesToRedeem, "sharesRedeemed");
        assertEq(assetsWithdrawn, expectedAssets, "assetsWithdrawn");
        assertEq(poolBalanceAfter, poolBalanceBefore + assetsWithdrawn, "poolBalanceAfter");
        assertEq(vault.balanceOf(address(this)), mintedShares - sharesRedeemed, "vault share balance");
    }

    function testFuzz_RedeemClaimTokens_HappyPath(uint256 shares) public {
        // Arrange: seed vault with shares owned by this contract
        uint256 depositAssets = 400 ether;
        asset.approve(address(vault), depositAssets);
        vault.deposit(depositAssets, address(this));
        asset.transfer(address(vault), depositAssets / 12); // Donate

        shares = bound(shares, 0, vault.balanceOf(address(this)));

        uint256 preview = vault.previewRedeem(shares);

        bytes memory result = poolManager.unlock(abi.encode("redeemTest", shares));
        (uint256 sharesRedeemed, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        assertEq(sharesRedeemed, shares, "shares");
        assertEq(assetsWithdrawn, preview, "assetsWithdrawn");
    }

    function test_RedeemClaimTokens_ReturnsZeroWhenSharesZero() public {
        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency.toId());

        bytes memory result = poolManager.unlock(abi.encode("redeemTest", uint256(0)));
        (uint256 sharesRedeemed, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        assertEq(sharesRedeemed, 0, "sharesRedeemed");
        assertEq(assetsWithdrawn, 0, "assetsWithdrawn");
        assertEq(poolManager.balanceOf(address(this), currency.toId()), poolBalanceBefore, "poolBalance");
    }

    function test_RedeemClaimTokens_RevertWhenRedeemingMoreThanBalance() public {
        uint256 depositAssets = 50 ether;
        asset.approve(address(vault), depositAssets);
        vault.deposit(depositAssets, address(this));

        // Arrange
        MockMaliciousERC4626 maliciousVault = new MockMaliciousERC4626(ERC20(address(asset)), true);
        vm.etch(address(vault), address(maliciousVault).code);
        MockMaliciousERC4626(address(vault)).setUpAttack(true, address(0xbad));

        // Act & Assert
        vm.expectRevert(Errors.Rehypothecation_VaultRedeemMoreThanRequested.selector);
        poolManager.unlock(abi.encode("redeemTest", 123456789));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      NESTED SYNC TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_WithdrawClaimTokens_WhenVaultSyncsSameCurrency() public {
        uint256 initialDeposit = 40 ether;
        _seedResyncingVault(initialDeposit);

        uint256 assets = 7 ether;
        uint256 preview = resyncingVault.previewWithdraw(assets);
        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency.toId());

        bytes memory result = poolManager.unlock(abi.encode("withdrawResync", assets));
        (uint256 shares, uint256 assetsWithdrawn) = abi.decode(result, (uint256, uint256));

        assertEq(shares, preview, "shares");
        assertEq(assetsWithdrawn, assets, "a vault's own sync must not void the credit");
        assertEq(
            poolManager.balanceOf(address(this), currency.toId()), poolBalanceBefore + assets, "claim tokens minted"
        );
        assertEq(asset.balanceOf(address(this)), 0, "no assets left behind in the hook");
    }

    function test_RedeemClaimTokens_WhenVaultSyncsSameCurrency() public {
        uint256 initialDeposit = 40 ether;
        _seedResyncingVault(initialDeposit);

        uint256 shares = 9 ether;
        uint256 preview = resyncingVault.previewRedeem(shares);
        uint256 poolBalanceBefore = poolManager.balanceOf(address(this), currency.toId());

        bytes memory result = poolManager.unlock(abi.encode("redeemResync", shares));
        (uint256 sharesRedeemed, uint256 assets) = abi.decode(result, (uint256, uint256));

        assertEq(sharesRedeemed, shares, "sharesRedeemed");
        assertEq(assets, preview, "a vault's own sync must not void the credit");
        assertEq(
            poolManager.balanceOf(address(this), currency.toId()), poolBalanceBefore + preview, "claim tokens minted"
        );
        assertEq(asset.balanceOf(address(this)), 0, "no assets left behind in the hook");
    }

    function _seedResyncingVault(uint256 assets) internal {
        resyncingVault = new MockResyncingERC4626(ERC20(address(asset)), false, address(0xcafe), poolManager);
        asset.approve(address(resyncingVault), assets);
        resyncingVault.deposit(assets, address(this));
        asset.transfer(bob, asset.balanceOf(address(this)));
    }
}
