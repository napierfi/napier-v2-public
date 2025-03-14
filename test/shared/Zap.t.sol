// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base, ZapBase} from "../Base.t.sol";
import {PrincipalTokenTest} from "./PrincipalToken.t.sol";

import {ITwoCrypto} from "./ITwoCrypto.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockFeeModule} from "../mocks/MockFeeModule.sol";

import "src/Types.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Casting} from "src/utils/Casting.sol";

abstract contract ZapPrincipalTokenTest is ZapBase, PrincipalTokenTest {
    function setUp() public virtual override(Base, PrincipalTokenTest) {
        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        _deployPeriphery();

        // Overwrite fee module to use MockFeeModule
        FeePcts feePcts = FeePctsLib.pack(5_000, 0, 100, 0, BASIS_POINTS); // For setting up liquidity, issuance fee should be 0
        deployCodeTo("MockFeeModule", address(feeModule));
        setMockFeePcts(address(feeModule), feePcts);

        _label();
    }

    function _label() internal virtual override(Base, ZapBase) {
        super._label();
    }

    function boundToken(Token token) internal view returns (Token) {
        address[] memory tokens = validTokenInput();
        for (uint256 i = 0; i < tokens.length; i++) {
            if (token.eq(tokens[i])) return token;
        }
        return Token.wrap(tokens[uint256(uint160(token.unwrap())) % tokens.length]);
    }

    function validTokenInput() internal view virtual returns (address[] memory tokens) {
        tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(base), address(target));
    }
}

abstract contract ZapAMMTest is ZapPrincipalTokenTest {
    struct AMMInit {
        address user;
        uint256 share;
        uint256 principal;
    }

    function setUpAMM(AMMInit memory init) public virtual {}

    struct U256 {
        uint256 value;
    }

    struct SetupAMMFuzzInput {
        uint256[2] deposits;
        uint256 timestamp;
        int256 yield;
    }

    modifier boundSetupAMMFuzzInput(SetupAMMFuzzInput memory input) virtual {
        uint256 price = ITwoCrypto(twocrypto.unwrap()).last_prices(); // coin1 price in terms of coin0 in wei
        input.deposits[1] = bound(input.deposits[1], 1e6, 1_000 * tOne);
        input.deposits[0] = bound(input.deposits[0], 0, input.deposits[1] * price / 1e18);
        input.timestamp = bound(input.timestamp, block.timestamp, expiry - 1);
        input.yield = bound(input.yield, -1_000 * int256(bOne), int256(1_000 * bOne));
        _;
    }

    modifier fuzzAMMState(SetupAMMFuzzInput memory input) {
        address fujiwara = makeAddr("fujiwara");
        vm.warp(input.timestamp);
        this.setUpAMM(AMMInit({user: fujiwara, share: input.deposits[0], principal: input.deposits[1]}));
        this.setUpYield(input.yield);
        _;
    }
}

abstract contract TwoCryptoZapAMMTest is ZapAMMTest {
    using Casting for *;

    function cheat_addLiquidity(address caller, uint256 amount0, uint256 amount1, address receiver)
        public
        returns (uint256)
    {
        deal(target.asAddr(), caller, amount0);
        deal(principalToken.asAddr(), caller, amount1);
        changePrank(caller, caller);
        return ITwoCrypto(twocrypto.unwrap()).add_liquidity([amount0, amount1], 0, receiver);
    }

    /// @dev Set up AMM for testing purposes
    function setUpAMM(AMMInit memory init) public override {
        address user = init.user;
        // principals
        uint256 principal = init.principal;
        try MockERC20(base.asAddr()).mint(user, principal) {}
        catch {
            vm.assume(false);
        }
        changePrank(user, user);
        base.approve(target.asAddr(), principal);
        try MockERC4626(target.asAddr()).deposit(principal, user) {}
        catch {
            vm.assume(false);
        }
        target.approve(principalToken.asAddr(), type(uint256).max);
        try principalToken.supply(principal, user) returns (uint256 actual) {
            init.principal = actual;
        } catch {
            vm.assume(false);
        }

        // shares
        uint256 shares = init.share;
        try MockERC20(base.asAddr()).mint(user, shares) {}
        catch {
            vm.assume(false);
        }
        base.approve(target.asAddr(), shares);
        try MockERC4626(target.asAddr()).deposit(shares, user) {}
        catch {
            vm.assume(false);
        }

        // LP tokens
        target.approve(twocrypto.unwrap(), type(uint256).max);
        principalToken.approve(twocrypto.unwrap(), type(uint256).max);
        try ITwoCrypto(twocrypto.unwrap()).add_liquidity([shares, principal], 0, user) {}
        catch {
            vm.assume(false);
        }
        vm.stopPrank();
    }
}
