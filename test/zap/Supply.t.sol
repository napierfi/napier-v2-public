// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapPrincipalTokenTest} from "../shared/Zap.t.sol";
import "../Property.sol" as Property;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract ZapSupplyTest is ZapPrincipalTokenTest {
    function toyInit() internal returns (Init memory init) {
        init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: int256(1e18)
        });
    }

    function test_SupplyUnderlying() public {
        Init memory init = toyInit();
        Token token = address(target).intoToken();
        uint256 shares = 10 ** target.decimals();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 10, 10, 100, BASIS_POINTS);
        setFeePcts(newFeePcts);

        _test_Supply(init, token, shares);
    }

    function test_SupplyBaseAsset() public {
        Init memory init = toyInit();
        Token token = address(base).intoToken();
        uint256 assets = 10 ** base.decimals();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 10, 10, 100, BASIS_POINTS);
        setFeePcts(newFeePcts);

        deal(token, init.user[0], assets); // Ensure caller has enough assets

        _test_Supply(init, token, assets);
    }

    function testFuzz_Supply(Init memory init, Token token, uint256 amount, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        address caller = init.user[0];

        token = boundToken(token);
        if (token.isNotNative()) deal(token, caller, amount);
        else deal(caller, amount); // Native ETH

        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Supply(init, token, amount);
    }

    /// @notice Test `supply` function
    function _test_Supply(Init memory init, Token token, uint256 amount) internal {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];

        uint256 oldPtBalance = principalToken.balanceOf(receiver);
        uint256 oldYtBalnce = yt.balanceOf(receiver);
        uint256 minPrincipal = 100_000;

        if (token.isNative()) {
            amount = bound(amount, 0, caller.balance);
        } else {
            amount = bound(amount, 0, SafeTransferLib.balanceOf(token.unwrap(), caller));
            _approve(token, caller, address(zap), amount);
        }

        vm.prank(caller);
        (bool s, bytes memory ret) = address(zap).call{value: token.isNative() ? amount : 0}(
            abi.encodeCall(zap.supply, (principalToken, token, amount, receiver, minPrincipal))
        );
        vm.assume(s);

        uint256 principal = abi.decode(ret, (uint256));
        assertGe(principal, minPrincipal, "Principal >= minPrincipal");
        assertEq(principalToken.balanceOf(receiver) - oldPtBalance, principal, "PT mismatch");
        assertEq(yt.balanceOf(receiver) - oldYtBalnce, principal, "YT mismatch");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.supply(PrincipalToken(makeAddr("badPrincipalToken")), address(base).intoToken(), 10000, alice, 0);
    }

    function test_RevertWhen_BadToken() public {
        deal(address(randomToken), address(this), 10000);
        _approve(address(randomToken), address(this), address(zap), 10000);
        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.supply(principalToken, address(randomToken).intoToken(), 10000, alice, 0);
    }

    function test_RevertWhen_BadCallback() public {
        address caller = alice;
        deal(address(target), alice, 10000);
        _approve(target, caller, address(zap), type(uint256).max);

        vm.prank(caller);
        zap.supply(principalToken, address(target).intoToken(), 100, alice, 1);

        vm.expectRevert(Errors.Zap_BadCallback.selector);
        zap.onSupply(100, 100, "jjj");
    }

    function test_RevertWhen_SlippageTooLarge() public {
        address caller = alice;
        deal(address(target), alice, 10000);
        _approve(target, caller, address(zap), type(uint256).max);

        vm.expectRevert(Errors.Zap_InsufficientPrincipalOutput.selector);
        vm.prank(caller);
        zap.supply(principalToken, address(target).intoToken(), 100, alice, 10000);
    }
}

contract ZapSupplyETHTest is ZapSupplyTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_SupplyNativeETH() public {
        Init memory init = toyInit();
        Token token = Token.wrap(NATIVE_ETH);
        uint256 value = 10 ether;

        vm.deal(init.user[0], value);

        _test_Supply(init, token, value);
    }

    function test_RevertWhen_InsufficientETH() public {
        vm.expectRevert(Errors.Zap_InsufficientETH.selector);
        zap.supply{value: 99}(principalToken, NATIVE_ETH.intoToken(), 100, alice, 0);
    }
}
