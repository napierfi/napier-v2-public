// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {ZapPrincipalTokenTest} from "../shared/Zap.t.sol";
import "../Property.sol" as Property;

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

abstract contract BatchCollectBaseTest is ZapPrincipalTokenTest {
    Vm.Wallet wallet = vm.createWallet("babe");

    function setUp() public virtual override {
        super.setUp();

        Init memory init = Init({
            user: [wallet.addr, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: 19038900130000
        });

        uint256 lscale = resolver.scale();
        setUpVault(init);
        require(resolver.scale() > lscale, "TEST: Scale must be greater than initial scale");

        skip(1 days); // Accumulate some rewards for testing
    }

    /// @dev Override this function to test `collectWithPermit` or `collectRewardsWithPermit`
    function batchCollect(TwoCryptoZap.CollectInput[] memory inputs, address receiver) internal virtual;

    struct _Temp {
        uint256 privateKey;
        address owner;
        uint256 nonce;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    function _signPermit(_Temp memory t) internal view {
        bytes32 typeHash = keccak256("PermitCollector(address owner,address collector,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, t.owner, address(zap), t.nonce, t.deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", principalToken.DOMAIN_SEPARATOR(), structHash));
        (t.v, t.r, t.s) = vm.sign(t.privateKey, digest);
    }

    function test_BatchCollect() public {
        FeePcts newFeePcts = FeePctsLib.pack(3000, 10, 10, 100, 100);
        setFeePcts(newFeePcts);

        PrincipalToken[] memory pts = new PrincipalToken[](1);
        pts[0] = principalToken;
        _test_BatchCollect(bob, pts, new bool[](pts.length));
    }

    function test_BatchCollect_When_SkipPermit() public {
        PrincipalToken[] memory pts = new PrincipalToken[](1);
        pts[0] = principalToken;

        // Permit directly
        bool[] memory skips = new bool[](pts.length);
        skips[0] = true;

        _Temp memory t = _Temp({
            privateKey: wallet.privateKey,
            owner: wallet.addr,
            nonce: principalToken.nonces(wallet.addr),
            deadline: block.timestamp,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        _signPermit(t);
        principalToken.permitCollector(t.owner, address(zap), t.deadline, t.v, t.r, t.s);

        _test_BatchCollect(bob, pts, skips);
    }

    function _test_BatchCollect(address receiver, PrincipalToken[] memory pts, bool[] memory skips) internal {
        require(pts.length == skips.length, "TEST: length mismatch");

        uint256[] memory oldRewardBalances = new uint256[](rewardTokens.length);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            oldRewardBalances[i] = SafeTransferLib.balanceOf(rewardTokens[i], receiver);
        }

        TwoCryptoZap.CollectInput[] memory inputs = new TwoCryptoZap.CollectInput[](pts.length);
        for (uint256 i = 0; i < pts.length; i++) {
            _Temp memory t;
            if (!skips[i]) {
                t = _Temp({
                    privateKey: wallet.privateKey,
                    owner: wallet.addr,
                    nonce: pts[i].nonces(wallet.addr),
                    deadline: block.timestamp + 1000,
                    v: 0,
                    r: bytes32(0),
                    s: bytes32(0)
                });
                _signPermit(t);
            }

            TwoCryptoZap.PermitCollectInput memory permit =
                TwoCryptoZap.PermitCollectInput({deadline: t.deadline, v: t.v, r: t.r, s: t.s});
            inputs[i] = TwoCryptoZap.CollectInput({principalToken: address(pts[i]), permit: permit});
        }

        vm.prank(wallet.addr);
        batchCollect(inputs, receiver);

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            assertGt(
                SafeTransferLib.balanceOf(rewardTokens[i], receiver), oldRewardBalances[i], "Reward should be collected"
            );
        }
        assertNoFundLeft();
    }

    function test_RevertWhen_BadPrincipalToken() public {
        PrincipalToken[] memory pts = new PrincipalToken[](2);
        pts[0] = principalToken;
        pts[1] = PrincipalToken(makeAddr("badPrincipalToken"));

        _Temp memory t = _Temp({
            privateKey: wallet.privateKey,
            owner: wallet.addr,
            nonce: principalToken.nonces(wallet.addr),
            deadline: block.timestamp,
            v: 0,
            r: bytes32(0),
            s: bytes32(0)
        });
        _signPermit(t);

        TwoCryptoZap.CollectInput[] memory inputs = new TwoCryptoZap.CollectInput[](pts.length);
        TwoCryptoZap.PermitCollectInput memory permit =
            TwoCryptoZap.PermitCollectInput({deadline: t.deadline, v: t.v, r: t.r, s: t.s});
        inputs[0] = TwoCryptoZap.CollectInput({principalToken: address(pts[0]), permit: permit});
        inputs[1] = TwoCryptoZap.CollectInput({principalToken: address(pts[1]), permit: permit});

        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        vm.prank(wallet.addr);
        batchCollect(inputs, bob);
    }

    function test_RevertWhen_NotApprovedCollector() public {
        PrincipalToken[] memory pts = new PrincipalToken[](1);
        pts[0] = principalToken;

        TwoCryptoZap.CollectInput[] memory inputs = new TwoCryptoZap.CollectInput[](pts.length);

        TwoCryptoZap.PermitCollectInput memory permit;
        inputs[0] = TwoCryptoZap.CollectInput({principalToken: address(pts[0]), permit: permit});

        vm.expectRevert(Errors.PrincipalToken_NotApprovedCollector.selector);
        vm.prank(wallet.addr);
        batchCollect(inputs, bob);
    }
}

contract BatchCollectTest is BatchCollectBaseTest {
    function batchCollect(TwoCryptoZap.CollectInput[] memory inputs, address receiver) internal override {
        zap.collectWithPermit(inputs, receiver);
    }
}

contract BatchCollectRewardsTest is BatchCollectBaseTest {
    function setUp() public override {
        super.setUp();

        vm.prank(wallet.addr);
        principalToken.combine(0, wallet.addr); // Accrued rewards for wallet
    }

    function batchCollect(TwoCryptoZap.CollectInput[] memory inputs, address receiver) internal override {
        address[][] memory rewardTokensInputs = new address[][](inputs.length);
        for (uint256 i = 0; i < inputs.length; i++) {
            rewardTokensInputs[i] = rewardTokens;
        }
        zap.collectRewardsWithPermit(inputs, rewardTokensInputs, receiver);
    }

    function test_RevertWhen_LengthMismatch() public {
        PrincipalToken[] memory pts = new PrincipalToken[](1);
        pts[0] = principalToken;

        TwoCryptoZap.CollectInput[] memory inputs = new TwoCryptoZap.CollectInput[](pts.length);
        address[][] memory rewardTokensInputs = new address[][](pts.length + 1);

        vm.expectRevert(Errors.Zap_LengthMismatch.selector);
        vm.prank(wallet.addr);
        zap.collectRewardsWithPermit(inputs, rewardTokensInputs, bob);
    }
}
