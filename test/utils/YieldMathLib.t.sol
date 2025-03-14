// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import "../Property.sol" as Property;

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockResolver} from "../mocks/MockResolver.sol";

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {Snapshot, Yield, YieldIndex, YieldMathLib} from "src/utils/YieldMathLib.sol";

contract YieldMathLibTest is Test {
    uint256 s_cscale;

    function scale() public view returns (uint256) {
        return s_cscale;
    }

    function test_CalcYield() public pure {
        assertEq(YieldMathLib.calcYield(1.1e18, 0.9e18, 121e18), 0, "Negative yield should generate 0 yield");
        assertEq(YieldMathLib.calcYield(10e18, 11e18, 0), 0, "Zero Supply should generate 0 yield");
        assertEq(YieldMathLib.calcYield(1e18, 2e18, 20e18), 10e18, "2x scale with 20 YTs should generate 10 yield");
    }

    function testFuzz_UpdateIndex(
        Snapshot memory s,
        uint128 cscale,
        uint256 ptSupply,
        uint256 ytSupply,
        uint256 feePctBps
    ) public {
        s.globalIndex = YieldIndex.wrap(uint128(bound(s.globalIndex.unwrap(), 0, 10_000e18)));
        s.maxscale = uint128(bound(s.maxscale, 0, 1_000e18));
        s_cscale = bound(cscale, 0, s.maxscale * 100);
        ytSupply = bound(ytSupply, 0, 100_000e18);
        ptSupply = bound(ptSupply, 0, ytSupply); // PT supply should be less than YT supply because PT is burnt after expiry
        feePctBps = bound(feePctBps, 0, YieldMathLib.BASIS_POINTS);

        bool firstAccrual = s.maxscale == 0;
        uint256 newMaxscale = s_cscale > s.maxscale ? s_cscale : s.maxscale;
        YieldIndex oldIndex = s.globalIndex;

        (uint256 totalAccrued, uint256 fee) = YieldMathLib.updateIndex(s, this.scale, ptSupply, ytSupply, feePctBps);

        YieldIndex newIndex = s.globalIndex;

        assertGe(newIndex.unwrap(), oldIndex.unwrap(), Property.T04_YIELD_INDEX);
        assertEq(s.maxscale, newMaxscale, "Previous maxscale should be updated");

        if (ptSupply == 0) assertEq(newIndex.unwrap(), oldIndex.unwrap(), "Index should not change when supply is 0");

        if (firstAccrual) {
            assertEq(totalAccrued, 0, "Total accrued should be 0 on first accrual");
            assertEq(fee, 0, "Fee should be 0 on first accrual");
        }
    }

    // Round trip of conversion functions
    // Open bound
    function testFuzz_RP_ConvertToUnderlying(uint256 shares, uint256 maxscale) public view {
        (bool s, bytes memory ret) = address(this).staticcall(
            abi.encodeWithSelector(this.prop_RP_ConvertToUnderlying.selector, shares, maxscale)
        );
        vm.assume(s);
        uint256 result = abi.decode(ret, (uint256));
        assertLe(result, shares, "should be rounded down against users");
    }

    function prop_RP_ConvertToUnderlying(uint256 shares, uint256 maxscale) public pure returns (uint256) {
        return
            YieldMathLib.convertToUnderlying(YieldMathLib.convertToPrincipal(shares, maxscale, false), maxscale, false);
    }

    function testFuzz_RP_ConvertToPrincipal(uint256 principal, uint256 maxscale) public view {
        (bool s, bytes memory ret) = address(this).staticcall(
            abi.encodeWithSelector(this.prop_RP_ConvertToPrincipal.selector, principal, maxscale)
        );
        vm.assume(s);
        uint256 result = abi.decode(ret, (uint256));
        assertLe(result, principal, "should be rounded down against users");
    }

    function prop_RP_ConvertToPrincipal(uint256 principal, uint256 maxscale) public pure returns (uint256) {
        return YieldMathLib.convertToPrincipal(
            YieldMathLib.convertToUnderlying(principal, maxscale, false), maxscale, false
        );
    }
}

contract YieldMathLibInvariantTest is Test {
    BalanceSum s_balanceSum;
    address[] s_users;

    function setUp() public {
        s_users.push(makeAddr("naruto"));
        s_users.push(makeAddr("sasuke"));
        s_users.push(makeAddr("kakashi"));
        s_users.push(makeAddr("guysensei"));

        s_balanceSum = new BalanceSum(s_users);

        targetContract(address(s_balanceSum));

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = BalanceSum.issue.selector;
        selectors[1] = BalanceSum.redeem.selector;
        selectors[2] = BalanceSum.claim.selector;
        FuzzSelector memory p = FuzzSelector({addr: address(s_balanceSum), selectors: selectors});
        targetSelector(p);
    }

    function invariant_Solvency() public {
        uint256 id = vm.snapshot();
        assertLe(
            s_balanceSum.s_ptSupply(), s_balanceSum.s_ytSupply(), "PT supply should be less than or equal to YT supply"
        );
        // Claim unclaimed yield for all users to make sure the invariant holds
        for (uint256 i = 0; i < s_users.length; i++) {
            s_balanceSum.claim(i, 0, 0);
        }
        assertGe(
            s_balanceSum.s_underlyingDeposits(),
            s_balanceSum.ghost_sum(),
            "Total underlying deposits should be greater than or equal to total claimable and redeemable"
        );
        vm.revertTo(id);
    }

    function invariant_CallSummary() public view {
        s_balanceSum.callSummary();
    }
}

contract BalanceSum is StdUtils, StdCheats, StdAssertions, TestBase {
    using YieldMathLib for *;

    address[] s_users;
    mapping(address => uint256) s_principals;
    mapping(address => uint256) s_yts;
    uint256 public s_ptSupply;
    uint256 public s_ytSupply;
    uint256 public s_underlyingDeposits;
    Snapshot s_snapshot;
    mapping(address => Yield) s_userAccruals;

    // Ghost variables
    uint256 public ghost_sum; // Total claimable and redeemable yield of all users
    mapping(address => uint256) ghost_claimableYields; // yield to be claimed by user
    mapping(bytes4 => uint256) ghost_calls;

    // Setup
    uint256 s_expiry;
    MockERC20 s_asset;
    MockERC4626 s_vault;
    MockResolver s_resolver;
    address alice = makeAddr("alice");

    event Issue(address user, uint256 principals, uint256 shares);
    event Redeem(address user, uint256 principals, uint256 shares);
    event Claim(address user, uint256 shares);
    event UserSummary(address user, uint256 accrued, uint256 claimable, uint256 redeemable);

    constructor(address[] memory users) {
        s_users = users;
        s_expiry = block.timestamp + 100 days;
        s_asset = new MockERC20(18);
        s_vault = new MockERC4626(s_asset, true);
        s_resolver = new MockResolver(address(s_vault));

        // setup vault
        vm.startPrank(alice);
        s_asset.mint(alice, 1e18);
        s_asset.approve(address(s_vault), type(uint256).max);
        s_vault.deposit(1e18, alice);
        vm.stopPrank();
    }

    /// @notice Issue `principals` of PT/YT to user `index` and the vault gets `yield` of the underlying token since the last index update.
    function issue(uint256 index, uint256 principals, int256 yield, uint256 timeJump) public incrementCallCount {
        if (block.timestamp >= s_expiry) return; // skip if expiry is reached

        // Prepare
        timeJump = _bound(timeJump, 0, 1 days);
        vm.warp(block.timestamp + timeJump);

        index = index % s_users.length;
        address user = s_users[index];

        principals = _bound(principals, 0, 10_000e18);

        yield = _boundYield(yield);
        _changeVaultPrice(yield);

        Snapshot memory sn = s_snapshot;

        // Execute
        (uint256 totalAccrued,) = YieldMathLib.updateIndex({
            self: sn,
            scaleFn: s_resolver.scale,
            ptSupply: s_ptSupply,
            ytSupply: s_ytSupply,
            feePctBps: 0
        });

        uint256 shares = YieldMathLib.convertToUnderlying(principals, sn.maxscale, true);

        // Update ghost variables
        _updateGhostClaimableYields(totalAccrued);

        // Update state variables
        YieldMathLib.accrueUserYield({
            self: s_userAccruals,
            index: sn.globalIndex,
            account: user,
            ytBalance: s_yts[user]
        });

        uint256 claimable = s_userAccruals[user].accrued;
        uint256 expected = ghost_claimableYields[user];
        assertLe(claimable, expected, "Claimable yield");

        s_snapshot = sn;
        s_underlyingDeposits += shares;
        s_ptSupply += principals;
        s_principals[user] += principals;
        s_ytSupply += principals;
        s_yts[user] += principals;

        emit Issue(user, principals, shares);

        _updateGhostSum();
    }

    /// @notice Redeem `principals` of PT of user `index` and the vault gets `yield` of the underlying token since the last index update.
    function redeem(uint256 index, uint256 principals, int256 yield, uint256 timeJump) public incrementCallCount {
        // Skip if expiry is not reached
        if (block.timestamp < s_expiry) return;

        // Prepare
        timeJump = _bound(timeJump, 0, 1 days);
        vm.warp(block.timestamp + timeJump);

        index = index % s_users.length;
        address user = s_users[index];

        principals = _bound(principals, 0, s_principals[user]);

        yield = _boundYield(yield);
        _changeVaultPrice(yield);

        Snapshot memory sn = s_snapshot;

        // Execute
        (uint256 totalAccrued,) = YieldMathLib.updateIndex({
            self: sn,
            scaleFn: s_resolver.scale,
            ptSupply: s_ptSupply,
            ytSupply: s_ytSupply,
            feePctBps: 0
        });

        uint256 shares = YieldMathLib.convertToUnderlying(principals, sn.maxscale, false);

        // Update ghost variables
        _updateGhostClaimableYields(totalAccrued);

        // Update state variables
        // No need to update user accruals because YT balance is not changed
        // YieldMathLib.accrueUserYield({
        //     self: s_userAccruals,
        //     index: sn.globalIndex,
        //     account: user,
        //     ytBalance: s_yts[user]
        // });

        s_snapshot = sn;
        s_underlyingDeposits -= shares;
        s_ptSupply -= principals;
        s_principals[user] -= principals;
        // YT supply is not changed

        emit Redeem(user, principals, shares);
    }

    function claim(uint256 index, int256 yield, uint256 timeJump) public incrementCallCount {
        timeJump = _bound(timeJump, 0, 1 days);
        vm.warp(block.timestamp + timeJump);

        index = index % s_users.length;
        address user = s_users[index];

        yield = _boundYield(yield);
        _changeVaultPrice(yield);

        Snapshot memory sn = s_snapshot;

        // Execute
        (uint256 totalAccrued,) = YieldMathLib.updateIndex({
            self: sn,
            scaleFn: s_resolver.scale,
            ptSupply: s_ptSupply,
            ytSupply: s_ytSupply,
            feePctBps: 0
        });

        // Update ghost variables
        _updateGhostClaimableYields(totalAccrued);

        YieldMathLib.accrueUserYield({
            self: s_userAccruals,
            index: sn.globalIndex,
            account: user,
            ytBalance: s_yts[user]
        });

        uint256 claimable = s_userAccruals[user].accrued;
        uint256 expected = ghost_claimableYields[user];
        assertLe(claimable, expected, "Claimable yield");

        // Update state variables
        s_snapshot = sn;
        ghost_claimableYields[user] = 0;
        s_userAccruals[user].accrued = 0;
        s_underlyingDeposits -= claimable;

        emit Claim(user, claimable);

        _updateGhostSum();
    }

    function _boundYield(int256 yield) internal view returns (int256) {
        if (yield > 0) yield = _bound(yield, 0, int256(s_asset.balanceOf(address(s_vault)) * 30 / 100));
        if (yield < 0) yield = _bound(yield, -int256(s_asset.balanceOf(address(s_vault)) * 10 / 100), 0);
        // If the vault is empty, the yield should be 0
        if (s_vault.totalSupply() == 0) yield = 0;
        return yield;
    }

    function _changeVaultPrice(int256 yield) internal {
        if (yield > 0) s_asset.mint(address(s_vault), uint256(yield));
        else s_asset.burn(address(s_vault), uint256(-yield));
    }

    function _updateGhostClaimableYields(uint256 totalAccrued) internal {
        if (s_ytSupply == 0) return; // skip if YT supply is 0

        for (uint256 i = 0; i < s_users.length; i++) {
            address u = s_users[i];
            // Note: Rounding up is necessary. We want to compute theoretical maximum yield that can be accrued by the user.
            // If rounding down, rounding errors will be accumulated and the sum of yield may be less
            uint256 accrued = FixedPointMathLib.mulDivUp(totalAccrued, s_yts[u], s_ytSupply);
            ghost_claimableYields[u] += accrued;
        }
    }

    /// @notice Post-update state variables
    function _updateGhostSum() internal {
        Snapshot memory sp = s_snapshot;
        uint256 sum;
        for (uint256 i = 0; i < s_users.length; i++) {
            address user = s_users[i];
            uint256 accrued = s_userAccruals[user].accrued;
            uint256 redeemable = YieldMathLib.convertToUnderlying(s_principals[user], sp.maxscale, false);
            sum += accrued + redeemable;

            emit UserSummary(user, accrued, ghost_claimableYields[user], redeemable);
        }
        ghost_sum = sum;
    }

    modifier incrementCallCount() {
        ghost_calls[msg.sig]++;
        _;
    }

    function callSummary() public view {
        console2.log("issue :>>", ghost_calls[this.issue.selector]);
        console2.log("redeem :>>", ghost_calls[this.redeem.selector]);
        console2.log("claim :>>", ghost_calls[this.claim.selector]);
    }
}
