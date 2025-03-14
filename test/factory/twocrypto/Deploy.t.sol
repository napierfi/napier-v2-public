// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Base} from "../../Base.t.sol";

import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {YieldToken} from "src/tokens/YieldToken.sol";
import {AccessManager} from "src/modules/AccessManager.sol";

import {TokenNameLib} from "src/utils/TokenNameLib.sol";
import {FeePcts, FEE_MODULE_INDEX} from "src/Types.sol";
import {Errors} from "src/Errors.sol";
import {FeePctsLib} from "src/modules/FeeModule.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import "src/Constants.sol" as Constants;

import {ITwoCrypto} from "../../shared/ITwoCrypto.sol";

contract DeployTest is Base {
    using SafeCastLib for uint256;

    function setUp() public override {
        super.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
    }

    function test_DeploySuccessfully() public {
        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            ptBlueprint: pt_blueprint,
            resolverBlueprint: resolver_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: abi.encode(twocryptoParams),
            resolverArgs: abi.encode(address(target))
        });

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(FeePctsLib.pack(factory.DEFAULT_SPLIT_RATIO_BPS().toUint16(), 100, 200, 50, 10000))
        });

        uint256 expiry = block.timestamp + 365 days;

        (address p, address y, address pool) = factory.deploy(suite, params, expiry, curator);

        // Assertions
        assertTrue(p != address(0), "PrincipalToken should be deployed");
        assertTrue(y != address(0), "YT should be deployed");
        assertTrue(pool != address(0), "Pool should be deployed");

        // Verify PrincipalToken is registered
        assertEq(factory.s_principalTokens(p), pt_blueprint, "PrincipalToken should be registered");

        // Verify pool is registered
        assertEq(factory.s_pools(pool), address(twocryptoDeployer), "Pool should be registered");

        // Verify curator is set correctly
        AccessManager accessManager = AccessManager(PrincipalToken(p).i_accessManager());
        assertEq(accessManager.owner(), curator, "Curator should be set as owner");

        // Verify expiry is set correctly
        assertEq(PrincipalToken(p).maturity(), expiry, "Expiry should be set correctly");

        // Verify YT is linked to PrincipalToken
        assertEq(address(YieldToken(y).i_principalToken()), address(p), "YT should be linked to PrincipalToken");
        assertEq(address(PrincipalToken(p).i_yt()), y, "YT address should be set correctly");

        assertEq(ITwoCrypto(pool).coins(Constants.TARGET_INDEX), address(target));
        assertEq(ITwoCrypto(pool).coins(Constants.PT_INDEX), address(p));

        assertEq(PrincipalToken(p).name(), TokenNameLib.principalTokenName(address(target), expiry));
        assertEq(PrincipalToken(p).symbol(), TokenNameLib.principalTokenSymbol(address(target), expiry));
        assertEq(YieldToken(y).name(), TokenNameLib.yieldTokenName(address(target), expiry));
        assertEq(YieldToken(y).symbol(), TokenNameLib.yieldTokenSymbol(address(target), expiry));
    }

    function test_RevertWhen_InvalidSuite() public {
        Factory.Suite memory validSuite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            ptBlueprint: pt_blueprint,
            resolverBlueprint: resolver_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: abi.encode(twocryptoParams),
            resolverArgs: abi.encode(address(target))
        });

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: ""
        });

        uint256 expiry = block.timestamp + 365 days;

        // Test invalid accessManagerImpl
        Factory.Suite memory invalidSuite = validSuite;
        invalidSuite.accessManagerImpl = address(0);
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test invalid ptBlueprint
        invalidSuite = validSuite;
        invalidSuite.ptBlueprint = address(0);
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test invalid resolverBlueprint
        invalidSuite = validSuite;
        invalidSuite.resolverBlueprint = address(0);
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test invalid poolDeployerImpl
        invalidSuite = validSuite;
        invalidSuite.poolDeployerImpl = address(0);
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test with unregistered accessManagerImpl
        invalidSuite = validSuite;
        invalidSuite.accessManagerImpl = address(0x123); // Some random address
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test with unregistered ptBlueprint
        invalidSuite = validSuite;
        invalidSuite.ptBlueprint = address(0x456); // Some random address
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test with unregistered resolverBlueprint
        invalidSuite = validSuite;
        invalidSuite.resolverBlueprint = address(0x789); // Some random address
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);

        // Test with unregistered poolDeployerImpl
        invalidSuite = validSuite;
        invalidSuite.poolDeployerImpl = address(0xabc); // Some random address
        vm.expectRevert(Errors.Factory_InvalidSuite.selector);
        factory.deploy(invalidSuite, params, expiry, curator);
    }

    function test_RevertWhen_InvalidExpiry() public {
        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            ptBlueprint: pt_blueprint,
            resolverBlueprint: resolver_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: abi.encode(twocryptoParams),
            resolverArgs: abi.encode(address(target))
        });

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: ""
        });

        uint256 invalidExpiry = block.timestamp - 1; // Expiry in the past

        vm.expectRevert(Errors.Factory_InvalidExpiry.selector);
        factory.deploy(suite, params, invalidExpiry, curator);
    }

    function test_RevertWhen_MissingFeeModule() public {
        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: accessManager_logic,
            ptBlueprint: pt_blueprint,
            resolverBlueprint: resolver_blueprint,
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: abi.encode(twocryptoParams),
            resolverArgs: abi.encode(address(target))
        });

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](0); // Empty params, missing FeeModule

        uint256 expiry = block.timestamp + 365 days;

        vm.expectRevert(Errors.Factory_FeeModuleRequired.selector);
        factory.deploy(suite, params, expiry, curator);
    }
}
