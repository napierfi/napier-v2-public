// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapForkTest} from "../shared/Fork.t.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;
import {RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

using {TokenType.intoToken} for address;

contract ZapSupplyAnyTokenTest is ZapForkTest {
    /// @notice 1inch payload for swapping 100 USDC to native ETH
    uint256 constant amountUSDC = 100e6;
    bytes constant ONEINCH_SWAP_CALL_DATA =
        hex"e2c95c82000000000000000000000000000c632910d6be3ef6601420bb35dab2a6f2ede7000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480000000000000000000000000000000000000000000000000000000005f5e100000000000000000000000000000000000000000000000000008b95fa3798d32d18800000000000003b6d03403aa370aacf4cb08c7e1e7aa8e8ff9418d73c7e0ffa7a9b25";

    Init init = toyInit();

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 21041095);
    }

    // alice :>> 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6
    // bob :>> 0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e
    function setUp() public override {
        super.setUp();
    }

    function toySwapInput() internal pure returns (TwoCryptoZap.SwapTokenInput memory) {
        RouterPayload memory swapData = RouterPayload({router: ONE_INCH_ROUTER, payload: ONEINCH_SWAP_CALL_DATA});
        return TwoCryptoZap.SwapTokenInput({tokenMintShares: NATIVE_ETH.intoToken(), swapData: swapData});
    }

    function toyInit() internal returns (Init memory) {
        return Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: int256(1e18)
        });
    }

    /// @notice USDC -> [1inch] -> native ETH -> [connector] -> pufETH -> [PrincipalToken] -> PT, YT
    function test_Supply() public {
        address caller = init.user[0];
        address receiver = init.user[1];

        Token token = USDC;
        uint256 assets = amountUSDC;

        FeePcts newFeePcts = FeePctsLib.pack(3000, 1021, 10, 100, 2122);
        setFeePcts(newFeePcts);

        _test_Supply(caller, receiver, token, assets);
    }

    /// @notice Test `supplyAnyToken` function
    function _test_Supply(address caller, address receiver, Token token, uint256 amount) internal {
        uint256 oldPtBalance = principalToken.balanceOf(receiver);
        uint256 oldYtBalnce = yt.balanceOf(receiver);
        uint256 minPrincipal = 0;

        if (token.isNative()) {
            deal(caller, amount);
        } else {
            deal(token, caller, amount);
            _approve(token, caller, address(zap), amount);
        }

        vm.prank(caller);
        uint256 principal = zap.supplyAnyToken{value: token.isNative() ? amount : 0}(
            principalToken, token, amount, receiver, minPrincipal, toySwapInput()
        );
        assertGt(principal, 0, "Principal > 0");
        assertGe(principal, minPrincipal, "Principal >= minPrincipal");
        assertEq(principalToken.balanceOf(receiver) - oldPtBalance, principal, "PT mismatch");
        assertEq(yt.balanceOf(receiver) - oldYtBalnce, principal, "YT mismatch");
        assertNoFundLeft();
    }

    function test_RevertWhen_BadPrincipalToken() public {
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.supplyAnyToken(
            PrincipalToken(makeAddr("badPrincipalToken")), address(base).intoToken(), 10000, alice, 0, toySwapInput()
        );
    }

    function test_RevertWhen_BadToken() public {
        vm.skip(true);
    }

    function test_RevertWhen_InsufficientETHReceived() public {
        uint256 value = 10000;
        vm.expectRevert(Errors.Zap_InconsistentETHReceived.selector);
        zap.supplyAnyToken{value: value - 1}(principalToken, NATIVE_ETH.intoToken(), value, alice, 0, toySwapInput());
    }

    function test_RevertWhen_SlippageTooLarge() public {
        deal(USDC, alice, amountUSDC);
        _approve(USDC, alice, address(zap), type(uint256).max);

        vm.expectRevert(Errors.Zap_InsufficientPrincipalOutput.selector);
        vm.prank(alice);
        zap.supplyAnyToken(
            principalToken,
            USDC,
            amountUSDC,
            alice,
            type(uint128).max, // Incredibly large principal to trigger slippage error
            toySwapInput()
        );
    }

    function test_RevertWhen_NonNativeTokenWithValue() public {
        deal(USDC, alice, amountUSDC);
        deal(alice, 1 ether);
        _approve(USDC, alice, address(zap), amountUSDC);

        vm.expectRevert(Errors.Zap_InconsistentETHReceived.selector);
        vm.prank(alice);
        zap.supplyAnyToken{value: 1 ether}(principalToken, USDC, amountUSDC, alice, 0, toySwapInput());
    }
}
