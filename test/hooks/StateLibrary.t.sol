// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {SymTest} from "halmos-cheatcodes/src/SymTest.sol";

import {UniswapV4Base} from "../UniswapV4Base.t.sol";
import {Brutalizer} from "../Brutalizer.sol";

import {PoolKey, PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import {ITokiHook, ImmutableParamsLib, StateLibrary} from "../../src/interfaces/ITokiHook.sol";
import {TokiHook} from "../../src/hooks/TokiHook.sol";
import {Factory} from "../../src/Factory.sol";
import {FunctionTypeCasts} from "../../src/utils/FunctionTypeCasts.sol";

contract MockTokiHook is TokiHook {
    constructor(IPoolManager poolManager, Factory factory) TokiHook(poolManager, factory) {}

    function setState(PoolId id, ITokiHook.PoolStorage memory state) public {
        s_hookStorage.s_states[id] = state;
    }

    function stateOf(PoolId id) public view returns (ITokiHook.PoolStorage memory state) {
        return s_hookStorage.s_states[id];
    }
}

contract StateLibrarySymTest is Test, SymTest {
    using FunctionTypeCasts for *;

    function check_Parse(ITokiHook.ImmutableParams memory data) public {
        address pointer = SSTORE2.write(abi.encode(data));

        ITokiHook.ImmutableParams memory result = ImmutableParamsLib.parse(pointer);
        assertEq(abi.encode(result), abi.encode(data));
    }

    function check_Decode(ITokiHook.ImmutableParams memory data) public {
        address pointer = SSTORE2.write(abi.encode(data));

        ITokiHook.ImmutableParams memory result = ImmutableParamsLib.decode.asImmutableParams()(pointer);
        assertEq(abi.encode(result), abi.encode(data));
    }
}

contract StateLibraryTest is UniswapV4Base, Brutalizer {
    using FunctionTypeCasts for *;

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployInstance();

        _label();

        deployCodeTo("MockTokiHook", abi.encode(poolManager, factory), address(tokiHook));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     Immutable Params                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Parse() public view brutalizeMemory {
        address pointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory result = ImmutableParamsLib.parse(pointer);
        ITokiHook.ImmutableParams memory immutableParams =
            abi.decode(SSTORE2.read(pointer), (ITokiHook.ImmutableParams));
        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(immutableParams)));
    }

    function testFuzz_Parse(ITokiHook.ImmutableParams memory data) public brutalizeMemory {
        address pointer = SSTORE2.write(abi.encode(data));

        ITokiHook.ImmutableParams memory result = ImmutableParamsLib.parse(pointer);

        assertEq(keccak256(abi.encode(result)), keccak256(abi.encode(data)));
    }

    function test_Decode() public view brutalizeMemory {
        address pointer = stateOf(poolKey.toId()).immutableParamsPointer;
        ITokiHook.ImmutableParams memory result = ImmutableParamsLib.decode.asImmutableParams()(pointer);
        ITokiHook.ImmutableParams memory data = abi.decode(SSTORE2.read(pointer), (ITokiHook.ImmutableParams));
        assertEq(abi.encode(result), abi.encode(data));
    }

    function testFuzz_Decode(ITokiHook.ImmutableParams memory data) public brutalizeMemory {
        address pointer = SSTORE2.write(abi.encode(data));

        ITokiHook.PoolStorage memory state;
        state.immutableParamsPointer = pointer;
        MockTokiHook(address(tokiHook)).setState(poolKey.toId(), state);

        ITokiHook.ImmutableParams memory result =
            ImmutableParamsLib.decodeFor.asImmutableParams()(tokiHook, poolKey.toId());
        assertEq(abi.encode(result), abi.encode(data));
    }

    function test_GetLiquidityToken() public view brutalizeMemory {
        address liquidityToken = ImmutableParamsLib.getLiquidityToken(tokiHook, poolKey.toId());
        assertEq(liquidityToken, pool);
    }

    function test_GetVaults() public view brutalizeMemory {
        (address vault0, address vault1) = ImmutableParamsLib.getVaults(tokiHook, poolKey.toId());
        assertEq(vault0, address(vault0));
        assertEq(vault1, address(vault1));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      State Library                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testFuzz_FuzzState(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        assertEq(state.reserves.unwrap(), StateLibrary.getReserves(hook, poolKey.toId()));
        assertEq(state.fees.unwrap(), StateLibrary.getFees(hook, poolKey.toId()));
        assertEq(state.rawBalances.unwrap(), StateLibrary.getRawBalances(hook, poolKey.toId()));
        assertEq(state.lnImpliedRate, StateLibrary.getLnImpliedRate(hook, poolKey.toId()));
        assertEq(state.totalLiquidity, StateLibrary.getLiquidity(hook, poolKey.toId()));
        assertEq(state.immutableParamsPointer, StateLibrary.getPointer(hook, poolKey.toId()));
        (uint16 cardinality, uint16 cardinalityNext, uint16 observationIndex) =
            StateLibrary.getObservationState(hook, poolKey.toId());
        assertEq(state.observationCardinality, cardinality);
        assertEq(state.observationCardinalityNext, cardinalityNext);
        assertEq(state.observationIndex, observationIndex);
    }

    function testFuzz_GetReserves(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        uint256 result = StateLibrary.getReserves(hook, poolKey.toId());
        assertEq(result, state.reserves.unwrap());
    }

    function testFuzz_GetFees(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        uint256 result = StateLibrary.getFees(hook, poolKey.toId());
        assertEq(result, state.fees.unwrap());
    }

    function testFuzz_GetRawBalances(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        uint256 result = StateLibrary.getRawBalances(hook, poolKey.toId());
        assertEq(result, state.rawBalances.unwrap());
    }

    function testFuzz_GetLnImpliedRate(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        uint256 result = StateLibrary.getLnImpliedRate(hook, poolKey.toId());
        assertEq(result, state.lnImpliedRate);
    }

    function testFuzz_GetLiquidity(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        uint256 result = StateLibrary.getLiquidity(hook, poolKey.toId());
        assertEq(result, state.totalLiquidity);
    }

    function testFuzz_GetObservationState(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        (uint16 cardinality, uint16 cardinalityNext, uint16 observationIndex) =
            StateLibrary.getObservationState(hook, poolKey.toId());
        assertEq(cardinality, state.observationCardinality);
        assertEq(cardinalityNext, state.observationCardinalityNext);
        assertEq(observationIndex, state.observationIndex);
    }

    function testFuzz_GetPointer(ITokiHook.PoolStorage memory state) public brutalizeMemory {
        MockTokiHook hook = MockTokiHook(address(tokiHook));
        hook.setState(poolKey.toId(), state);

        address pointer = StateLibrary.getPointer(hook, poolKey.toId());
        assertEq(pointer, state.immutableParamsPointer);
    }

    function test_Observations() public view brutalizeMemory {
        uint256 timestamp = block.timestamp;

        (uint32 blockTimestamp, uint216 lnImpliedRateCumulative, bool initialized) =
            StateLibrary.observations(tokiHook, poolKey.toId(), 0);

        assertEq(blockTimestamp, timestamp);
        assertEq(lnImpliedRateCumulative, 0);
        assertEq(initialized, true);
    }

    function testFuzz_Observations(uint256 index, uint32 newTimestamp, uint216 newLnImpliedRateCumulative) public {
        // This test validates that StateLibrary.observations can read from different indices
        index = uint16(bound(index, 1, 100)); // Use indices 1-100 to avoid overwriting index 0
        newTimestamp = uint32(bound(newTimestamp, 1, type(uint32).max));
        newLnImpliedRateCumulative = uint216(bound(newLnImpliedRateCumulative, 0, type(uint216).max));

        // Pack the values according to the storage layout:
        // - bits 0-31: blockTimestamp (uint32)
        // - bits 32-247: lnImpliedRateCumulative (uint216)
        // - bits 248-255: initialized (bool as uint8)
        uint256 packedValue = uint256(newTimestamp) | (uint256(newLnImpliedRateCumulative) << 32) | (uint256(1) << 248); // initialized = true

        // Calculate the storage slot for s_observations[poolId][index]
        // The mapping is: mapping(PoolId => Observation[65535])
        bytes32 poolIdSlot =
            keccak256(abi.encode(PoolId.unwrap(poolKey.toId()), StateLibrary.OBSERVATIONS_MAPPING_SLOT));
        // Array elements are stored contiguously starting from the poolIdSlot
        bytes32 finalSlot = bytes32(uint256(poolIdSlot) + index);

        // Write directly to storage
        vm.store(address(tokiHook), finalSlot, bytes32(packedValue));

        // Read back using StateLibrary and verify
        (uint32 blockTimestamp, uint216 lnImpliedRateCumulative, bool initialized) =
            StateLibrary.observations(tokiHook, poolKey.toId(), index);

        assertEq(blockTimestamp, newTimestamp);
        assertEq(lnImpliedRateCumulative, newLnImpliedRateCumulative);
        assertTrue(initialized);
    }
}
