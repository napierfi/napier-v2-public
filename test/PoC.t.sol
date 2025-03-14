// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.0;

import {Base, ZapBase} from "./Base.t.sol";

import "src/Types.sol";
import "src/Constants.sol";

import {MockFeeModule} from "./mocks/MockFeeModule.sol";

import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";

/// @dev In order to further configure the principal token or Zap, refer to the `test/shared/PrincipalToken.t.sol`,`test/shared/Zap.t.sol` and `test/shared/Fork.t.sol`
contract POCTest is ZapBase {
    function setUp() public override {
        super.setUp();

        _deployTwoCryptoDeployer();
        _setUpModules();

        // There is 1 principal token deployed with bare minimum configuration:
        // - PrincipalToken using MockERC4626 as the underlying
        // - PrincipalToken is configured with DepositCapVerifierModule, MockFeeModule and MockRewardProxyModule
        // The MockERC4626 uses MockERC20 as a base asset.
        // The PrincipalToken can accumulate 2 mock reward tokens.
        _deployInstance();
        _deployPeriphery();

        // Overwrite ConstantFeeModule withMockFeeModule
        FeePcts feePcts = FeePctsLib.pack(5_000, 0, 0, 0, BASIS_POINTS); // For setting up principal token, issuance fee should be 0
        deployCodeTo("MockFeeModule", address(feeModule));
        setMockFeePcts(address(feeModule), feePcts);

        _label();
    }

    function _label() internal virtual override {
        super._label();
        // Label user defined addresses for easier debugging (See vm.label())
    }

    function test_POC() external {}
}
