// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {PoolId, PoolKey} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IExtsload} from "@uniswap/v4-core/src/interfaces/IExtsload.sol";

import "../Types.sol";
import {IHooklet} from "./IHooklet.sol";
import {PrincipalToken} from "../tokens/PrincipalToken.sol";
import {TokiPoolToken} from "../tokens/TokiPoolToken.sol";
import {LibOracle} from "../utils/LibOracle.sol";
import {FunctionTypeCasts} from "../utils/FunctionTypeCasts.sol";

interface ITokiHook is IExtsload {
    enum CurrencyIndex {
        CURRENCY_0,
        CURRENCY_1
    }

    /// @dev The reference to the storage for Hook logic library.
    struct HookStorage {
        mapping(address liquidityToken => PoolKey) s_poolKeyOf;
        mapping(PoolId => PoolStorage) s_states;
        mapping(PoolId => LibOracle.Observation[65535]) s_observations;
    }

    /// @param reserves Reserve of principalToken and underlying token
    /// @param lnImpliedRate last ln(impliedRate)
    /// @param immutableParamsPointer Pointer to immutable parameters (Principal Token, liquidity token, hooklet, scalarRoot, initialAnchor, pausableFlags etc)
    /// @param observationCardinality The number of populated elements in the oracle array
    /// @param observationCardinalityNext The new length of the oracle array, independent of population
    /// @param observationIndex The index of the observation that was most recently written to the observations array (used to manage the circular buffer of observations)
    struct PoolStorage {
        Uint128x2 reserves; // reserve0, reserve1
        Uint128x2 fees; // curator fees, protocol fees
        Uint128x2 rawBalances; // rawBalance0, rawBalance1
        uint96 lnImpliedRate;
        address immutableParamsPointer;
        uint128 totalLiquidity;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        uint16 observationIndex;
    }

    /// @param pausableFlags Each bit indicates whether an operation is pausable (1 = pausable, 0 = not pausable)
    struct ImmutableParams {
        TokiPoolToken liquidityToken;
        PrincipalToken principalToken;
        address underlying;
        uint256 expiry;
        IHooklet hooklet;
        ERC4626 vault0;
        ERC4626 vault1;
        Flags16 pausableFlags;
        /// AMM params
        uint256 scalarRoot;
        int256 initialAnchor;
        // Rehypothecation params
        uint16 targetRawTokenRatio0;
        uint16 maxRawTokenRatio0;
        uint16 minRawTokenRatio0;
        uint16 targetRawTokenRatio1;
        uint16 maxRawTokenRatio1;
        uint16 minRawTokenRatio1;
        uint16 vaultFlags0;
        uint16 vaultFlags1;
    }

    /// @dev Each action modifies different aspects of the pool configuration
    enum UpdateConfiguration {
        UPDATE_RATIOS,
        UPDATE_VAULT,
        FREEZE_RATIOS,
        FREEZE_VAULT
    }

    /// @notice Parameters for deploying a new TokiPool
    /// @param hookParams hook params for encoding pool-specific params
    /// @param liquidityTokenImplementation address of the implementation of TokiPoolToken to be used for the pool (must be whitelisted)
    /// @param liquidityTokenImmutableData optional immutable data for TokiPoolToken instance
    /// @param hooklet optional
    /// @param hookletParams hooklet params for encoding hooklet-specific params
    struct TokiPoolDeploymentParams {
        bytes32 salt;
        address hook;
        Flags16 pausableFlags;
        bytes hookParams;
        IHooklet hooklet;
        bytes hookletParams;
        ERC4626 vault0;
        ERC4626 vault1;
        bytes vault0Params;
        bytes vault1Params;
        address liquidityTokenImplementation;
        bytes liquidityTokenImmutableData;
    }

    function deploy(address underlying, address principalToken, TokiPoolDeploymentParams calldata params)
        external
        returns (PoolKey memory poolKey, address liquidityToken);

    function updateConfiguration(
        PoolKey calldata key,
        ITokiHook.UpdateConfiguration[] calldata actions,
        bytes[] calldata params
    ) external;

    function getTotalBalances(PoolId id) external view returns (Uint128x2);

    function poolKeyOf(address liquidityToken) external view returns (PoolKey memory);

    function observe(PoolKey calldata key, uint32[] memory secondsAgos)
        external
        view
        returns (uint216[] memory lnImpliedRateCumulative);
}

library ImmutableParamsLib {
    using FunctionTypeCasts for *;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                IMMUTABLE PARAMS CONSTANTS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    uint256 public constant LIQUIDITY_TOKEN_OFFSET = 0x00;
    uint256 public constant VAULT_OFFSET = 0x20 * 5;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Functions                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function parse(address pointer) internal view returns (ITokiHook.ImmutableParams memory immutableParams) {
        bytes memory data = SSTORE2.read(pointer);
        assembly {
            immutableParams := add(data, 0x20)
        }
    }

    function parse(ITokiHook hook, PoolId id)
        internal
        view
        returns (ITokiHook.ImmutableParams memory immutableParams)
    {
        return parse(StateLibrary.getPointer(hook, id));
    }

    /// @notice Variant of `parse`
    /// @dev Returns the reference to the immutable params in the memory, not SSTORE2 pointer
    ///      This is used to avoid duplicate declaration/allocation of ITokiHook.ImmutableParams return parameter.
    /// @dev The function is meant to be used with type casting
    function decode(address pointer) internal view returns (uint256 ref) {
        bytes memory data = SSTORE2.read(pointer);
        assembly {
            ref := add(data, 0x20)
        }
    }

    function decodeFor(ITokiHook hook, PoolId id) internal view returns (uint256 ref) {
        bytes memory data = SSTORE2.read(StateLibrary.getPointer(hook, id));
        assembly {
            ref := add(data, 0x20)
        }
    }

    function getLiquidityToken(ITokiHook hook, PoolId id) internal view returns (address) {
        return abi.decode(
            SSTORE2.read(StateLibrary.getPointer(hook, id), LIQUIDITY_TOKEN_OFFSET, LIQUIDITY_TOKEN_OFFSET + 0x20),
            (address)
        );
    }

    function getVaults(address pointer) internal view returns (address vault0, address vault1) {
        return abi.decode(SSTORE2.read(pointer, VAULT_OFFSET, VAULT_OFFSET + 0x20 * 2), (address, address));
    }

    function getVaults(ITokiHook hook, PoolId id) internal view returns (address vault0, address vault1) {
        return getVaults(StateLibrary.getPointer(hook, id));
    }
}

library StateLibrary {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     STORAGE SLOT CONSTANTS                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev The location of the mapping(liquidityToken => PoolKey) in the storage
    uint256 public constant POOL_KEY_MAPPING_SLOT = 0x00;

    /// @dev The location of the mapping(PoolId => PoolStorage) in the storage
    uint256 public constant STATE_MAPPING_SLOT = 0x01;

    /// @dev The location of the mapping(PoolId => LibOracle.Observations[65535]) in the storage
    uint256 public constant OBSERVATIONS_MAPPING_SLOT = 0x02;

    /// @dev The index of members in the PoolStorage storage
    uint256 public constant POOL_STATE_RESERVES_INDEX = 0x00;
    uint256 public constant POOL_STATE_FEES_INDEX = 0x01;
    uint256 public constant POOL_STATE_RAW_BALANCES_INDEX = 0x02;
    uint256 public constant POOL_STATE_LN_IMPLIED_RATE_INDEX = 0x03;
    uint256 public constant POOL_STATE_IMMUTABLE_POINTER_INDEX = 0x03;
    uint256 public constant POOL_STATE_LIQUIDITY_INDEX = 0x04;
    uint256 public constant POOL_STATE_OBSERVATION_STATE_INDEX = 0x04;

    /// @dev The offset of the immutable pointer in the slot
    uint256 public constant IMMUTABLE_POINTER_OFFSET = 0x60; // 96 bits

    /// @dev The offset of the observation cardinality in the slot
    uint256 public constant OBSERVATION_CARDINALITY_OFFSET = 0x80; // 128 bits
    uint256 public constant OBSERVATION_CARDINALITY_NEXT_OFFSET = OBSERVATION_CARDINALITY_OFFSET + 0x10; // 16 bits
    uint256 public constant OBSERVATION_INDEX_OFFSET = OBSERVATION_CARDINALITY_NEXT_OFFSET + 0x10; // 16 bits

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         Functions                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Returns the reserves of the pool (reserve0, reserve1) without id check
    function getReserves(ITokiHook hook, PoolId id) internal view returns (uint256 reserves) {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_RESERVES_INDEX);
        reserves = uint256(extsload(hook, slot));
    }

    function getFees(ITokiHook hook, PoolId id) internal view returns (uint256 fees) {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_FEES_INDEX);
        fees = uint256(extsload(hook, slot));
    }

    function getRawBalances(ITokiHook hook, PoolId id) internal view returns (uint256 rawBalances) {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_RAW_BALANCES_INDEX);
        rawBalances = uint256(extsload(hook, slot));
    }

    function getLnImpliedRate(ITokiHook hook, PoolId id) internal view returns (uint96 lnImpliedRate) {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_LN_IMPLIED_RATE_INDEX);
        bytes32 value = extsload(hook, slot);
        lnImpliedRate = uint96(uint256(value));
    }

    function getPointer(ITokiHook hook, PoolId id) internal view returns (address pointer) {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_IMMUTABLE_POINTER_INDEX);
        bytes32 value = extsload(hook, slot);
        assembly {
            pointer := shr(IMMUTABLE_POINTER_OFFSET, value)
        }
    }

    function getLiquidity(ITokiHook hook, PoolId id) internal view returns (uint128 liquidity) {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_LIQUIDITY_INDEX);
        bytes32 value = extsload(hook, slot);
        liquidity = uint128(uint256(value));
    }

    function getObservationState(ITokiHook hook, PoolId id)
        internal
        view
        returns (uint16 cardinality, uint16 cardinalityNext, uint16 observationIndex)
    {
        bytes32 slot = deriveStateSlot(id, POOL_STATE_OBSERVATION_STATE_INDEX);
        uint256 value = uint256(extsload(hook, slot));
        cardinality = uint16(value >> OBSERVATION_CARDINALITY_OFFSET);
        cardinalityNext = uint16(value >> OBSERVATION_CARDINALITY_NEXT_OFFSET);
        observationIndex = uint16(value >> OBSERVATION_INDEX_OFFSET);
    }

    /// @dev Returns the observation at the given index without bounds checking
    function observations(ITokiHook hook, PoolId id, uint256 index)
        internal
        view
        returns (uint32 blockTimestamp, uint216 lnImpliedRateCumulative, bool initialized)
    {
        bytes32 slot;
        // Mapping of one-word fixed-size arrays
        assembly {
            mstore(0x00, id)
            mstore(0x20, OBSERVATIONS_MAPPING_SLOT)
            slot := add(keccak256(0x00, 0x40), index)
        }
        uint256 value = uint256(extsload(hook, slot));

        blockTimestamp = uint32(value);
        lnImpliedRateCumulative = uint216(value >> 32);
        initialized = uint8(value >> 248) == 1;
    }

    function extsload(ITokiHook hook, bytes32 slot) internal view returns (bytes32 value) {
        assembly {
            mstore(0x20, slot) // Store the `slot` argument.
            mstore(0x00, 0x1e2eaeaf) // `extsload(bytes32)`.
            value :=
                mload(
                    // mload(success ? 0x00 : uint256(-1)) trick for if-else-revert pattern without branching.
                    // If `success` is false, it consumes all gas and reverts with OOG.
                    // In this case 99.99% of the time, the call will succeed.
                    sub(
                        and(
                            // The arguments of `and` are evaluated from right to left.
                            gt(returndatasize(), 0x1f),
                            staticcall(gas(), hook, 0x1c, 0x24, 0x00, 0x20) // The return value is written to 0x00.
                        ),
                        0x01
                    )
                )
        }
    }

    function deriveStateSlot(PoolId id, uint256 index) internal pure returns (bytes32 slot) {
        assembly {
            mstore(0x00, id)
            mstore(0x20, STATE_MAPPING_SLOT)
            slot := add(keccak256(0x00, 0x40), index)
        }
    }
}
