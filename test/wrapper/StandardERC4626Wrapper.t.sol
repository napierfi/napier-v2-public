// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import "src/Types.sol";
import "src/Errors.sol";
import {StandardERC4626Wrapper} from "src/wrapper/StandardERC4626Wrapper.sol";

abstract contract BaseWrapperTest is ZapForkTest {
    StandardERC4626Wrapper public wrapper;

    function setUp() public override {
        super.setUp();
        wrapper = _deployWrapper();
        _label();
    }

    function _deployWrapper() internal virtual returns (StandardERC4626Wrapper);

    function _label() internal virtual override(ZapForkTest) {
        super._label();
        vm.label(address(wrapper), "wrapper");
    }

    function boundTokenIn(Token token) public view returns (Token) {
        Token[] memory tokens = wrapper.getTokenInList();
        return tokens[uint256(uint160(token.unwrap())) % tokens.length];
    }

    function boundTokenOut(Token token) public view returns (Token) {
        Token[] memory tokens = wrapper.getTokenOutList();
        return tokens[uint256(keccak256(abi.encode(token.unwrap()))) % tokens.length];
    }

    function testFuzz_TokenIn(Token token) public virtual {
        token = boundTokenIn(token);

        uint256 callerBalance = 10 ether;
        deal(token.unwrap(), alice, callerBalance);

        uint256 tokens = 913893305211;

        vm.startPrank(alice);
        uint256 preview = wrapper.previewDeposit(token, tokens);
        uint256 shares = wrapper.deposit{value: token.isNative() ? tokens : 0}(token, tokens, bob);

        assertApproxEqAbs(preview, shares, 3, "preview");
        assertEq(wrapper.balanceOf(bob), shares, "shares");
        if (token.isNative()) {
            assertEq(address(alice).balance, callerBalance - tokens, "tokens");
        } else {
            assertEq(token.erc20().balanceOf(alice), callerBalance - tokens, "tokens");
        }
    }

    function testFuzz_TokenOut(Token token) public virtual {
        testFuzz_TokenIn(token); // setup

        token = boundTokenOut(token);

        uint256 shares = wrapper.balanceOf(bob);
        require(shares > 0, "setup failed");

        uint256 receiverBalance = token.isNative() ? address(alice).balance : token.erc20().balanceOf(alice);

        vm.startPrank(bob);
        uint256 preview = wrapper.previewRedeem(token, shares);
        uint256 tokens = wrapper.redeem(token, shares, alice);

        assertApproxEqAbs(preview, shares, 3, "preview");
        assertEq(wrapper.balanceOf(bob), 0, "shares");
        if (token.isNative()) {
            assertEq(address(alice).balance, receiverBalance + tokens, "tokens");
        } else {
            assertEq(token.erc20().balanceOf(alice), receiverBalance + tokens, "tokens");
        }
    }

    function test_ClaimRewards_RevertWhenNotAuthorized() public virtual {
        vm.startPrank(alice);
        try wrapper.claimRewards() returns (TokenReward[] memory rewards) {
            // If successful, it should return an empty array
            assertEq(rewards.length, 0, "No rewards");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), Errors.AccessManaged_Restricted.selector, "Unauthorized");
        }
    }
}
