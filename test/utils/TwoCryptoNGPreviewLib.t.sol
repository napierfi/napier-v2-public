// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";
import {ITwoCrypto} from "../shared/ITwoCrypto.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {MockERC20} from "../mocks/MockERC20.sol";
import {TwoCryptoNGPrecompiles, TwoCryptoNGParams} from "../TwoCryptoNGPrecompiles.sol";

import "src/Types.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";

import {TwoCryptoNGPreviewLib} from "src/utils/TwoCryptoNGPreviewLib.sol";

contract TwoCryptoNGPreviewLibTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public virtual override {
        super.setUp();
        _label();

        // Principal Token should be discounted against underlying token
        uint256 initialPrincipal = 14_000_000 * tOne;
        uint256 initialShare = 1_000_000 * tOne;

        // Setup initial AMM liquidity
        setUpAMM(AMMInit({user: makeAddr("bocchi"), share: initialShare, principal: initialPrincipal}));

        vm.startPrank(alice);
        deal(address(base), alice, 1e10 * bOne);
        base.approve(address(target), type(uint256).max);
        target.deposit(1e10 * bOne, alice);
        target.approve(address(principalToken), type(uint256).max);
        principalToken.issue(1e9 * tOne, alice); // fee may be charged
        vm.stopPrank();

        skip(1 days); // Advance time to accrue rewards
    }

    function _deployTokens() internal override {
        _deployWETHVault();
    }

    modifier boundSetupAMMFuzzInput(SetupAMMFuzzInput memory input) override {
        uint256 price = ITwoCrypto(twocrypto.unwrap()).last_prices(); // coin1 price in terms of coin0 in wei
        input.deposits[1] = bound(input.deposits[1], 1e6, 1_000_000 * tOne);
        input.deposits[0] = bound(input.deposits[0], 0, input.deposits[1] * price / 1e18);
        input.timestamp = bound(input.timestamp, block.timestamp, expiry - 1);
        input.yield = bound(input.yield, -10_000 * int256(bOne), int256(10_000 * bOne));
        _;
    }

    /// forge-config: default.fuzz.runs = 1000
    /// @notice Preview result get_dy(approx_dx) should be always less than or equal to actual dy
    function testFuzz_Preview(SetupAMMFuzzInput memory input, uint256 dy)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        // Ignore the case where the previewer fails.
        try this.ext_previews(dy) returns (uint256, /* appxDx */ uint256 appxDy) {
            assertGe(dy, appxDy, "dy >= appxDy");
        } catch {}
    }

    // If native get_dx succeeds, the result of binsearch_dx should succeed
    function testFuzz_NotRevert(SetupAMMFuzzInput memory input, uint256 dy)
        public
        boundSetupAMMFuzzInput(input)
        fuzzAMMState(input)
    {
        dy = bound(dy, tOne, 1_000_000 * tOne);

        // Ignore the case where the native get_dx fails.
        (bool s, bytes memory ret) =
            twocrypto.unwrap().staticcall(abi.encodeWithSignature("get_dx(uint256,uint256,uint256)", 0, 1, dy));
        vm.assume(s);
        uint256 dx = abi.decode(ret, (uint256));
        // If the native get_dy fails, the binsearch_dx will fail as well. So we don't care about it.
        (s,) = twocrypto.unwrap().staticcall(abi.encodeWithSignature("get_dy(uint256,uint256,uint256)", 0, 1, dx));
        vm.assume(s);

        uint256 result = TwoCryptoNGPreviewLib.binsearch_dx(twocrypto, 0, 1, dy);
        // We don't care about the result, we just want to make sure it doesn't revert
        result;
    }

    function ext_previews(uint256 dy) external view returns (uint256, uint256) {
        uint256 approxDx = TwoCryptoNGPreviewLib.binsearch_dx(twocrypto, 0, 1, dy);
        uint256 approxDy = twocrypto.get_dy(0, 1, approxDx);
        return (approxDx, approxDy);
    }

    /// @notice Randomly test binsearch_dx with mock
    function testFuzz_Binsearch(uint256 targetDy) public {
        targetDy = bound(targetDy, 10, 1e30);

        MockTwoCrypto instance = new MockTwoCrypto();
        vm.etch(twocrypto.unwrap(), address(instance).code);

        MockTwoCrypto(twocrypto.unwrap()).set_coins(address(target), address(principalToken));

        uint256 dx = TwoCryptoNGPreviewLib.binsearch_dx(twocrypto, 0, 1, targetDy);
        dx;
    }

    function test_Binsearch() public {
        MockERC20 coin0 = new MockERC20(6);
        MockERC20 coin1 = new MockERC20(18);

        twocrypto = TwoCrypto.wrap(
            TwoCryptoNGPrecompiles.deployTwoCrypto(
                address(twoCryptoFactory), "test", "test", [address(coin0), address(coin1)], 0, twocryptoParams
            )
        );

        coin0.mint(alice, 1_000_000 * 1e6);
        coin1.mint(alice, 1_000_000 * 1e18);

        vm.startPrank(alice);
        coin0.approve(twocrypto.unwrap(), type(uint256).max);
        coin1.approve(twocrypto.unwrap(), type(uint256).max);

        twocrypto.add_liquidity(1_000_000 * 1e6, 1_000_000 * 1e18, 0, alice);

        vm.stopPrank();
        uint256 i = 1;
        uint256 j = 0;

        uint256 approxDx1 = twocrypto.get_dx(i, j, 313003 * 1e6);
        uint256 dx1 = TwoCryptoNGPreviewLib.binsearch_dx(twocrypto, i, j, 313003 * 1e6);
        assertApproxEqRel(dx1, approxDx1, 0.00001e18);
    }
}

contract MockTwoCrypto {
    address[2] public coins;

    function get_dy(uint256, uint256, uint256 dx) external pure returns (uint256) {
        uint256 a = 130 * dx + 3239093;
        uint256 b = 390 * dx;
        if (a > b) return b;
        return a;
    }

    function set_coins(address coin0, address coin1) external {
        coins[0] = coin0;
        coins[1] = coin1;
    }
}
