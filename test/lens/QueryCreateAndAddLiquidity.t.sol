// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";
import {ImpersonatorTest} from "./Impersonator.t.sol";

import {Impersonator} from "src/lens/Impersonator.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {Factory} from "src/Factory.sol";

import {FeePctsLib} from "src/utils/FeePctsLib.sol";

import "src/Types.sol";
import "src/Constants.sol";

contract QueryCreateAndAddLiquidityTest is ImpersonatorTest {
    function setUp() public override {
        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        // No need to deploy instances
        _deployPeriphery();

        _label();

        setImpersonator();
    }

    function test_Query() public {
        uint256 shares = 353258901219909923;
        _test_Query(Token.wrap(address(target)), shares);
    }

    function testFuzz_Query(SetupAMMFuzzInput memory, /* input */ Token, /* token */ uint256 shares) public override {
        _test_Query(Token.wrap(address(target)), shares);
    }

    function _test_Query(Token, /* token */ uint256 shares) internal override {
        deal(address(target), alice, shares);

        (Factory.Suite memory suite, Factory.ModuleParam[] memory modules) = toyParams();

        // Run simulation
        uint256 snapshot = vm.snapshot();
        vm.prank(alice);
        (bool success, bytes memory ret) = alice.call(
            abi.encodeCall(
                Impersonator.queryCreateAndAddLiquidity,
                (address(zap), address(quoter), suite, modules, expiry, curator, shares)
            )
        );
        vm.revertTo(snapshot); // Revert to before the call
        vm.assume(success);

        // Get the result
        (uint256 liquidity, uint256 principal) = abi.decode(ret, (uint256, uint256));

        _approve(target, alice, address(zap), shares);

        // Run the real transaction
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = TwoCryptoZap.CreateAndAddLiquidityParams({
            suite: suite,
            modules: modules,
            expiry: expiry,
            curator: curator,
            shares: shares,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        vm.prank(alice);
        ( /* address _pt */ , /* address _yt */, /* address _twoCrypto */, uint256 _liquidity, uint256 _principal) =
            zap.createAndAddLiquidity(params);

        assertEq(_liquidity, liquidity, "Liquidity");
        assertEq(_principal, principal, "Principal");
    }

    function toyParams() public view returns (Factory.Suite memory suite, Factory.ModuleParam[] memory modules) {
        FeePcts feePcts = FeePctsLib.pack(DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183);

        bytes memory poolArgs = abi.encode(twocryptoParams);
        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        modules = new Factory.ModuleParam[](1);
        modules[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        suite = Factory.Suite({
            accessManagerImpl: address(accessManager_logic),
            resolverBlueprint: address(resolver_blueprint),
            ptBlueprint: address(pt_blueprint),
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });
    }
}
