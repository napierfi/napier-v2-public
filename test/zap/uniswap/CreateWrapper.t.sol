// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";
import {MockWrapper} from "../../mocks/MockWrapper.sol";

import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Events.sol";
import "src/Constants.sol" as Constants;

contract CreateWrapperTest is UniswapV4ZapBase {
    address mockWrapperImplementation;

    // Test amounts
    uint256 internal INITIAL_LIQUIDITY_UNDERLYING;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           SETUP                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function setUp() public virtual override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _label();

        INITIAL_LIQUIDITY_UNDERLYING = 50000 * tOne;

        mockWrapperImplementation = address(new MockWrapper());

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = wrapperFactory.setWrapperImplementation.selector;
        napierAccessManager.grantTargetFunctionRoles(address(wrapperFactory), selectors, Constants.DEV_ROLE);

        wrapperFactory.setWrapperImplementation(mockWrapperImplementation, true);
        vm.stopPrank();
    }

    function test_CreateWrapper() public {
        bytes memory args = abi.encode(target, weth);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.CREATE_WRAPPER)));

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(mockWrapperImplementation, args);

        // Start recording logs to capture events
        vm.recordLogs();

        vm.prank(alice);
        zap.execute(commands, inputs);

        // Get all recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find the WrapperCreated event
        address wrapper;

        for (uint256 i = 0; i < logs.length; i++) {
            // WrapperCreated event signature: WrapperCreated(address indexed wrapper, address indexed connector)
            if (logs[i].topics[0] == keccak256("WrapperCreated(address,address)")) {
                // Extract wrapper address from first indexed parameter (topics[1])
                wrapper = address(uint160(uint256(logs[i].topics[1])));
                break;
            }
        }

        assertTrue(wrapper != address(0), "Wrapper address is zero");

        // Verify the wrapper was properly registered
        assertEq(wrapperFactory.s_wrappers(wrapper), mockWrapperImplementation, "wrapper implementation mismatch");
    }
}
