/// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import "forge-std/src/Test.sol";

import {LiquidityHookBase} from "../hooks/LiquidityHookBase.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Initializable} from "solady/src/utils/Initializable.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

import {TokiOracle} from "../../src/oracles/TokiOracle.sol";

contract TokiOracleTest is LiquidityHookBase {
    uint16 constant DEFAULT_CARDINALITY = 85;
    uint32 constant DEFAULT_TWAP_WINDOW = 1800; // 30 minutes
    uint16 constant ETHEREUM_BLOCK_INTERVAL = 11000; // 11 seconds
    uint16 constant L2_BLOCK_INTERVAL = 1000; // 1 second

    TokiOracle oracle;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public override {
        super.setUp();

        // Deploy oracle and initialize with default block interval
        address implementation = address(new TokiOracle());
        bytes memory args = abi.encode(factory);
        oracle = TokiOracle(LibClone.deployERC1967I(implementation, args));
        oracle.initialize(ETHEREUM_BLOCK_INTERVAL);

        // Add initial liquidity to create a functioning pool
        _addInitialLiquidity(alice, alice);

        tokiHook.increaseObservationsCardinalityNext(poolKey, DEFAULT_CARDINALITY);

        // Ensure we have enough historical data for TWAP calculations
        // Need at least DEFAULT_TWAP_WINDOW (30 minutes) of data
        _swap({user: alice, zeroForOne: false, amount: -1000, timeJump: 0});
        _swap({user: alice, zeroForOne: true, amount: 500, timeJump: 10 minutes});
        _swap({user: alice, zeroForOne: false, amount: -500, timeJump: 10 minutes});
        _swap({user: alice, zeroForOne: true, amount: 1000, timeJump: 15 minutes});

        // Pump up the vault share price
        deal(address(base), curator, 1100 * bOne);
        _approve(address(base), curator, address(target), type(uint256).max);
        vm.prank(curator);
        target.deposit(1000 * bOne, alice);
        vm.prank(curator);
        base.transfer(address(target), 100 * bOne);

        require(target.convertToAssets(tOne) > bOne, "vault share price");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             MISC                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Initialize_WhenNoBlockIntervalMs() public {
        address implementation = address(new TokiOracle());
        bytes memory args = abi.encode(factory);

        vm.chainId(1);
        oracle = TokiOracle(LibClone.deployERC1967I(implementation, args));
        oracle.initialize(0);
        assertEq(oracle.blockIntervalMs(), ETHEREUM_BLOCK_INTERVAL);

        vm.chainId(2121);
        oracle = TokiOracle(LibClone.deployERC1967I(implementation, args));
        oracle.initialize(0);
        assertEq(oracle.blockIntervalMs(), L2_BLOCK_INTERVAL);
    }

    function test_Initialize_WhenReinitialize() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        oracle.initialize(0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   TWAP READINESS TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_CheckTwapReadiness() public {
        // Block interval is 11 seconds, window is 1 hour then 328+1 = 329 observations are needed
        (bool needsIncrease, uint16 required, bool hasOldestData) = oracle.checkTwapReadiness(pool, 1 hours);

        assertEq(required, 329);
        assertEq(needsIncrease, true, "needsIncrease");
        assertEq(hasOldestData, false, "hasOldestData");

        _swap({user: alice, zeroForOne: false, amount: -1000, timeJump: 1 hours});

        (needsIncrease, required, hasOldestData) = oracle.checkTwapReadiness(pool, 1 hours);
        assertEq(required, 329);
        assertEq(needsIncrease, true, "needsIncrease");
        assertEq(hasOldestData, true, "hasOldestData");

        // Increase observations cardinality next to required cardinality
        tokiHook.increaseObservationsCardinalityNext(poolKey, required);

        (needsIncrease, required, hasOldestData) = oracle.checkTwapReadiness(pool, 1 hours);
        assertEq(required, 329);
        assertEq(needsIncrease, false, "needsIncrease");
        assertEq(hasOldestData, true, "hasOldestData");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN TESTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_SetBlockIntervalMs_ValidInterval() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiOracle.setBlockIntervalMs.selector;

        _grantRoles(napierAccessManager, admin, admin, address(oracle), selectors, Constants.DEV_ROLE);
        vm.prank(admin);
        oracle.setBlockIntervalMs(L2_BLOCK_INTERVAL);

        assertEq(oracle.blockIntervalMs(), L2_BLOCK_INTERVAL);
    }

    function test_SetBlockIntervalMs_RevertWhen_InvalidInterval() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TokiOracle.setBlockIntervalMs.selector;

        _grantRoles(napierAccessManager, admin, admin, address(oracle), selectors, Constants.DEV_ROLE);
        vm.prank(admin);
        vm.expectRevert(TokiOracle.TokiOracle_InvalidBlockInterval.selector);
        oracle.setBlockIntervalMs(500);
    }

    function test_SetBlockIntervalMs_RevertWhen_NotAuthorized() public {
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        oracle.setBlockIntervalMs(500);
    }
}
