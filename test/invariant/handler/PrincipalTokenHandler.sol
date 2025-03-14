// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {Helpers} from "../../shared/Helpers.sol";
import "../../Property.sol" as Property;

import {LibPRNG} from "solady/src/utils/LibPRNG.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {BaseHandler} from "./BaseHandler.sol";
import {HookData} from "./HookActor.sol";
import {Ghost} from "../Ghost.sol";

import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";

import "src/Types.sol";
import {Errors} from "src/Errors.sol";
import "src/Constants.sol" as Constants;
import {Casting} from "src/utils/Casting.sol";
import {LibExpiry} from "src/utils/LibExpiry.sol";

import {IRewardProxy} from "src/interfaces/IRewardProxy.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {AccessManager} from "src/modules/AccessManager.sol";

contract PrincipalTokenHandler is BaseHandler, StdAssertions, Helpers {
    using Casting for *;

    PrincipalToken s_pt;
    YieldToken s_yt;
    MockERC4626 s_target;
    MockERC20 s_asset;
    address[] s_rewardTokens;
    address s_curatorFeeReceiver = makeAddr("CuratorFeeReceiver");

    bytes32 constant EMPTY_HOOK_HASH = keccak256(abi.encode(HookData({target: address(0), value: 0, data: ""})));

    constructor(Ghost _ghost, PrincipalToken _t) {
        s_ghost = _ghost;
        s_pt = _t;
        s_yt = _t.i_yt();
        s_target = MockERC4626(_t.underlying());
        s_asset = MockERC20(_t.i_asset().asAddr());
        s_rewardTokens = IRewardProxy(_t.i_factory().moduleFor(address(_t), REWARD_PROXY_MODULE_INDEX)).rewardTokens();
    }

    /// @notice `sender` supplies `shares` of underlying token and issues PTs and YTs to `receiver`
    /// @notice The vault's generated yield is `yield` and `timeJump` passed since the last update
    function supply(address sender, uint256 shares, address receiver, int256 yield, uint256 timeJump)
        public
        useSender(sender)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("supply")
    {
        _handleSupply(shares, receiver, HookData({target: address(0), value: 0, data: ""}));
    }

    function supplyWithHook(
        uint256 hookActorSeed,
        uint256 shares,
        address receiver,
        int256 yield,
        uint256 timeJump,
        HookData memory hook
    )
        public
        useHookActor(hookActorSeed)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("supplyWithHook")
    {
        _handleSupply(shares, receiver, hook);
    }

    function _handleSupply(uint256 shares, address receiver, HookData memory hook) internal {
        // Precondition
        uint256 max = s_pt.maxIssue(s_currentSender);
        shares = _bound(shares, 0, FixedPointMathLib.min(max, 1e8 * 10 ** s_target.decimals()));

        // Need to check expiry
        if (LibExpiry.isExpired(s_pt)) {
            assertEq(s_pt.previewSupply(shares), 0, Property.T21_PREVIEW_SUPPLY);
            vm.expectRevert(Errors.Expired.selector);
            s_pt.supply(shares, receiver);
            return;
        }

        uint256 assets = s_target.previewMint(shares);
        s_asset.mint(s_currentSender, assets);

        s_asset.approve(address(s_target), assets);
        s_target.mint(shares, s_currentSender);

        // Execute and assert
        _supply(shares, receiver, hook);
    }

    function issue(address sender, uint256 principal, address receiver, int256 yield, uint256 timeJump)
        public
        useSender(sender)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("issue")
    {
        _handleIssue(principal, receiver, HookData({target: address(0), value: 0, data: ""}));
    }

    function issueWithHook(
        uint256 hookActorSeed,
        uint256 principal,
        address receiver,
        int256 yield,
        uint256 timeJump,
        HookData memory hook
    )
        public
        useHookActor(hookActorSeed)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("issueWithHook")
    {
        _handleIssue(principal, receiver, hook);
    }

    function _handleIssue(uint256 principal, address receiver, HookData memory hook) internal {
        // Precondition
        uint256 max = s_pt.maxIssue(s_currentSender);
        principal = _bound(principal, 0, FixedPointMathLib.min(max, 1e8 * 10 ** s_pt.decimals()));

        if (LibExpiry.isExpired(s_pt)) {
            assertEq(s_pt.previewIssue(principal), 0, Property.T22_PREVIEW_ISSUE);
            vm.expectRevert(Errors.Expired.selector);
            s_pt.issue(principal, receiver);
            return;
        }

        uint256 preview = s_pt.previewIssue(principal);

        uint256 assets = s_target.previewMint(preview);
        s_asset.mint(s_currentSender, assets);

        s_asset.approve(address(s_target), assets);
        s_target.mint(preview, s_currentSender);

        // Execute and assert
        _issue(principal, receiver, hook);
    }

    function redeem(
        address sender,
        uint256 ownerSeed,
        uint256 principal,
        address receiver,
        int256 yield,
        uint256 timeJump
    )
        public
        useSender(sender)
        useFuzzedFrom(ownerSeed)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("redeem")
    {
        uint256 maxPrincipal = s_pt.balanceOf(s_currentFrom);
        principal = _bound(principal, 0, maxPrincipal);

        if (LibExpiry.isNotExpired(s_pt)) {
            assertEq(s_pt.previewRedeem(principal), 0, Property.T23_PREVIEW_REDEEM);
            vm.expectRevert(Errors.NotExpired.selector);
            s_pt.redeem(principal, receiver, s_currentFrom);
            return;
        }

        _redeem(principal, receiver, s_currentFrom);
    }

    function _redeem(uint256 principal, address receiver, address owner)
        internal
        updateGhost(owner)
        // Note userIndex doesn't change in redeem because YT balance doesn't change
        // assertUserIndexInvariant(owner)
        assertAccumulatorInvariant
        returns (uint256 actual)
    {
        uint256 preUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 preOwnerBalance = s_pt.balanceOf(owner);
        uint256 preview = s_pt.previewRedeem(principal);

        address sender = s_currentSender;
        if (owner != sender) {
            changePrank(owner, owner);
            s_pt.approve(sender, type(uint256).max);
            changePrank(sender, sender);
        }

        actual = s_pt.redeem(principal, receiver, owner);

        uint256 postUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 postOwnerBalance = s_pt.balanceOf(owner);

        assertGe(actual, preview, Property.T13_REDEEM);

        assertEq(preUnderlyingBalance - actual, postUnderlyingBalance, "Underlying balance change incorrect");
        assertEq(preOwnerBalance - principal, postOwnerBalance, "PT balance change incorrect");
    }

    function withdraw(
        address sender,
        uint256 ownerSeed,
        uint256 shares,
        address receiver,
        int256 yield,
        uint256 timeJump
    )
        public
        useSender(sender)
        useFuzzedFrom(ownerSeed)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("withdraw")
    {
        uint256 maxShares = s_pt.previewRedeem(s_pt.balanceOf(s_currentFrom));
        shares = _bound(shares, 0, maxShares);

        // Need to check expiry before executing and asserting
        if (LibExpiry.isNotExpired(s_pt)) {
            assertEq(s_pt.previewWithdraw(shares), 0, Property.T24_PREVIEW_WITHDRAW);
            vm.expectRevert(Errors.NotExpired.selector);
            s_pt.withdraw(shares, receiver, s_currentFrom);
            return;
        }

        _withdraw(shares, receiver, s_currentFrom);
    }

    function _withdraw(uint256 shares, address receiver, address owner)
        internal
        updateGhost(owner)
        // Note userIndex doesn't change in withdraw because YT balance doesn't change
        // assertUserIndexInvariant(owner)
        assertAccumulatorInvariant
        returns (uint256 actual)
    {
        uint256 preUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 preOwnerBalance = s_pt.balanceOf(owner);
        uint256 preview = s_pt.previewWithdraw(shares);

        address sender = s_currentSender;
        if (owner != sender) {
            changePrank(owner, owner);
            s_pt.approve(sender, type(uint256).max);
            changePrank(sender, sender);
        }
        actual = s_pt.withdraw(shares, receiver, owner);

        uint256 postUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 postOwnerBalance = s_pt.balanceOf(owner);

        assertLe(actual, preview, Property.T12_WITHDRAW);

        // If `receiver` is PrincipalToken, the assertion will fail.
        assertEq(preUnderlyingBalance - shares, postUnderlyingBalance, "Underlying balance change incorrect");

        assertEq(preOwnerBalance - actual, postOwnerBalance, "PT balance change incorrect");
    }

    function combine(uint256 ownerSeed, uint256 principal, address receiver, int256 yield, uint256 timeJump)
        public
        useFuzzedFrom(ownerSeed)
        useSender(s_currentFrom)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("combine")
    {
        _handleCombine(principal, receiver, HookData({target: address(0), value: 0, data: ""}));
    }

    function combineWithHook(
        uint256 hookActorSeed,
        uint256 principal,
        address receiver,
        int256 yield,
        uint256 timeJump,
        HookData memory hook
    )
        public
        useFuzzedHookActor(hookActorSeed)
        useFrom(s_currentSender)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("combineWithHook")
    {
        _handleCombine(principal, receiver, hook);
    }

    function _handleCombine(uint256 principal, address receiver, HookData memory hook) internal {
        // Precondition
        uint256 max = FixedPointMathLib.min(s_yt.balanceOf(s_currentFrom), s_pt.balanceOf(s_currentFrom));
        principal = _bound(principal, 0, max);

        // Execute and assert
        _combine(principal, receiver, hook);
    }

    function unite(uint256 ownerSeed, uint256 shares, address receiver, int256 yield, uint256 timeJump)
        public
        useFuzzedFrom(ownerSeed)
        useSender(s_currentFrom)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("unite")
    {
        _handleUnite(shares, receiver, HookData({target: address(0), value: 0, data: ""}));
    }

    function uniteWithHook(
        uint256 hookActorSeed,
        uint256 shares,
        address receiver,
        int256 yield,
        uint256 timeJump,
        HookData memory hook
    )
        public
        useFuzzedHookActor(hookActorSeed)
        useFrom(s_currentSender)
        checkActor(receiver)
        changeVaultSharePrice(yield)
        skipTime(timeJump)
        countCall("uniteWithHook")
    {
        _handleUnite(shares, receiver, hook);
    }

    function _handleUnite(uint256 shares, address receiver, HookData memory hook) internal returns (uint256 actual) {
        // Precondition
        uint256 max = FixedPointMathLib.min(s_yt.balanceOf(s_currentFrom), s_pt.balanceOf(s_currentFrom));
        shares = _bound(shares, 0, s_pt.previewCombine(max));

        // Execute and assert
        actual = _unite(shares, receiver, hook);
    }

    function collect(address sender, uint256 ownerSeed, address receiver, int256 yield, uint256 timeJump)
        public
        useSender(sender)
        useFuzzedFrom(ownerSeed)
        checkActor(receiver)
        changeVaultSharePrice(yield)
        skipTime(timeJump)
        countCall("collect")
    {
        _collect({owner: s_currentFrom, receiver: receiver});
    }

    /// @dev Stack too deep error workaround
    function _collect(address owner, address receiver)
        internal
        updateGhost(owner)
        assertAccumulatorInvariant
        assertUserIndexInvariant(owner)
    {
        address sender = s_currentSender;
        uint256 random = _bound(block.timestamp, 0, type(uint256).max);
        // 50% chance `setApprovalCollector` even if `owner` is `sender`
        if (random % 2 == 0 || owner != sender) {
            changePrank(owner, owner);
            s_pt.setApprovalCollector(sender, true);
            changePrank(sender, sender);
        }
        uint256 preview = s_pt.previewCollect(owner);
        (uint256 shares,) = s_pt.collect({owner: owner, receiver: receiver});

        // Assert
        assertEq(shares, preview, Property.T16_COLLECT);
        assertEq(s_pt.getUserYield(owner).accrued, 0, "Zeroed out");
        for (uint256 i = 0; i < s_rewardTokens.length; i++) {
            assertEq(s_pt.getUserReward({owner: owner, reward: s_rewardTokens[i]}).accrued, 0, "Zeroed out");
        }
    }

    function yt_transfer(
        address sender,
        uint256 ownerSeed,
        address receiver,
        uint256 value,
        int256 yield,
        uint256 timeJump
    )
        public
        useSender(sender)
        useFuzzedFrom(ownerSeed)
        checkActor(receiver)
        skipTime(timeJump)
        changeVaultSharePrice(yield)
        countCall("yt_transfer")
    {
        value = _bound(value, 0, s_yt.balanceOf(s_currentFrom));
        _yt_transfer({owner: s_currentFrom, receiver: receiver, value: value});
    }

    /// @dev Stack too deep error workaround
    function _yt_transfer(address owner, address receiver, uint256 value)
        internal
        updateGhost(owner)
        updateGhost(receiver) // Both owner and receiver states are updated
        assertUserIndexInvariant(owner)
        assertUserIndexInvariant(receiver)
        assertAccumulatorInvariant
    {
        address sender = s_currentSender;
        uint256 random = _bound(uint256(keccak256(abi.encode(block.timestamp))), 0, type(uint256).max);
        // 50% chance `transferFrom` even if `sender` is `owner`
        if ((random % 2 == 0 && owner == sender) || owner != sender) {
            changePrank(owner, owner);
            s_yt.approve(sender, value);
            changePrank(sender, sender);
            s_yt.transferFrom(owner, receiver, value);
        } else {
            s_yt.transfer(receiver, value);
        }
    }

    function updateFeeParams(FeePcts value) public countCall("updateFee") {
        address feeModule = s_pt.i_factory().moduleFor(address(s_pt), FEE_MODULE_INDEX);
        FeePcts v = boundFeePcts(value);
        setMockFeePcts(feeModule, v);
    }

    function collectCuratorFees(address[] memory additionalTokens, address feeCollector)
        public
        useFeeCollectorRole(s_pt.i_accessManager(), feeCollector, s_pt.collectCuratorFees.selector)
        countCall("collectCuratorFees")
    {
        (uint256 fees,) = s_pt.getFees();
        if (fees == 0) return; // If no fees, revert with underflow
        s_pt.collectCuratorFees(additionalTokens, s_curatorFeeReceiver);
    }

    function collectProtocolFees(address[] memory additionalTokens, address feeCollector)
        public
        useFeeCollectorRole(s_pt.i_factory().i_accessManager(), feeCollector, s_pt.collectProtocolFees.selector)
        countCall("collectProtocolFees")
    {
        (, uint256 fees) = s_pt.getFees();
        if (fees == 0) return; // If no fees, revert with underflow
        s_pt.collectProtocolFees(additionalTokens);
    }

    modifier useFeeCollectorRole(AccessManager accessManager, address feeCollector, bytes4 selector) {
        if (feeCollector == address(0) || feeCollector == address(s_pt) || feeCollector == address(this)) return;
        vm.startPrank(accessManager.owner());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        accessManager.grantRoles(feeCollector, Constants.FEE_COLLECTOR_ROLE);
        accessManager.grantTargetFunctionRoles(address(s_pt), selectors, Constants.FEE_COLLECTOR_ROLE);
        s_currentSender = feeCollector;
        changePrank(feeCollector, feeCollector);
        _;
        vm.stopPrank();
    }

    function _supply(uint256 shares, address receiver, HookData memory hook)
        internal
        updateGhost(receiver)
        assertUserIndexInvariant(receiver)
        assertAccumulatorInvariant
        returns (uint256 actual)
    {
        // Prepare
        s_target.approve(s_pt.asAddr(), shares);

        uint256 preUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 preview = s_pt.previewSupply(shares);

        actual = _isHookEmpty(hook) ? s_pt.supply(shares, receiver) : s_pt.supply(shares, receiver, abi.encode(hook));

        // Assert - Function-level property
        uint256 postUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        assertGe(actual, preview, Property.T10_SUPPLY);
        assertEq(
            postUnderlyingBalance,
            preUnderlyingBalance + shares,
            "Underlying balance is not equal to the sum of pre-supply and shares"
        );
    }

    function _issue(uint256 principal, address receiver, HookData memory hook)
        internal
        updateGhost(receiver)
        assertUserIndexInvariant(receiver)
        assertAccumulatorInvariant
        returns (uint256 actual)
    {
        // Prepare

        uint256 preUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 preview = s_pt.previewIssue(principal);

        s_target.approve(s_pt.asAddr(), preview);

        actual =
            _isHookEmpty(hook) ? s_pt.issue(principal, receiver) : s_pt.issue(principal, receiver, abi.encode(hook));

        // Assert - Function-level property
        uint256 postUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        assertLe(actual, preview, Property.T11_ISSUE);
        assertEq(
            postUnderlyingBalance,
            preUnderlyingBalance + actual,
            "Underlying balance is not equal to the sum of pre-issue and shares"
        );
    }

    function _combine(uint256 principal, address receiver, HookData memory hook)
        internal
        updateGhost(s_currentSender)
        assertUserIndexInvariant(s_currentSender)
        assertAccumulatorInvariant
        returns (uint256 actual)
    {
        // Prepare

        uint256 preUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 preview = s_pt.previewCombine(principal);

        // Execute
        actual =
            _isHookEmpty(hook) ? s_pt.combine(principal, receiver) : s_pt.combine(principal, receiver, abi.encode(hook));

        // Assert - Function-level property
        uint256 postUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        assertGe(actual, preview, Property.T15_COMBINE);
        assertEq(
            postUnderlyingBalance,
            preUnderlyingBalance - actual,
            "Underlying balance is not equal to the sum of pre-combine and shares"
        );
    }

    function _unite(uint256 shares, address receiver, HookData memory hook)
        internal
        updateGhost(s_currentSender)
        assertUserIndexInvariant(s_currentSender)
        assertAccumulatorInvariant
        returns (uint256 actual)
    {
        // Prepare

        uint256 preUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        uint256 preview = s_pt.previewUnite(shares);

        // Execute
        actual = _isHookEmpty(hook) ? s_pt.unite(shares, receiver) : s_pt.unite(shares, receiver, abi.encode(hook));

        // Assert - Function-level property
        uint256 postUnderlyingBalance = s_target.balanceOf(s_pt.asAddr());
        assertLe(actual, preview, Property.T14_UNITE);
        assertEq(
            postUnderlyingBalance,
            preUnderlyingBalance - shares,
            "Underlying balance is not equal to the sum of pre-unite and shares"
        );
    }

    modifier changeVaultSharePrice(int256 yield) {
        // If the target is not minted, it should not produce any interest in theory.
        // Negative yield is at most 10% of the balance of the underlying token.
        if (yield > 0) yield = _bound(yield, 0, int256(s_asset.balanceOf(address(s_target)) * 30 / 100));
        if (yield < 0) yield = _bound(yield, -int256(s_asset.balanceOf(address(s_target)) * 10 / 100), 0);
        if (s_target.totalSupply() == 0) yield = 0;

        // Underlying token share price increases or decreases.
        if (yield > 0) {
            s_asset.mint(address(s_target), uint256(yield));
        } else {
            s_asset.burn(address(s_target), uint256(-yield));
        }
        _;
    }

    modifier updateGhost(address user) {
        _;

        // User specific
        s_ghost.add_receiver(user);
        // Hook actor
        s_ghost.add_fuzzed_hook_actor(user);

        // Global
        // TODO
    }

    /// @dev User-specific invariant check on YT balance change
    modifier assertUserIndexInvariant(address user) {
        _;

        for (uint256 i = 0; i < s_rewardTokens.length; i++) {
            uint256 rewardIndex = s_pt.getRewardGlobalIndex(s_rewardTokens[i]).unwrap();
            assertEq(
                rewardIndex,
                s_pt.getUserReward({owner: user, reward: s_rewardTokens[i]}).userIndex.unwrap(),
                "Reward index mismatch"
            );
        }
        assertEq(
            s_pt.getSnapshot().globalIndex.unwrap(), s_pt.getUserYield(user).userIndex.unwrap(), "Yield index mismatch"
        );
    }

    /// @dev Global accumulator invariant check on YT balance change
    modifier assertAccumulatorInvariant() {
        uint256[] memory indexesBefore = new uint256[](s_rewardTokens.length);
        for (uint256 i = 0; i < s_rewardTokens.length; i++) {
            indexesBefore[i] = s_pt.getRewardGlobalIndex(s_rewardTokens[i]).unwrap();
        }
        uint256 beforeYieldIndex = s_pt.getSnapshot().globalIndex.unwrap();

        _;

        for (uint256 i = 0; i < s_rewardTokens.length; i++) {
            uint256 rewardIndex = s_pt.getRewardGlobalIndex(s_rewardTokens[i]).unwrap();
            assertGe(rewardIndex, indexesBefore[i], Property.T09_REWARD_INDEX);
        }
        assertGe(s_pt.getSnapshot().globalIndex.unwrap(), beforeYieldIndex, Property.T04_YIELD_INDEX);
    }

    /// @dev Uniformly samples a value within the given range because forge-std's bound() biases to the larger values or zero.
    function _bound(uint256 x, uint256 min, uint256 max) internal pure override returns (uint256 result) {
        if (min <= x && x <= max) return x;
        LibPRNG.PRNG memory prng;
        LibPRNG.seed(prng, x);
        result = LibPRNG.uniform(prng, max - min) + min;
    }

    function _isHookEmpty(HookData memory hook) internal pure returns (bool) {
        return keccak256(abi.encode(hook)) == EMPTY_HOOK_HASH;
    }

    function callSummary() public view override {
        console2.log("['supply'] :>>", s_calls["supply"]);
        console2.log("['issue'] :>>", s_calls["issue"]);
        console2.log("['redeem'] :>>", s_calls["redeem"]);
        console2.log("['withdraw'] :>>", s_calls["withdraw"]);
        console2.log("['combine'] :>>", s_calls["combine"]);
        console2.log("['unite'] :>>", s_calls["unite"]);
        console2.log("['collect'] :>>", s_calls["collect"]);
        console2.log("['updateFee'] :>>", s_calls["updateFee"]);
        console2.log("['yt_transfer'] :>>", s_calls["yt_transfer"]);
        console2.log("['supplyWithHook'] :>>", s_calls["supplyWithHook"]);
        console2.log("['issueWithHook'] :>>", s_calls["issueWithHook"]);
        console2.log("['combineWithHook'] :>>", s_calls["combineWithHook"]);
        console2.log("['uniteWithHook'] :>>", s_calls["uniteWithHook"]);
        console2.log("['collectCuratorFees'] :>>", s_calls["collectCuratorFees"]);
        console2.log("['collectProtocolFees'] :>>", s_calls["collectProtocolFees"]);
    }
}
