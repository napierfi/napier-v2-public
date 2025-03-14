// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {Base, TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {Impersonator} from "src/lens/Impersonator.sol";

import {Errors} from "src/Errors.sol";
import "src/Types.sol";
import "src/Constants.sol";

abstract contract ImpersonatorTest is TwoCryptoZapAMMTest {
    Impersonator instance = new Impersonator();

    function setUp() public virtual override {
        super.setUp();
        _label();

        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        // Impersonate alice. Mock `eth_call` stateOvveride option
        setImpersonator();
    }

    function setImpersonator() internal {
        vm.etch(alice, type(Impersonator).runtimeCode);
    }

    function testFuzz_Query(SetupAMMFuzzInput memory input, Token token, uint256 amount)
        public
        virtual
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        _test_Query(token, amount);
    }

    function _test_Query(Token token, uint256 amount) internal virtual;
}
