// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {Quoter} from "src/lens/Quoter.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Errors} from "src/Errors.sol";
import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

contract PreviewCollectTest is TwoCryptoZapAMMTest {
    function setUp() public override {
        super.setUp();
        _label();

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: 30009218913
        });
        setUpVault(init);
    }

    function testFuzz_PreviewCollects(address account, uint64 timeJump) public {
        skip(timeJump);

        PrincipalToken[] memory pts = new PrincipalToken[](1);
        pts[0] = principalToken;
        Quoter.PreviewCollectResult[] memory result = quoter.previewCollects(pts, account);

        // Interest
        assertEq(result.length, pts.length, "result length mismatch");
        for (uint256 i = 0; i < pts.length; i++) {
            assertEq(result[i].interest, principalToken.previewCollect(account), "interest mismatch");
        }
        // Rewards
        address[] memory tokens = rewardProxy.rewardTokens();
        for (uint256 i = 0; i < pts.length; i++) {
            assertEq(result[i].rewards.length, tokens.length, "rewards length mismatch");

            for (uint256 j = 0; j < pts.length; j++) {
                assertEq(result[i].rewards[j].token, tokens[j]);
                assertEq(
                    result[i].rewards[j].amount, pts[i].getUserReward(tokens[j], account).accrued, "rewards mismatch"
                );
            }
        }
    }

    function testFuzz_WhenRewardProxyNotFound(address account) public {
        vm.mockCallRevert(address(factory), abi.encodeWithSelector(factory.moduleFor.selector), "0x");

        PrincipalToken[] memory pts = new PrincipalToken[](1);
        pts[0] = principalToken;
        Quoter.PreviewCollectResult[] memory result = quoter.previewCollects(pts, account);

        assertEq(result.length, 1, "result length mismatch");
        assertEq(result[0].rewards.length, 0, "result length mismatch");
    }

    function test_RevertWhen_BadPrincipalToken() public {
        PrincipalToken[] memory badPrincipalTokens = new PrincipalToken[](2);
        badPrincipalTokens[0] = principalToken;
        badPrincipalTokens[0] = PrincipalToken(address(0xcafe)); // invalid
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        quoter.previewCollects(badPrincipalTokens, alice);
    }
}
