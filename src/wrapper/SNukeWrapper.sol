// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {Token, TokenReward} from "../Types.sol";
import {IWrapper} from "./IWrapper.sol";
import {Errors} from "../Errors.sol";

interface ISNuke {
    function index() external view returns (uint256);
    function gonsForBalance(uint256 amount) external view returns (uint256);
    function balanceForGons(uint256 gons) external view returns (uint256);
}

/// @notice Non-rebasing shares backed by sNUKE gons.
/// @dev Clone args: abi.encode(address sNuke, address nuke). Only sNUKE transfers are supported.
///      A share claims a fixed fraction of sNUKE gons; its token balance grows only on actual rebases.
///      Custody does not price shares, so directly donated sNUKE remains unclaimed.
///      Zero and dust amounts are accepted: conversions round down, so a dust deposit can mint shares
///      claiming zero sNUKE and a dust redemption burns shares for zero sNUKE, leaving the gons in custody.
///      Markets must price shares with `assetsPerShare()`, which releases each sNUKE rebase linearly over at least
///      one epoch. `convertToAssets` is exact and steps at every rebase, which anyone can trigger at a known time.
contract SNukeWrapper is ERC20, IWrapper, Initializable, ReentrancyGuard {
    using SafeCastLib for uint256;

    uint256 private constant SHARE_SCALE = 1e18;
    // sNUKE fixes the gons corresponding to its initial 1e9-fragment index at deployment.
    uint256 private constant INITIAL_FRAGMENTS = 5_000_000_000e9;
    uint256 private constant TOTAL_GONS = type(uint256).max - (type(uint256).max % INITIAL_FRAGMENTS);
    uint256 private constant INDEX_GONS = 1e9 * (TOTAL_GONS / INITIAL_FRAGMENTS);
    // sNUKE rebases once per 8-hour staking epoch.
    uint256 private constant MIN_VESTING_PERIOD = 8 hours;

    /// @dev `anchor <= target <= sNUKE.index()`. sNUKE caps its supply at 2^128 - 1, which bounds the index
    ///      below 6.9e28 < 2^96.
    struct IndexVesting {
        uint96 anchor;
        uint96 target;
        uint40 start;
        uint24 duration;
    }

    IndexVesting private s_indexVesting;

    error SNukeWrapper_InvalidConfiguration();
    error SNukeWrapper_InvalidRecipient();
    error SNukeWrapper_UnexpectedETH();

    function initialize() external initializer {
        (address sNuke, address nuke) = _args();
        // The index is quoted in 9-decimal NUKE units for a 9-decimal sNUKE balance.
        if (
            sNuke == address(0) || nuke == address(0) || sNuke == nuke || sNuke.code.length == 0
                || nuke.code.length == 0 || ERC20(sNuke).decimals() != 9 || ERC20(nuke).decimals() != 9
        ) {
            revert SNukeWrapper_InvalidConfiguration();
        }
        uint256 index = ISNuke(sNuke).index();
        if (index == 0 || ISNuke(sNuke).balanceForGons(INDEX_GONS) != index) {
            revert SNukeWrapper_InvalidConfiguration();
        }
        uint96 initialIndex = index.toUint96();
        s_indexVesting =
            IndexVesting({anchor: initialIndex, target: initialIndex, start: block.timestamp.toUint40(), duration: 0});
    }

    function name() public pure override returns (string memory) {
        return "Napier Wrapped sNUKE";
    }

    function symbol() public pure override returns (string memory) {
        return "nw-sNUKE";
    }

    function vault() public view returns (address sNuke) {
        (sNuke,) = _args();
    }

    function asset() public view returns (address nuke) {
        (, nuke) = _args();
    }

    function convertToAssets(uint256 shares) public view returns (uint256 assets) {
        return _toAssets(ISNuke(vault()), shares);
    }

    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        return _toShares(ISNuke(vault()), assets);
    }

    /// @notice NUKE per 1e18 shares, releasing each sNUKE index increase linearly.
    /// @dev Never exceeds `convertToAssets(1e18)` and never decreases. An index increase starts vesting at the
    ///      first share transfer or `checkpoint()` that observes it, continuing from the current value. The
    ///      remaining amount vests over the longest of one epoch, the time since the previously observed increase,
    ///      and the time left on the current release (capped at 2^24 - 1 seconds). The release rate therefore never
    ///      exceeds the rate at which yield accrued unobserved plus the rate already scheduled.
    function assetsPerShare() external view returns (uint256) {
        return _vestedIndex(s_indexVesting);
    }

    /// @notice Starts vesting an sNUKE index increase that no share transfer has observed yet.
    /// @dev Without a share transfer or checkpoint each epoch, the price lags by all yield accrued since the
    ///      last observation. Readers that pay out at the lagged price, such as a post-expiry PT redemption,
    ///      take that yield from YT holders.
    function checkpoint() external {
        _checkpoint();
    }

    function deposit(Token token, uint256 tokens, address receiver)
        external
        payable
        nonReentrant
        returns (uint256 shares)
    {
        address sNuke = vault();
        _checkToken(token, sNuke);
        if (msg.value != 0) revert SNukeWrapper_UnexpectedETH();
        _checkReceiver(receiver);

        SafeTransferLib.safeTransferFrom(sNuke, msg.sender, address(this), tokens);
        shares = _toShares(ISNuke(sNuke), tokens);
        _mint(receiver, shares);
    }

    function redeem(Token token, uint256 shares, address receiver) external nonReentrant returns (uint256 tokens) {
        address sNuke = vault();
        _checkToken(token, sNuke);
        _checkReceiver(receiver);
        tokens = _toAssets(ISNuke(sNuke), shares);
        _burn(msg.sender, shares);
        SafeTransferLib.safeTransfer(sNuke, receiver, tokens);
    }

    function previewDeposit(Token token, uint256 tokens) external view returns (uint256) {
        _checkToken(token, vault());
        return convertToShares(tokens);
    }

    function previewRedeem(Token token, uint256 shares) external view returns (uint256) {
        _checkToken(token, vault());
        return convertToAssets(shares);
    }

    function getTokenInList() external view returns (Token[] memory tokens) {
        tokens = new Token[](1);
        tokens[0] = Token.wrap(vault());
    }

    function getTokenOutList() external view returns (Token[] memory tokens) {
        tokens = new Token[](1);
        tokens[0] = Token.wrap(vault());
    }

    function claimRewards() external pure returns (TokenReward[] memory rewards) {
        rewards = new TokenReward[](0);
    }

    function _args() internal view returns (address sNuke, address nuke) {
        (sNuke, nuke) = abi.decode(LibClone.argsOnClone(address(this)), (address, address));
    }

    function _afterTokenTransfer(address, address, uint256) internal override {
        _checkpoint();
    }

    function _checkpoint() internal {
        uint256 index = ISNuke(vault()).index();
        IndexVesting memory vesting = s_indexVesting;
        if (index <= vesting.target) return;
        uint256 duration = FixedPointMathLib.max(
            block.timestamp - vesting.start,
            FixedPointMathLib.zeroFloorSub(uint256(vesting.start) + vesting.duration, block.timestamp)
        );
        s_indexVesting = IndexVesting({
            anchor: _vestedIndex(vesting).toUint96(),
            target: index.toUint96(),
            start: block.timestamp.toUint40(),
            duration: FixedPointMathLib.clamp(duration, MIN_VESTING_PERIOD, type(uint24).max).toUint24()
        });
    }

    function _vestedIndex(IndexVesting memory vesting) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - vesting.start;
        if (elapsed >= vesting.duration) return vesting.target;
        return vesting.anchor + uint256(vesting.target - vesting.anchor) * elapsed / vesting.duration;
    }

    function _toAssets(ISNuke sNuke, uint256 shares) internal view returns (uint256 assets) {
        assets = sNuke.balanceForGons(FixedPointMathLib.fullMulDiv(shares, INDEX_GONS, SHARE_SCALE));
    }

    function _toShares(ISNuke sNuke, uint256 assets) internal view returns (uint256 shares) {
        shares = FixedPointMathLib.fullMulDiv(sNuke.gonsForBalance(assets), SHARE_SCALE, INDEX_GONS);
    }

    function _checkToken(Token token, address sNuke) internal pure {
        if (Token.unwrap(token) != sNuke) revert Errors.ERC4626Wrapper_TokenNotListed();
    }

    function _checkReceiver(address receiver) internal view {
        if (receiver == address(0) || receiver == address(this)) revert SNukeWrapper_InvalidRecipient();
    }
}
