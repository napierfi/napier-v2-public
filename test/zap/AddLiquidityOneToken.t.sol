// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {TwoCrypto, LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract AddLiquidityOneTokenTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public virtual override {
        super.setUp();
        _label();

        // Principal Token should be discounted against underlying token
        uint256 initialPrincipal = 140_000 * tOne;
        uint256 initialShare = 100_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        vm.startPrank(alice);
        deal(address(base), alice, 1e18 * bOne);
        base.approve(address(target), type(uint256).max);
        uint256 shares = target.deposit(1e18 * bOne, alice);
        target.approve(address(principalToken), type(uint256).max);
        principalToken.supply(shares, alice);
        vm.stopPrank();
    }

    function test_DepositUnderlying() public {
        Token token = address(target).intoToken();
        uint256 sharesIn = 10 * 10 ** target.decimals();

        deal(token, alice, sharesIn);

        FeePcts newFeePcts = FeePctsLib.pack(3000, 100, 10, 100, 20);
        setFeePcts(newFeePcts);

        _test_Deposit(alice, bob, token, sharesIn);
    }

    function test_DepositBaseAsset() public {
        Token token = address(base).intoToken();
        uint256 assetsIn = 1212113133121;

        deal(token, alice, assetsIn);

        FeePcts newFeePcts = FeePctsLib.pack(3000, 55, 200, 100, 20);
        setFeePcts(newFeePcts);

        _test_Deposit(alice, bob, token, assetsIn);
    }

    function testFuzz_Deposit(SetupAMMFuzzInput memory input, Token token, uint256 amount, FeePcts newFeePcts)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        token = boundToken(token);
        amount = bound(amount, 0, type(uint88).max);

        address caller = alice;
        deal(token, caller, amount);

        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Deposit(caller, bob, token, amount);
    }

    function _test_Deposit(address caller, address receiver, Token token, uint256 amount) internal {
        uint256 oldLiquidityBalance = twocrypto.balanceOf(receiver);
        uint256 oldYtBalnce = yt.balanceOf(receiver);
        (uint256 oldBalance0, uint256 oldBalance1) = (twocrypto.balances(0), twocrypto.balances(1));

        if (token.isNative()) {
            amount = bound(amount, 0, caller.balance);
        } else {
            amount = bound(amount, 0, SafeTransferLib.balanceOf(token.unwrap(), caller));
            _approve(token, caller, address(zap), amount);
        }

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: token,
            amountIn: amount,
            receiver: bob,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        vm.prank(caller);
        (bool s, bytes memory ret) =
            address(zap).call{value: token.isNative() ? amount : 0}(abi.encodeCall(zap.addLiquidityOneToken, (params)));
        vm.assume(s);
        (uint256 liquidity, uint256 principal) = abi.decode(ret, (uint256, uint256));

        assertEq(twocrypto.balanceOf(bob) - oldLiquidityBalance, liquidity, "liquidity balance");
        assertEq(yt.balanceOf(bob) - oldYtBalnce, principal, "yt balance");
        assertNoFundLeft();

        // Assert zero price impact (reserve ratio doesn't change much)
        (uint256 newBalance0, uint256 newBalance1) = (twocrypto.balances(0), twocrypto.balances(1));
        assertApproxEqRel(
            oldBalance0 * newBalance1, oldBalance1 * newBalance0, 0.000001e18, "price impact should be negligible"
        );
    }

    function test_RevertWhen_BadToken() public {
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = toyParams();
        params.tokenIn = address(randomToken).intoToken();
        deal(params.tokenIn, address(this), params.amountIn);
        _approve(params.tokenIn, address(this), address(zap), params.amountIn);
        vm.expectRevert(Errors.ERC4626Connector_InvalidToken.selector);
        zap.addLiquidityOneToken(params);
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientYtOut() public {
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = toyParams();
        params.tokenIn = address(base).intoToken();

        deal(params.tokenIn, alice, params.amountIn);
        _approve(params.tokenIn, alice, address(zap), type(uint256).max);

        params.minYt = 100001e18;
        params.minLiquidity = 0;
        vm.expectRevert(Errors.Zap_InsufficientYieldTokenOutput.selector);
        vm.prank(alice);
        zap.addLiquidityOneToken(params);
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientLiquidity() public {
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = toyParams();
        params.tokenIn = address(base).intoToken();

        deal(params.tokenIn, alice, params.amountIn);
        _approve(params.tokenIn, alice, address(zap), type(uint256).max);

        params.minYt = 0;
        params.minLiquidity = 1e55;
        vm.expectRevert();
        vm.prank(alice);
        zap.addLiquidityOneToken(params);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.addLiquidityOneToken(params);
    }

    function toyParams() internal view returns (TwoCryptoZap.AddLiquidityOneTokenParams memory) {
        return TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: address(base).intoToken(),
            amountIn: 1e18,
            receiver: alice,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });
    }
}

contract AddLiquidityOneETHTest is AddLiquidityOneTokenTest {
    function _deployTokens() internal override {
        _deployWETHVault();
    }

    function validTokenInput() internal view override returns (address[] memory tokens) {
        tokens = new address[](3);
        tokens[0] = address(target);
        tokens[1] = address(base);
        tokens[2] = NATIVE_ETH;
    }

    function test_DepositNativeETH() public {
        Token token = NATIVE_ETH.intoToken();
        uint256 value = 10 ether;

        vm.deal(alice, value);

        _test_Deposit(alice, bob, token, value);
    }

    function test_RevertWhen_InsufficientETH() public {
        TwoCryptoZap.AddLiquidityOneTokenParams memory params = toyParams();
        params.tokenIn = NATIVE_ETH.intoToken();
        params.amountIn = 100;

        vm.expectRevert(Errors.Zap_InsufficientETH.selector);
        zap.addLiquidityOneToken{value: 99}(params);
    }
}

contract AddLiquidityOneTokenForkTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant MORPHO_VAULT_USDC = 0xd63070114470f685b75B74D60EEc7c1113d33a3D;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20976838);
    }

    function _deployTokens() internal override {
        target = MockERC4626(MORPHO_VAULT_USDC);
        base = MockERC20(USDC);
    }

    function setUp() public override {
        super.setUp();
        _label();

        deal(MORPHO_VAULT_USDC, alice, 1_000 * tOne);
    }

    function testFork_WhenZeroTotalSupply() public {
        uint256 amount = 1_000 * tOne;
        _testFork_DepositUnderlying(amount);
    }

    function testFork_WhenNonZeroTotalSupply() public {
        uint256 amount = 1_000 * tOne;

        _testFork_DepositUnderlying(amount);

        deal(MORPHO_VAULT_USDC, alice, 1_000 * tOne);
        _testFork_DepositUnderlying(amount);
    }

    function _testFork_DepositUnderlying(uint256 amount) internal {
        uint256 oldLiquidityBalance = twocrypto.balanceOf(bob);
        uint256 oldYtBalnce = yt.balanceOf(bob);
        (uint256 oldBalance0, uint256 oldBalance1) = (twocrypto.balances(0), twocrypto.balances(1));

        _approve(MORPHO_VAULT_USDC, alice, address(zap), amount);

        TwoCryptoZap.AddLiquidityOneTokenParams memory params = TwoCryptoZap.AddLiquidityOneTokenParams({
            twoCrypto: twocrypto,
            tokenIn: MORPHO_VAULT_USDC.intoToken(),
            amountIn: amount,
            receiver: bob,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });

        vm.prank(alice);
        (uint256 liquidity, uint256 principal) = zap.addLiquidityOneToken(params);

        assertEq(twocrypto.balanceOf(bob) - oldLiquidityBalance, liquidity, "liquidity balance");
        assertEq(yt.balanceOf(bob) - oldYtBalnce, principal, "yt balance");
        assertNoFundLeft();

        // Assert zero price impact (reserve ratio doesn't change much)
        (uint256 newBalance0, uint256 newBalance1) = (twocrypto.balances(0), twocrypto.balances(1));
        assertApproxEqRel(
            oldBalance0 * newBalance1, oldBalance1 * newBalance0, 0.000001e18, "price impact should be negligible"
        );
    }
}
