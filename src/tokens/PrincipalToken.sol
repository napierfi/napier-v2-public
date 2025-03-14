// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {LibString} from "solady/src/utils/LibString.sol";
import {ECDSA} from "solady/src/utils/ECDSA.sol";

// Interfaces
import "../Types.sol";
import {IHook} from "../interfaces/IHook.sol";
import {FeeModule} from "../modules/FeeModule.sol";
import {IRewardProxy} from "../interfaces/IRewardProxy.sol";
import {VerifierModule} from "../modules/VerifierModule.sol";
import {VaultInfoResolver} from "../modules/resolvers/VaultInfoResolver.sol";
import {Factory} from "../Factory.sol";
import {YieldToken} from "./YieldToken.sol";
// Libraries
import {LibRewardProxy} from "../utils/LibRewardProxy.sol";
import {ModuleAccessor} from "../utils/ModuleAccessor.sol";
import {TokenNameLib} from "../utils/TokenNameLib.sol";
import {CustomRevert} from "../utils/CustomRevert.sol";
import {LibExpiry} from "../utils/LibExpiry.sol";
import {Events} from "../Events.sol";
import {Errors} from "../Errors.sol";
import {BASIS_POINTS} from "../Constants.sol";
// Math & Fee logic
import {FeePctsLib} from "../utils/FeePctsLib.sol";
import {Snapshot, Yield, YieldMathLib} from "../utils/YieldMathLib.sol";
import {Reward, RewardIndex, RewardMathLib} from "../utils/RewardMathLib.sol";
// Implements
import {EIP5095} from "../interfaces/EIP5095.sol";
// Inherits
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "solady/src/utils/ReentrancyGuard.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {AccessManager, AccessManaged} from "../modules/AccessManager.sol";
import {LibApproval} from "../utils/LibApproval.sol";

/// @dev Modularity
/// PrincipalToken instance is deployed with a AccessManager instance through the Factory.
///  - FeeModule instance that manages the fee logic for the PrincipalToken instance. It is not upgradable and is managed by the factory's AccessManager.
///  - AccessManager instance that manages the access control for the PrincipalToken instance. It is not upgradable.
///  - RewardProxyModule instance that manages the additional reward collection for the PrincipalToken instance. It is upgradable.
///  - Resolver instance that provides vault share price. It is not upgradable.
///  - YieldToken instance that manages the yield token for the PrincipalToken instance. It is not upgradable.
/// @dev Ownership
///  - On deployment, the ownership of the PrincipalToken instance is transferred to a `curator` specified by a caller.
///  - The curator CAN grant and revoke roles for a PrincipalToken instance.
///  - The curator CAN pause a PrincipalToken instance or change the maximum deposit cap.
/// @dev Access control against Napier Finance
///  - Napier CAN NOT change any roles for a PrincipalToken instance.
///  - Napier CAN NOT change any modules for a PrincipalToken instance.
///  - Napier CAN NOT pause a PrincipalToken instance or change the maximum deposit cap.
/// @dev Princiapl Token Lifecycle:
/// - The first user interaction after the expiry triggers the settlement. The user is called the `settler`
/// Three types of phases: Pre expiry, Post expiry, Post settlement
/// Two types of events:
/// - Deployment: once the principalToken is deployed, the principalToken is in the pre expiry phase
/// - Settlement: once the first user interacts after the expiry, the principalToken is in the post settlement phase. The user is called the `settler`
/// Until the settlement, pre-settlement performance fee is charged. Once the settlement is done, post-settlement performance fee is charged.
/// It means the settler is charged with pre-settlement performance fee though the timestamp at the settlement is after the expiry.
///
/// - ---> Pre expiry (Issue-enabled) ---> Post expiry (Redeem-enabled) ---> Post settlement
///    ^                                                                 ^
/// Deployment                                                       Settlement
///
/// @dev User interaction:
/// - Pre expiry: Supply, Issue, Unite, Combine, Collect are enabled.
/// - Post expiry ~ Post settlement: Withdraw, Redeem, Unite, Combine, Collect are enabled
/// @dev Yield Token Lifecycle:
/// - Users can collect yield as many times as they want whenerver they want.
/// @dev Yield Accrual mechanism:
/// - Yield is accrued every time the a user's YT balance changes (supply, issue, redeem, withdraw, transfer, collect)
/// - Accrued yield is calculated based on the difference between the maxscale at the time of the user's last interaction and the current maxscale. See `YieldMathLib`
/// - Accrued yield is proportional to the user's YT balance
/// - Accrued yield is collected in the target token
/// - Accrued yield is collected by the user or approved collectors by the user
/// @dev Fee mechanism:
/// - Three types of fees: issuance fee, performance fee (pre settlement), redemption fee and post settlement fee (post settlement)
/// - All fees are collected in the target token
/// - Fees are split between the curator and the protocol based on the fee split ratio
/// - Performance fee is applied against the accrued yield
/// - The performance fee is collected every time the user interacts with the contract
/// @dev ERC20 support:
/// - The target token must not be a rebase token
/// - The target token must not be fee-on-transfer token
/// - The target token must have less than or equal to 18 decimals
/// - The target token must not be double-entry point token like TrueUSD.
/// - The reward token must not be a rebase token
/// - The reward token must not be fee-on-transfer token
/// - The reward token must not be the target token
/// @dev Price oracle:
/// AMM may provide the price oracle for the PT.
/// Important security note: It may be possible for an attacker to flash mint tons of PT, sell those on TwoCrypto or AMM and decrease PT price
/// atomically, and then exploit an external lending market that uses this PT as collateral.
contract PrincipalToken is ERC20, LibApproval, AccessManaged, Pausable, ReentrancyGuard, EIP5095 {
    using CustomRevert for bytes4;
    using SafeCastLib for uint256;
    using FeePctsLib for FeePcts;
    using ModuleAccessor for address[];
    using ModuleAccessor for address;
    using DynamicArrayLib for uint256[];

    /// @notice Principal token implementation version
    bytes32 public constant VERSION = "2.0.0";

    /// @dev `keccak256("PermitCollector(address owner,address collector,uint256 nonce,uint256 deadline)")`.
    bytes32 private constant PERMIT_COLLECTOR_TYPEHASH =
        0xabaa81be0e21ab93788e05cd5409517fd2908fd1c16213aab992c623ac2cf0a4;

    /// @dev Solady.ERC20 nonces slot seed
    uint256 private constant _NONCES_SLOT_SEED = 0x38377508;

    AccessManager internal immutable _i_accessManager;

    /// @notice Expiry timestamp of the principalToken in seconds
    uint256 internal immutable i_expiry;

    /// @notice Factory that deployed this contract
    Factory public immutable i_factory;

    /// @notice YieldToken that this principalToken is associated with
    YieldToken public immutable i_yt;

    /// @notice Resolver that this principalToken is associated with
    VaultInfoResolver public immutable i_resolver;

    /// @notice Base asset that the resolver is associated with
    ERC20 public immutable i_asset;

    /// @notice Yield bearing token (e.g wstETH, rETH, etc) that this principalToken accepts as deposit
    ERC20 internal immutable i_target;

    /// @notice Name hash for gas saving
    /// @dev Name hash is calculated based on the underlying token name at the time of deployment.
    bytes32 internal immutable i_nameHash;

    /// @notice Flag to indicate if the principalToken is settled
    bool internal s_isSettled;

    /// @notice SSTORE2 pointer for module addresses storage
    address public s_modules;

    /// @notice Snapshot of the principalToken at the last update
    Snapshot internal s_snapshot;

    /// @notice Name and symbol string for efficient storage
    /// @dev Design: For downsizing contract, we will store the name and symbol.
    /// - Composing the name and symbol string on the fly increases the contract size.
    /// - `ShortString` type supports only up to 31 bytes. It's not enough for long token names.
    /// - SSTORE2 takes minimum 32k gas.
    LibString.StringStorage internal s_name;

    LibString.StringStorage internal s_symbol;

    /// @notice User yield index
    mapping(address account => Yield) internal s_userYields;

    /// @notice Fee accruals in units of underlying token
    uint128 internal s_curatorFee;

    uint128 internal s_protocolFee;

    struct RewardRecord {
        mapping(address account => Reward) userRewards;
        uint128 curatorReward; // Fee accruals in units of reward token
        uint128 protocolReward; // Fee accruals in units of reward token
        RewardIndex globalIndex;
    }

    /// @notice Reward data
    mapping(address reward => RewardRecord) internal s_rewardRecords;

    /// @dev None direct constructor args for easier verification and deterministic deployment
    constructor() payable {
        Factory.ConstructorArg memory args = Factory(msg.sender).args();

        i_factory = Factory(msg.sender);
        address target = VaultInfoResolver(args.resolver).target();

        i_expiry = args.expiry;
        i_resolver = VaultInfoResolver(args.resolver);
        i_yt = YieldToken(args.yt);
        i_target = ERC20(target);
        i_asset = ERC20(VaultInfoResolver(args.resolver).asset());
        _i_accessManager = AccessManager(args.accessManager);
        s_modules = args.modules;

        string memory tokenName = TokenNameLib.principalTokenName(target, i_expiry);
        i_nameHash = keccak256(bytes(tokenName));
        LibString.set(s_name, tokenName);
        LibString.set(s_symbol, TokenNameLib.principalTokenSymbol(target, i_expiry));
    }

    /// @notice Deposit `shares` of YBT and mint `principal` amount of PT and YT to `receiver`
    function supply(uint256 shares, address receiver) external returns (uint256) {
        return supply(shares, receiver, "");
    }

    function supply(uint256 shares, address receiver, bytes memory data)
        public
        nonReentrant
        whenNotPaused
        notExpired
        returns (uint256)
    {
        address[] memory m = ModuleAccessor.read(s_modules);
        Snapshot memory snapshot = s_snapshot;

        FeePcts feePcts = FeeModule(m.unsafeGet(FEE_MODULE_INDEX)).getFeePcts();

        // Fetch share price (scale) and update the global index and calculate the performance fee (not just for `receiver`) and issuance fee
        // Calculate the principal amount of PT and YT to mint
        (uint256 principal, uint256 fee) = _previewSupply(snapshot, feePcts, shares);

        uint256 ytBalance = i_yt.balanceOf(receiver);

        // Veriy deposit cap and other conditions
        _verify(m, shares, principal, receiver);

        _writeState(snapshot, feePcts, fee);

        _accrueYield(snapshot, receiver, ytBalance);

        // Accrue rewards if any
        TokenReward[] memory rewards = _delegateCallRewardProxy(m);
        _accrueRewards(feePcts, rewards, address(0), 0, receiver, ytBalance);

        // Mint PT and YT and call the hook if any
        _supplyWithHook(msg.sender, receiver, shares, principal, data);

        return principal;
    }

    function issue(uint256 principal, address receiver) external returns (uint256) {
        return issue(principal, receiver, "");
    }

    /// @notice Issue `principal` amount of PT and YT to `receiver` in return for `shares` of YBT
    function issue(uint256 principal, address receiver, bytes memory data)
        public
        nonReentrant
        whenNotPaused
        notExpired
        returns (uint256)
    {
        address[] memory m = ModuleAccessor.read(s_modules);
        Snapshot memory snapshot = s_snapshot;

        FeePcts feePcts = FeeModule(m.unsafeGet(FEE_MODULE_INDEX)).getFeePcts();

        // Fetch share price (scale) and update the global index and calculate the fee and issuance fee
        // Calculate the principal amount of PT and YT to mint
        (uint256 shares, uint256 fee) = _previewIssue(snapshot, feePcts, principal);

        uint256 ytBalance = i_yt.balanceOf(receiver);

        // Veriy deposit cap and other conditions
        _verify(m, shares, principal, receiver);

        _writeState(snapshot, feePcts, fee);

        _accrueYield(snapshot, receiver, ytBalance);

        // Accrue rewards if any
        TokenReward[] memory rewards = _delegateCallRewardProxy(m);
        _accrueRewards(feePcts, rewards, address(0), 0, receiver, ytBalance);

        // Mint PT and YT and call the hook if any
        _supplyWithHook(msg.sender, receiver, shares, principal, data);

        return shares;
    }

    function _supplyWithHook(address by, address receiver, uint256 shares, uint256 principal, bytes memory data)
        internal
    {
        uint256 expected = SafeTransferLib.balanceOf(address(i_target), address(this)) + shares;

        Events.emitSupply({by: by, receiver: receiver, shares: shares, principal: principal});

        // Mint PT and YT
        if (data.length > 0) {
            // Optimistically flash mint
            _mint(receiver, principal);
            IHook(by).onSupply(shares, principal, data);
        } else {
            SafeTransferLib.safeTransferFrom(address(i_target), by, address(this), shares);
            _mint(receiver, principal);
        }
        if (SafeTransferLib.balanceOf(address(i_target), address(this)) < expected) {
            Errors.PrincipalToken_InsufficientSharesReceived.selector.revertWith();
        }
    }

    function unite(uint256 shares, address receiver) external returns (uint256) {
        return unite(shares, receiver, "");
    }

    /// @notice Burn `shares` amount of PT and YT and send back `shares` of YBT to `receiver`
    /// @notice This function doesn't redeem accrued yield at the same time
    /// @dev This API shouldn't have an `owner` parameter because the same amount of YT are burned regardless of `owner`'s approval towards `msg.sender`
    function unite(uint256 shares, address receiver, bytes memory data)
        public
        nonReentrant
        settleIfExpired
        returns (uint256)
    {
        address[] memory m = ModuleAccessor.read(s_modules);
        Snapshot memory snapshot = s_snapshot;

        FeePcts feePcts = FeeModule(m.unsafeGet(FEE_MODULE_INDEX)).getFeePcts();
        uint256 ytBalance = i_yt.balanceOf(msg.sender);

        (uint256 principal, uint256 fee) = _previewUnite(snapshot, feePcts, shares);

        _writeState(snapshot, feePcts, fee);

        _accrueYield(snapshot, msg.sender, ytBalance);

        // Accrue rewards if any
        TokenReward[] memory rewards = _delegateCallRewardProxy(m);
        _accrueRewards(feePcts, rewards, msg.sender, ytBalance, address(0), 0);

        _uniteWithHook(msg.sender, receiver, shares, principal, data);

        return principal;
    }

    /// @notice Burn `msg.sender`'s `principal` amount of PT and YT and send back `shares` of YBT to `receiver`.
    /// @notice This function doesn't redeem accrued yield at the same time.
    /// @dev This API shouldn't have a `owner` parameter because the same amount of YT are burned regardless of `owner`'s approval towards `msg.sender`
    function combine(uint256 principal, address receiver) external returns (uint256) {
        return combine(principal, receiver, "");
    }

    function combine(uint256 principal, address receiver, bytes memory data)
        public
        nonReentrant
        settleIfExpired
        returns (uint256)
    {
        address[] memory m = ModuleAccessor.read(s_modules);
        Snapshot memory snapshot = s_snapshot;

        FeePcts feePcts = FeeModule(m.unsafeGet(FEE_MODULE_INDEX)).getFeePcts();
        uint256 ytBalance = i_yt.balanceOf(msg.sender);

        (uint256 shares, uint256 fee) = _previewCombine(snapshot, feePcts, principal);

        _writeState(snapshot, feePcts, fee);

        _accrueYield(snapshot, msg.sender, ytBalance);

        // Accrue rewards if any
        TokenReward[] memory rewards = _delegateCallRewardProxy(m);
        _accrueRewards(feePcts, rewards, msg.sender, ytBalance, address(0), 0);

        _uniteWithHook(msg.sender, receiver, shares, principal, data);

        return shares;
    }

    function _uniteWithHook(address by, address receiver, uint256 shares, uint256 principal, bytes memory data)
        internal
    {
        Events.emitUnite({by: by, receiver: receiver, shares: shares, principal: principal});

        SafeTransferLib.safeTransfer(address(i_target), receiver, shares);
        if (data.length > 0) {
            IHook(by).onUnite(shares, principal, data);
        }
        _burn(by, principal);
        i_yt.burn(by, principal);
    }

    /// @notice Claim `shares` of accrued yield (in unit of YBT) and rewards for `owner` and transfer it to `receiver`.
    /// @notice If the caller is not `owner`, the caller must be approved by `owner`.
    function collect(address receiver, address owner)
        external
        nonReentrant
        ownerOrApprovedCollector(owner)
        settleIfExpired
        returns (uint256, TokenReward[] memory rewards)
    {
        address[] memory m = ModuleAccessor.read(s_modules);
        Snapshot memory snapshot = s_snapshot;
        FeePcts feePcts = FeeModule(m.unsafeGet(FEE_MODULE_INDEX)).getFeePcts();

        uint256 ytBalance = i_yt.balanceOf(owner);

        // Note Calculate the newly accrued interest and returns the total accrued interest
        (uint256 shares, uint256 fee) = _previewCollect(snapshot, feePcts, owner, ytBalance);

        _writeState(snapshot, feePcts, fee);

        // Update the user's userIndex and reset the pending yield
        _accrueYield(snapshot, owner, ytBalance);
        delete s_userYields[owner].accrued;

        Events.emitInterestCollected({by: msg.sender, owner: owner, receiver: receiver, shares: shares});

        // Accrue rewards and send it to the receiver
        rewards = _delegateCallRewardProxy(m);
        _accrueRewards(feePcts, rewards, owner, ytBalance, address(0), 0);

        for (uint256 i; i != rewards.length;) {
            rewards[i].amount = _collectRewards(rewards[i].token, receiver, owner); // Reuse the memory to save gas
            unchecked {
                ++i;
            }
        }

        SafeTransferLib.safeTransfer(address(i_target), receiver, shares);
        return (shares, rewards);
    }

    /// @notice Users can collect rewards but not update the accrued rewards.
    /// This function is useful when `RewardProxyModule.rewardTokens()` doesn't include tokens that the user wants to collect.
    function collectRewards(address[] calldata rewardTokens, address receiver, address owner)
        external
        nonReentrant
        ownerOrApprovedCollector(owner)
        returns (uint256[] memory result)
    {
        result = new uint256[](rewardTokens.length);
        for (uint256 i; i != rewardTokens.length;) {
            DynamicArrayLib.set(result, i, _collectRewards(rewardTokens[i], receiver, owner)); // Unsafe access without bounds check
            unchecked {
                ++i;
            }
        }
    }

    /// @dev Note PrincipalToken doesn't support double-entry point tokens.
    function _collectRewards(address token, address receiver, address owner) internal returns (uint256 rewards) {
        if (token == address(i_target)) Errors.PrincipalToken_ProtectedToken.selector.revertWith(); // Prevent collecting the underlying token

        Reward storage userReward = s_rewardRecords[token].userRewards[owner];
        rewards = userReward.accrued;
        delete userReward.accrued;

        Events.emitRewardsCollected({
            by: msg.sender,
            owner: owner,
            receiver: receiver,
            rewardToken: token,
            rewards: rewards
        });

        SafeTransferLib.safeTransfer(token, receiver, rewards);
    }

    /// @notice Updates the user's accrued yield and rewards on YieldToken transfer events
    /// @dev This function is called by the YieldToken contract whenever a transfer happens
    /// See {YieldToken-transfer} and {YieldToken-transferFrom}
    function onYtTransfer(address owner, address receiver, uint256 balanceOfOwner, uint256 balanceOfReceiver)
        external
        nonReentrant
        settleIfExpired
    {
        if (msg.sender != address(i_yt)) Errors.PrincipalToken_OnlyYieldToken.selector.revertWith();

        address[] memory m = ModuleAccessor.read(s_modules);
        Snapshot memory snapshot = s_snapshot;

        FeePcts feePcts = FeeModule(m.unsafeGet(FEE_MODULE_INDEX)).getFeePcts();
        {
            // Note: Calculation must follow `_previewCollect` logic
            uint256 perfFeePct = s_isSettled ? feePcts.getPostSettlementFeePctBps() : feePcts.getPerformanceFeePctBps();

            uint256 fee = _updateIndex(snapshot, perfFeePct);

            _writeState(snapshot, feePcts, fee);

            // Update the two users' accrued yield
            _accrueYield(snapshot, owner, balanceOfOwner);
            _accrueYield(snapshot, receiver, balanceOfReceiver);
        }

        TokenReward[] memory rewards = _delegateCallRewardProxy(m);
        _accrueRewards(feePcts, rewards, owner, balanceOfOwner, receiver, balanceOfReceiver);
    }

    /// @notice This function doesn't redeem accrued yield at the same time
    function withdraw(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        expired
        settleIfExpired
        returns (uint256)
    {
        Snapshot memory snapshot = s_snapshot;
        FeePcts feePcts = FeeModule(ModuleAccessor.read(s_modules).unsafeGet(FEE_MODULE_INDEX)).getFeePcts();

        // Fetch fresh share price (scale) and update the global index and calculate the performance fee
        (uint256 principal, uint256 fee) = _previewWithdraw(snapshot, feePcts, shares);

        // Update snapshot and fees
        _writeState(snapshot, feePcts, fee);

        _redeem(msg.sender, owner, receiver, shares, principal);

        return principal;
    }

    /// @notice Burn `owner`'s `principal` amount of PT and send `shares` of YBT to `receiver`.
    /// @notice If owner is not `msg.sender`, the caller must be approved by `owner` at least `principal` amount of PT.
    /// @notice Revert if the principalToken is not expired.
    /// @notice This function doesn't redeem accrued yield at the same time.
    function redeem(uint256 principal, address receiver, address owner)
        external
        nonReentrant
        expired
        settleIfExpired
        returns (uint256)
    {
        Snapshot memory snapshot = s_snapshot;
        FeePcts feePcts = FeeModule(ModuleAccessor.read(s_modules).unsafeGet(FEE_MODULE_INDEX)).getFeePcts();

        // Fetch fresh share price (scale) and update the global index and calculate the performance fee and redemption fee
        (uint256 shares, uint256 fee) = _previewRedeem(snapshot, feePcts, principal);

        // Update snapshot and fees
        _writeState(snapshot, feePcts, fee);

        // Note Redeem doesn't update the user's accrued yield because the YT balance doesn't change.
        // So the accrued yield is not updated here.
        _redeem(msg.sender, owner, receiver, shares, principal);

        return shares;
    }

    function _redeem(address by, address owner, address receiver, uint256 shares, uint256 principal) internal {
        Events.emitRedeem({by: by, owner: owner, receiver: receiver, shares: shares, principal: principal});

        // Check allowance and burn the principal amount from the owner
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, principal);
        _burn(owner, principal);

        // Transfer the shares to the receiver
        SafeTransferLib.safeTransfer(address(i_target), receiver, shares);
    }

    /// @notice the caller approves `collector` collects accrued yield through `collect` and `collectRewards` functions
    function setApprovalCollector(address collector, bool isApproved) external {
        _setApprovalCollector(msg.sender, collector, isApproved);
    }

    /// @notice The signature based `setApprovalCollector` function that allows `owner` to approve `collector` to collect accrued yield and rewards
    /// @dev This ECDSA implementation does NOT check if a signature is non-malleable.
    /// @dev Mark `external` visibility to make sure upper bits of `owner`, `collector` and etc are clean.
    function permitCollector(address owner, address collector, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
    {
        assembly {
            // Revert if the block timestamp is greater than `deadline`.
            if gt(timestamp(), deadline) {
                mstore(0x00, 0x1a15a3cc) // `PermitExpired()`.
                revert(0x1c, 0x04)
            }
        }

        uint256 nonce = nonces(owner);
        bytes32 domainSeparator = DOMAIN_SEPARATOR();

        bytes32 digest;
        /// @solidity memory-safe-assembly
        assembly {
            // Dev: Forked from Solady's ERC20 permit and EIP712 hashTypedData implementation.
            let m := mload(0x40) // Grab the free memory pointer.
            // Prepare the struct hash.
            mstore(m, PERMIT_COLLECTOR_TYPEHASH)
            mstore(add(m, 0x20), owner) // Upper 96 bits are already clean.
            mstore(add(m, 0x40), collector) // Upper 96 bits are already clean.
            mstore(add(m, 0x60), nonce)
            mstore(add(m, 0x80), deadline)
            let structHash := keccak256(m, 0xa0)
            // Prepare the digest (hashTypedData)
            mstore(0x00, 0x1901000000000000) // Store "\x19\x01".
            mstore(0x1a, domainSeparator) // Store the domain separator.
            mstore(0x3a, structHash) // Store the struct hash.
            digest := keccak256(0x18, 0x42)
            // Restore the part of the free memory slot that was overwritten.
            mstore(0x3a, 0)
        }

        address signer = ECDSA.recover(digest, v, r, s);
        if (signer != owner) InvalidPermit.selector.revertWith();

        // WRITE
        assembly {
            // Compute the nonce slot and increment the nonce without overflow check.
            mstore(0x0c, _NONCES_SLOT_SEED)
            mstore(0x00, owner)
            sstore(keccak256(0x0c, 0x20), add(nonce, 1))
        }
        _setApprovalCollector(owner, collector, true);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      INTERNAL HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _setApprovalCollector(address owner, address collector, bool isApproved) internal {
        setApproval(owner, collector, isApproved);
        Events.emitSetApprovalCollector({owner: owner, collector: collector, approved: isApproved});
    }

    /// @dev This function should be called every time snapshot changes (core logic)
    function _writeState(Snapshot memory snapshot, FeePcts feePcts, uint256 fee) internal {
        uint256 curatorFee = (fee * feePcts.getSplitPctBps()) / BASIS_POINTS; // round down or up is not a big deal here

        s_snapshot = snapshot;
        s_curatorFee = (s_curatorFee + curatorFee).toUint128();
        s_protocolFee = (s_protocolFee + fee - curatorFee).toUint128();

        Events.emitYieldFeeAccrued(fee);
    }

    /// @dev This function should be called every time the `user`'s YT balance changes
    function _accrueYield(Snapshot memory snapshot, address user, uint256 ytBalance) internal {
        uint256 accrued = YieldMathLib.accrueUserYield(s_userYields, snapshot.globalIndex, user, ytBalance);
        Events.emitYieldAccrued(user, accrued, snapshot.globalIndex.unwrap());
    }

    /// @notice Accrue additional rewards and distribute them to `user` proportionally to the `user`'s YT balance
    /// @dev This function should be called every time the `user`'s YT balance changes
    /// @dev This function must be called before YT balance or total supply changes
    function _accrueRewards(
        FeePcts feePcts,
        TokenReward[] memory rewards,
        address src,
        uint256 srcYtBalance,
        address dst,
        uint256 dstYtBalance
    ) internal {
        uint256 ytSupply = i_yt.totalSupply();
        bool settled = s_isSettled;

        for (uint256 i; i != rewards.length;) {
            RewardRecord storage record = s_rewardRecords[rewards[i].token];

            // Calculate fee
            if (settled) {
                uint256 feePct = feePcts.getPostSettlementFeePctBps();

                uint256 amount = rewards[i].amount;
                uint256 fee = FixedPointMathLib.mulDivUp(amount, feePct, BASIS_POINTS);
                uint256 curatorFee = (fee * feePcts.getSplitPctBps()) / BASIS_POINTS;

                (uint256 curatorReward, uint256 protocolReward) = (record.curatorReward, record.protocolReward);
                // Subtract the fee from the reward amount and update fees
                rewards[i].amount = amount - fee;
                record.curatorReward = (curatorReward + curatorFee).toUint128();
                record.protocolReward = (protocolReward + fee - curatorFee).toUint128();
            }

            (RewardIndex newIndex,) = RewardMathLib.updateIndex(record.globalIndex, ytSupply, rewards[i].amount);
            record.globalIndex = newIndex;
            if (src != address(0)) RewardMathLib.accrueUserReward(record.userRewards, newIndex, src, srcYtBalance);
            if (dst != address(0)) RewardMathLib.accrueUserReward(record.userRewards, newIndex, dst, dstYtBalance);

            unchecked {
                ++i;
            }
        }
    }

    /// @dev Mint PT and YT to `to`.
    function _mint(address to, uint256 amount) internal override {
        super._mint(to, amount);
        i_yt.mint(to, amount);
    }

    /// @dev Update the global index for yield (accumulator). Must be called before minting or redeeming.
    function _updateIndex(Snapshot memory snapshot, uint256 performanceFeePct) internal view returns (uint256 fee) {
        (, fee) = YieldMathLib.updateIndex({
            self: snapshot,
            scaleFn: i_resolver.scale,
            ptSupply: totalSupply(),
            ytSupply: i_yt.totalSupply(),
            feePctBps: performanceFeePct
        });
    }

    function _previewSupply(Snapshot memory snapshot, FeePcts feePcts, uint256 shares)
        internal
        view
        returns (uint256 principal, uint256 fee)
    {
        uint256 performanceFee = _updateIndex(snapshot, feePcts.getPerformanceFeePctBps());

        // Calculate the principal amount of PT and YT to mint
        uint256 issuanceFee = _feeOnTotal(shares, feePcts.getIssuanceFeePctBps());
        principal = YieldMathLib.convertToPrincipal(shares - issuanceFee, snapshot.maxscale, false);
        fee = performanceFee + issuanceFee;
    }

    function _previewIssue(Snapshot memory snapshot, FeePcts feePcts, uint256 principal)
        internal
        view
        returns (uint256 shares, uint256 fee)
    {
        uint256 performanceFee = _updateIndex(snapshot, feePcts.getPerformanceFeePctBps());

        shares = YieldMathLib.convertToUnderlying(principal, snapshot.maxscale, true);
        uint256 issuanceFee = _feeOnRaw(shares, feePcts.getIssuanceFeePctBps());
        shares += issuanceFee;
        fee = performanceFee + issuanceFee;
    }

    function _previewUnite(Snapshot memory snapshot, FeePcts feePcts, uint256 shares)
        internal
        view
        returns (uint256 principal, uint256 fee)
    {
        uint256 perfFeePct = s_isSettled ? feePcts.getPostSettlementFeePctBps() : feePcts.getPerformanceFeePctBps();

        // Fetch share price (scale) and update the global index and calculate the performance fee
        uint256 performanceFee = _updateIndex(snapshot, perfFeePct);

        uint256 redemptionFee = _feeOnRaw(shares, feePcts.getRedemptionFeePctBps());
        // Calculate the principal amount corresponding to the shares. (Round up against the user)
        principal = YieldMathLib.convertToPrincipal(shares + redemptionFee, snapshot.maxscale, true);
        fee = performanceFee + redemptionFee;
    }

    function _previewCombine(Snapshot memory snapshot, FeePcts feePcts, uint256 principal)
        internal
        view
        returns (uint256 shares, uint256 fee)
    {
        uint256 perfFeePct = s_isSettled ? feePcts.getPostSettlementFeePctBps() : feePcts.getPerformanceFeePctBps();

        uint256 performanceFee = _updateIndex(snapshot, perfFeePct);

        shares = YieldMathLib.convertToUnderlying(principal, snapshot.maxscale, false);
        uint256 redemptionFee = _feeOnTotal(shares, feePcts.getRedemptionFeePctBps());
        shares -= redemptionFee;
        fee = performanceFee + redemptionFee;
    }

    function _previewWithdraw(Snapshot memory snapshot, FeePcts feePcts, uint256 shares)
        internal
        view
        returns (uint256 principal, uint256 fee)
    {
        uint256 perfFeePct = s_isSettled ? feePcts.getPostSettlementFeePctBps() : feePcts.getPerformanceFeePctBps();

        uint256 performanceFee = _updateIndex(snapshot, perfFeePct);

        uint256 redemptionFee = _feeOnRaw(shares, feePcts.getRedemptionFeePctBps());
        // Calculate the principal amount corresponding to the shares. (Round up against the user)
        principal = YieldMathLib.convertToPrincipal(shares + redemptionFee, snapshot.maxscale, true);
        fee = performanceFee + redemptionFee;
    }

    function _previewRedeem(Snapshot memory snapshot, FeePcts feePcts, uint256 principal)
        internal
        view
        returns (uint256 shares, uint256 fee)
    {
        uint256 perfFeePct = s_isSettled ? feePcts.getPostSettlementFeePctBps() : feePcts.getPerformanceFeePctBps();

        uint256 performanceFee = _updateIndex(snapshot, perfFeePct);

        shares = YieldMathLib.convertToUnderlying(principal, snapshot.maxscale, false);
        uint256 redemptionFee = _feeOnTotal(shares, feePcts.getRedemptionFeePctBps());
        shares -= redemptionFee;
        fee = performanceFee + redemptionFee;
    }

    function _previewCollect(Snapshot memory snapshot, FeePcts feePcts, address owner, uint256 ownerYtBalance)
        internal
        view
        returns (uint256 shares, uint256 fee)
    {
        uint256 perfFeePct = s_isSettled ? feePcts.getPostSettlementFeePctBps() : feePcts.getPerformanceFeePctBps();

        fee = _updateIndex(snapshot, perfFeePct);
        shares = s_userYields[owner].accrued
            + YieldMathLib.computeAccrueUserYield(s_userYields, snapshot.globalIndex, owner, ownerYtBalance);
    }

    /// @dev Calculates the fees that should be added to an amount `shares` that does not already include fees.
    function _feeOnRaw(uint256 shares, uint256 feeBasisPoints) private pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(shares, feeBasisPoints, BASIS_POINTS);
    }

    /// @dev Calculates the fee part of an amount `shares` that already includes fees.
    function _feeOnTotal(uint256 shares, uint256 feeBasisPoints) private pure returns (uint256) {
        return FixedPointMathLib.mulDivUp(shares, feeBasisPoints, feeBasisPoints + BASIS_POINTS);
    }

    /// @notice Delegate call to the RewardProxy to claim rewards accrued by the underlying tokens.
    function _delegateCallRewardProxy(address[] memory m) internal returns (TokenReward[] memory rewards) {
        address rewardProxy = ModuleAccessor.getOrDefault(m, REWARD_PROXY_MODULE_INDEX);
        if (rewardProxy == address(0)) return rewards;

        uint256 balanceBefore = SafeTransferLib.balanceOf(address(i_target), address(this));

        rewards = LibRewardProxy.delegateCallCollectReward(rewardProxy);

        // Although reward proxy is considered trusted, check the underlying token balance does not change.
        if (SafeTransferLib.balanceOf(address(i_target), address(this)) != balanceBefore) {
            Errors.PrincipalToken_UnderlyingTokenBalanceChanged.selector.revertWith();
        }
    }

    function _verify(address[] memory m, uint256 shares, uint256 principal, address receiver) internal view {
        VerifierModule verifier = VerifierModule(ModuleAccessor.getOrDefault(m, VERIFIER_MODULE_INDEX));
        if (address(verifier) == address(0)) return;

        VerificationStatus status = verifier.verify(msg.sig, msg.sender, shares, principal, receiver);
        if (status != VerificationStatus.Success) {
            Errors.PrincipalToken_VerificationFailed.selector.revertWith(uint256(status));
        }
    }

    /// @dev If the principalToken is expired and not settled, it will be settled at the end of the function call.
    modifier settleIfExpired() {
        _;
        if (_isExpired() && !s_isSettled) s_isSettled = true;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            View                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Get `owner`' has approved `collector` to collect accrued interest and rewards through `collect` and `collectRewards` functions
    /// @dev Returns true if `collector` is approved by `owner`
    function isApprovedCollector(address owner, address collector) public view returns (bool) {
        return isApproved(owner, collector);
    }

    function previewSupply(uint256 shares) external view nonReadReentrant returns (uint256 principal) {
        if (_isIssuanceDisabled()) return 0;
        (principal,) =
            _previewSupply(s_snapshot, FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(), shares);
    }

    function previewIssue(uint256 principal) external view nonReadReentrant returns (uint256 shares) {
        if (_isIssuanceDisabled()) return 0;
        (shares,) =
            _previewIssue(s_snapshot, FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(), principal);
    }

    function previewUnite(uint256 shares) external view nonReadReentrant returns (uint256 principal) {
        (principal,) =
            _previewUnite(s_snapshot, FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(), shares);
    }

    function previewCombine(uint256 principal) external view nonReadReentrant returns (uint256 shares) {
        (shares,) =
            _previewCombine(s_snapshot, FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(), principal);
    }

    function previewCollect(address owner) external view nonReadReentrant returns (uint256 shares) {
        (shares,) = _previewCollect(
            s_snapshot,
            FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(),
            owner,
            i_yt.balanceOf(owner)
        );
    }

    function previewWithdraw(uint256 shares) external view nonReadReentrant returns (uint256 principal) {
        if (!_isExpired()) return 0;
        (principal,) =
            _previewWithdraw(s_snapshot, FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(), shares);
    }

    function previewRedeem(uint256 principal) external view nonReadReentrant returns (uint256 shares) {
        if (!_isExpired()) return 0;
        (shares,) =
            _previewRedeem(s_snapshot, FeeModule(s_modules.read().unsafeGet(FEE_MODULE_INDEX)).getFeePcts(), principal);
    }

    function convertToUnderlying(uint256 principal) public view returns (uint256) {
        uint256 maxscale = FixedPointMathLib.max(i_resolver.scale(), s_snapshot.maxscale);
        return YieldMathLib.convertToUnderlying(principal, maxscale, false);
    }

    function convertToPrincipal(uint256 shares) public view returns (uint256) {
        uint256 maxscale = FixedPointMathLib.max(i_resolver.scale(), s_snapshot.maxscale);
        return YieldMathLib.convertToPrincipal(shares, maxscale, false);
    }

    /// @notice Get the maximum shares that can be deposited for `receiver`
    /// @dev If the verifier module is not set, no cap is applied.
    /// MUST return a limited value if receiver is subject to some deposit limit.
    /// MUST return 2 ** 256 - 1 if there is no limit on the maximum amount that may be deposited.
    /// MUST return 0 if it's paused or expired.
    /// MUST NOT revert.
    function maxSupply(address receiver) public view returns (uint256) {
        if (_isIssuanceDisabled()) return 0;
        address verifier = ModuleAccessor.getOrDefault(ModuleAccessor.read(s_modules), VERIFIER_MODULE_INDEX);
        if (verifier == address(0)) return type(uint256).max;
        return VerifierModule(verifier).maxSupply(receiver);
    }

    /// @notice Get the maximum amount of PT that can be issued to `receiver`
    /// @dev If the verifier module is not set, no cap is applied
    function maxIssue(address receiver) external view returns (uint256) {
        uint256 maxShares = maxSupply(receiver);
        if (maxShares == type(uint256).max) return type(uint256).max;
        return convertToPrincipal(maxShares); // Rounded down
    }

    function maxRedeem(address owner) external view returns (uint256) {
        if (!_isExpired()) return 0;
        return balanceOf(owner);
    }

    function maxWithdraw(address owner) external view returns (uint256) {
        if (!_isExpired()) return 0;
        return convertToUnderlying(balanceOf(owner));
    }

    function getUserYield(address owner) external view returns (Yield memory) {
        return s_userYields[owner];
    }

    /// @notice Get the accrued rewards for `owner`.
    /// @dev Note The result doesn't include the pending rewards that haven't been accrued yet since the last `owner`'s interaction
    function getUserReward(address reward, address owner) external view returns (Reward memory) {
        return s_rewardRecords[reward].userRewards[owner];
    }

    function getFeeRewards(address reward) external view returns (uint256, uint256) {
        return (s_rewardRecords[reward].curatorReward, s_rewardRecords[reward].protocolReward);
    }

    function getFees() external view returns (uint256, uint256) {
        return (s_curatorFee, s_protocolFee);
    }

    function getRewardGlobalIndex(address reward) external view returns (RewardIndex) {
        return s_rewardRecords[reward].globalIndex;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Permissioned                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Accounts authorized by Curator `AccessManager.owner()` can collect fees and rewards.
    /// @dev Rewards to be collected are `RewardProxyModule.rewardTokens()`, and additional tokens `additionalTokens` are also collected.
    /// @param additionalTokens Additional reward tokens to be collected in addition to `RewardProxyModule.rewardTokens()`. It can be empty. Duplicated element is allowed.
    function collectCuratorFees(address[] calldata additionalTokens, address feeReceiver)
        external
        restricted
        returns (uint256 shares, TokenReward[] memory rewards)
    {
        shares = s_curatorFee;
        s_curatorFee = 0;

        rewards = _collectFeeRewards({additionalTokens: additionalTokens, feeReceiver: feeReceiver, isCurator: true});
        SafeTransferLib.safeTransfer(address(i_target), feeReceiver, shares);

        emit Events.CuratorFeesCollected(msg.sender, feeReceiver, shares, rewards);
    }

    /// @notice Accounts authorized by Napier's `AccessManager` can collect fees and rewards.
    /// @dev Rewards to be collected are `RewardProxyModule.rewardTokens()`, and additional tokens `additionalTokens` are also collected.
    /// @param additionalTokens Additional reward tokens to be collected in addition to `RewardProxyModule.rewardTokens()`. It can be empty. Duplicated element is allowed.
    function collectProtocolFees(address[] calldata additionalTokens)
        external
        restrictedBy(i_factory.i_accessManager())
        returns (uint256 shares, TokenReward[] memory rewards)
    {
        address treasury = i_factory.s_treasury();

        shares = s_protocolFee;
        s_protocolFee = 0;

        rewards = _collectFeeRewards({additionalTokens: additionalTokens, feeReceiver: treasury, isCurator: false});
        SafeTransferLib.safeTransfer(address(i_target), treasury, shares);

        emit Events.ProtocolFeesCollected(msg.sender, treasury, shares, rewards);
    }

    /// @dev `rewardTokens` and/or `additionalTokens` may include the underlying token address.
    /// @param additionalTokens Additional reward tokens to be collected in addition to `RewardProxyModule.rewardTokens()`
    function _collectFeeRewards(address[] calldata additionalTokens, address feeReceiver, bool isCurator)
        internal
        returns (TokenReward[] memory rewards)
    {
        address[] memory rewardTokens;

        address rewardProxy = ModuleAccessor.read(s_modules).getOrDefault(REWARD_PROXY_MODULE_INDEX);
        if (rewardProxy != address(0)) rewardTokens = IRewardProxy(rewardProxy).rewardTokens();

        uint256 k = rewardTokens.length;
        rewards = new TokenReward[](k + additionalTokens.length); // Reward tokens + additional tokens
        for (uint256 i; i != rewards.length;) {
            unchecked {
                address token = i < k
                    ? DynamicArrayLib.toUint256Array(rewardTokens).getAddress(i) // Unsafe access without bounds check
                    : additionalTokens[i - k];
                RewardRecord storage record = s_rewardRecords[token];

                rewards[i].token = token;
                if (isCurator) {
                    rewards[i].amount = record.curatorReward;
                    record.curatorReward = 0;
                } else {
                    rewards[i].amount = record.protocolReward;
                    record.protocolReward = 0;
                }

                // Note: When we update pending reward fees, the underlying token is not allowed as a reward token.
                SafeTransferLib.safeTransfer(token, feeReceiver, rewards[i].amount);

                ++i;
            }
        }
    }

    function setModules(address modules) external {
        if (msg.sender != address(i_factory)) Errors.PrincipalToken_NotFactory.selector.revertWith();
        s_modules = modules;
    }

    /// @notice Accounts authorized by `AccessManager.owner()` can pause the principalToken.
    /// @notice If the owner is renounced, the principalToken is not pausable anymore even if the caller is authorized.
    function pause() external restricted {
        if (i_accessManager().owner() == address(0)) revert Errors.PrincipalToken_Unstoppable();
        _pause();
    }

    /// @notice Accounts authorized by `AccessManager.owner()` can unpause the principalToken.
    /// @notice Even if the owner is renounced, the principalToken is still unpausable.
    function unpause() external restricted {
        _unpause();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          Metadata                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function underlying() external view returns (address) {
        return address(i_target);
    }

    function maturity() external view returns (uint256) {
        return i_expiry;
    }

    function name() public view override returns (string memory _name) {
        _name = LibString.get(s_name);
    }

    function symbol() public view override returns (string memory _symbol) {
        _symbol = LibString.get(s_symbol);
    }

    function decimals() public view override returns (uint8) {
        return i_asset.decimals();
    }

    /// @dev Settlement is a one-time event that happens at the end of the first interaction after the expiry.
    function isSettled() external view nonReadReentrant returns (bool) {
        return s_isSettled;
    }

    function getSnapshot() external view returns (Snapshot memory) {
        return s_snapshot;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           Utils                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _constantNameHash() internal view override returns (bytes32) {
        return i_nameHash;
    }

    modifier ownerOrApprovedCollector(address owner) {
        _checkOwnerOrApprovedCollector(owner);
        _;
    }

    function _checkOwnerOrApprovedCollector(address owner) internal view {
        if (msg.sender != owner && !isApprovedCollector(owner, msg.sender)) {
            Errors.PrincipalToken_NotApprovedCollector.selector.revertWith();
        }
    }

    function _isExpired() internal view returns (bool) {
        return LibExpiry.isExpired(i_expiry);
    }

    /// @notice Issuance is disabled when the principalToken is expired or paused
    function _isIssuanceDisabled() internal view returns (bool) {
        return _isExpired() || paused();
    }

    modifier notExpired() {
        if (_isExpired()) Errors.Expired.selector.revertWith();
        _;
    }

    modifier expired() {
        if (!_isExpired()) Errors.NotExpired.selector.revertWith();
        _;
    }

    function i_accessManager() public view override returns (AccessManager) {
        return _i_accessManager;
    }
}
