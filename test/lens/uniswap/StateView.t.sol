// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";
import {ZapSwapTest} from "../../zap/uniswap/SwapYT.t.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";
import {SSTORE2} from "solady/src/utils/SSTORE2.sol";

import "../../../src/lens/uniswap/StateView.sol";
import "../../../src/interfaces/ITokiHook.sol";
import "../../../src/Types.sol";
import "../../../src/Errors.sol";

contract StateViewTest is ZapSwapTest {
    StateView stateView;
    PoolId poolId;

    function setUp() public override {
        super.setUp();

        // Deploy StateView
        stateView = new StateView(TokiPoolDeployer(tokiPoolDeployer));
        poolId = poolKey.toId();

        _swap({user: alice, zeroForOne: false, amount: -1000, timeJump: 0});
        _swap({user: alice, zeroForOne: true, amount: 500, timeJump: 10 minutes});
        _swap({user: alice, zeroForOne: false, amount: -500, timeJump: 10 minutes});

        tokiHook.increaseObservationsCardinalityNext(poolKey, 100);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     HOOK RESOLUTION                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_HookOf() public view {
        ITokiHook hook = stateView.hookOf(poolId);
        assertEq(address(hook), address(tokiHook));
    }

    function test_PoolKeyOf() public view {
        PoolKey memory key = stateView.poolKeyOf(poolId);
        assertEq(keccak256(abi.encode(key)), keccak256(abi.encode(poolKey)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      POOL STATE TESTS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Vaults() public view {
        (address resultVault0, address resultVault1) = stateView.getVaults(poolId);
        assertEq(address(resultVault0), address(vault0));
        assertEq(address(resultVault1), address(vault1));
    }

    function test_TotalBalances() public view {
        (uint128 totalBalance0, uint128 totalBalance1) = stateView.getTotalBalances(poolId);
        Uint128x2 balances = tokiHook.getTotalBalances(poolId);
        assertEq(totalBalance0, balances.value0());
        assertEq(totalBalance1, balances.value1());
    }

    function test_Reserves() public view {
        (uint128 reserve0, uint128 reserve1) = stateView.getReserves(poolId);
        assertEq(reserve0, stateOf(poolId).reserves.value0());
        assertEq(reserve1, stateOf(poolId).reserves.value1());
    }

    function test_Fees() public view {
        (uint128 curatorFees, uint128 protocolFees) = stateView.getFees(poolId);
        assertEq(curatorFees, stateOf(poolId).fees.value0());
        assertEq(protocolFees, stateOf(poolId).fees.value1());
    }

    function test_RawBalances() public view {
        (uint128 rawBalance0, uint128 rawBalance1) = stateView.getRawBalances(poolId);
        assertEq(rawBalance0, stateOf(poolId).rawBalances.value0());
        assertEq(rawBalance1, stateOf(poolId).rawBalances.value1());
    }

    function test_LnImpliedRate() public view {
        uint256 lnImpliedRate = stateView.getLnImpliedRate(poolId);
        assertEq(lnImpliedRate, stateOf(poolId).lnImpliedRate);
    }

    function test_Pointer() public view {
        address pointer = stateView.getPointer(poolId);
        assertEq(pointer, stateOf(poolId).immutableParamsPointer);
    }

    function test_Liquidity() public view {
        uint128 liquidity = stateView.getLiquidity(poolId);
        assertEq(liquidity, stateOf(poolId).totalLiquidity);
    }

    function test_LiquidityToken() public view {
        address liquidityToken = stateView.getLiquidityToken(poolId);
        assertEq(liquidityToken, pool);
    }

    function test_ImmutableData() public view {
        bytes memory immutableData = stateView.getImmutableData(poolId);
        assertEq(keccak256(immutableData), keccak256(SSTORE2.read(stateOf(poolId).immutableParamsPointer)));
    }

    function test_ObservationState() public view {
        (uint16 cardinality, uint16 cardinalityNext, uint16 observationIndex) = stateView.getObservationState(poolId);
        assertEq(cardinality, stateOf(poolId).observationCardinality);
        assertEq(cardinalityNext, stateOf(poolId).observationCardinalityNext);
        assertEq(observationIndex, stateOf(poolId).observationIndex);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      NEGATIVE TESTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_HookOf_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.hookOf(PoolId.wrap(keccak256("non-existent")));
    }

    function test_PoolKeyOf_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.poolKeyOf(PoolId.wrap(keccak256("non-existent")));
    }

    function test_Vaults_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getVaults(PoolId.wrap(keccak256("non-existent")));
    }

    function test_TotalBalances_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getTotalBalances(PoolId.wrap(keccak256("non-existent")));
    }

    function test_Reserves_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getReserves(PoolId.wrap(keccak256("non-existent")));
    }

    function test_Fees_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getFees(PoolId.wrap(keccak256("non-existent")));
    }

    function test_RawBalances_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getRawBalances(PoolId.wrap(keccak256("non-existent")));
    }

    function test_LnImpliedRate_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getLnImpliedRate(PoolId.wrap(keccak256("non-existent")));
    }

    function test_Pointer_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getPointer(PoolId.wrap(keccak256("non-existent")));
    }

    function test_Liquidity_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getLiquidity(PoolId.wrap(keccak256("non-existent")));
    }

    function test_ImmutableData_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getImmutableData(PoolId.wrap(keccak256("non-existent")));
    }

    function test_LiquidityToken_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getLiquidityToken(PoolId.wrap(keccak256("non-existent")));
    }

    function test_ObservationState_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.getObservationState(PoolId.wrap(keccak256("non-existent")));
    }

    function test_Observations_RevertWhen_BadPool() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.BadTokiPool.selector));
        stateView.observations(PoolId.wrap(keccak256("non-existent")), 0);
    }
}
