// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {TwoCryptoZapBase} from "../../TwoCryptoBase.t.sol";
import {Impersonator} from "src/lens/twocrypo/Impersonator.sol";
import {TwoCryptoZap} from "src/zap/twocrypto/TwoCryptoZap.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";

import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import "src/Types.sol";
import "src/Constants.sol";

using LibTwoCryptoNG for TwoCrypto;

contract PoCForkTest is TwoCryptoZapBase {
    address lens;

    constructor() {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22116000);
    }

    Impersonator dummy = new Impersonator();

    function setImpersonator(address addr) internal {
        vm.etch(addr, type(Impersonator).runtimeCode);
    }

    function setUp() public override {
        assembly {
            // system
            sstore(weth.slot, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)
            // core
            sstore(napierAccessManager.slot, 0x000000C196dBD8c8b737F95507C2C39271CdcC99)
            sstore(factory.slot, 0x0000001afbCA1E8CF82fe458B33C9954A65b987B)
            // modules
            sstore(twocryptoDeployer.slot, 0x129D398a6116a13Cc0D1AE8833B0490C2D53Cf37)
            // instance
            sstore(twocrypto.slot, 0x7cb27098c046d70c6783d07759813e5591e7789a)
            // periphery
            sstore(zap.slot, 0x0000001d41857cb60F6BE0C9Fe74B9e69E1e5234)
            sstore(quoter.slot, 0x0000006182e8f8B89419159efe131ed65764bCbd)
            sstore(lens.slot, 0x0000006178ee874e0ae58b131b8a5fcbe78cab2f)
        }

        address _pt = twocrypto.coins(PT_INDEX);
        address _target = twocrypto.coins(TARGET_INDEX);
        address _base = address(PrincipalToken(_pt).i_asset());
        address _yt = address(PrincipalToken(_pt).i_yt());

        assembly {
            sstore(principalToken.slot, _pt)
            sstore(target.slot, _target)
            sstore(base.slot, _base)
            sstore(yt.slot, _yt)
        }

        setImpersonator(alice);
    }

    function testFork_POC() internal {
        vm.skip(true);

        uint256 amount = twocrypto.balances(PT_INDEX) / 10;
        deal(address(yt), alice, amount);

        TwoCryptoZap.SwapYtParams memory params = TwoCryptoZap.SwapYtParams({
            twoCrypto: twocrypto,
            principal: amount,
            tokenOut: Token.wrap(address(target)),
            receiver: alice,
            amountOutMin: 0,
            deadline: block.timestamp + 1 hours
        });

        vm.startPrank(alice);

        uint256 snapshot = vm.snapshot();
        uint256 toleranceBps = 10; // 0.1%
        (
            uint256 previewAmountOut,
            uint256 ytSpentPreview,
            ApproxValue dxResultWithMargin,
            /* uint256 priceInAssetWei */
            ,
            /* int256 impliedApyWei */
            ,
            /* uint256 executionPrice */
        ) = Impersonator(payable(alice)).querySwapYtForToken(
            address(zap), quoter, twocrypto, params.tokenOut, params.principal, toleranceBps
        );
        vm.revertTo(snapshot);

        uint256 balanceBefore = yt.balanceOf(alice);
        yt.approve(address(zap), type(uint256).max);
        uint256 amountOut = zap.swapYtForToken(params, dxResultWithMargin);
        uint256 balanceAfter = yt.balanceOf(alice);

        console2.log("Input YT %e", params.principal);
        console2.log("Preview YT spent %e", ytSpentPreview);
        console2.log("Actual YT spent %e", balanceBefore - balanceAfter);
        console2.log(
            "(Input - Actual) / Input", (params.principal - (balanceBefore - balanceAfter)) * 1e18 / params.principal
        );

        console2.log("Preview amount out %e", previewAmountOut);
        console2.log("Actual amount out %e", amountOut);

        vm.stopPrank();
    }
}
