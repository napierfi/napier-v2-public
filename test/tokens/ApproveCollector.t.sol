// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {Events} from "src/Events.sol";

contract ApproveCollectorTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
    }

    function test_SetApproveCollector() public {
        address owner = makeAddr("L");
        address collector = makeAddr("Kira");

        assertFalse(principalToken.isApprovedCollector(owner, collector), "not approved");

        vm.expectEmit(true, true, true, true);
        emit Events.SetApprovalCollector({owner: owner, collector: collector, approved: true});

        vm.prank(owner);
        principalToken.setApprovalCollector(collector, true);
        assertTrue(principalToken.isApprovedCollector(owner, collector), "approved");

        vm.expectEmit(true, true, true, true);
        emit Events.SetApprovalCollector({owner: owner, collector: collector, approved: false});

        vm.prank(owner);
        principalToken.setApprovalCollector(collector, false);
        assertFalse(principalToken.isApprovedCollector(owner, collector), "not approved again");
    }

    function test_Permit() public {
        uint256 privKey = 0x1234567890abcdef;
        address signer = vm.addr(privKey);
        address collector = makeAddr("nina");
        _test_Permit(signer, privKey, collector);
    }

    function testFuzz_Permit(string calldata keyLabel, address collector) public {
        vm.assume(collector != address(0));
        Vm.Wallet memory wallet = vm.createWallet(keyLabel);
        _test_Permit(wallet.addr, wallet.privateKey, collector);
    }

    struct _Temp {
        uint256 privateKey;
        address owner;
        address collector;
        uint256 nonce;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
        bytes32 digest;
    }

    function _test_Permit(address signer, uint256 privateKey, address collector) internal {
        uint256 nonce = principalToken.nonces(signer);
        uint256 deadline = block.timestamp;

        _Temp memory t;
        t.privateKey = privateKey;
        t.owner = signer;
        t.collector = collector;
        t.nonce = nonce;
        t.deadline = deadline;

        _signPermit(t);

        address recoveredAddress = ecrecover(t.digest, t.v, t.r, t.s);
        assertEq(recoveredAddress, signer, "recoveredAddress");

        vm.expectEmit(true, true, true, true);
        emit Events.SetApprovalCollector({owner: signer, collector: collector, approved: true});

        vm.prank(alice);
        principalToken.permitCollector(signer, collector, deadline, t.v, t.r, t.s);

        assertTrue(principalToken.isApprovedCollector(signer, collector), "approved");
        assertEq(principalToken.nonces(signer), nonce + 1, "Incremented nonce");
    }

    function _toyData() internal returns (_Temp memory t) {
        t.privateKey = 0x1234567890abcdef;
        t.owner = vm.addr(t.privateKey);
        t.collector = makeAddr("nina");
        t.nonce = principalToken.nonces(t.owner);
        t.deadline = block.timestamp;
    }

    function test_RevertWhen_Expired() public {
        _Temp memory t = _toyData();
        t.deadline = block.timestamp - 1;

        _signPermit(t);

        vm.expectRevert(ERC20.PermitExpired.selector);
        principalToken.permitCollector(t.owner, t.collector, t.deadline, t.v, t.r, t.s);
    }

    function test_RevertWhen_Replay() public {
        _Temp memory t = _toyData();

        _signPermit(t);
        principalToken.permitCollector(t.owner, t.collector, t.deadline, t.v, t.r, t.s);

        vm.expectRevert(ERC20.InvalidPermit.selector);
        principalToken.permitCollector(t.owner, t.collector, t.deadline, t.v, t.r, t.s);
    }

    function test_RevertWhen_BadNonce() public {
        _Temp memory t = _toyData();

        t.nonce = 22;
        _signPermit(t);

        vm.expectRevert(ERC20.InvalidPermit.selector);
        principalToken.permitCollector(t.owner, t.collector, t.deadline, t.v, t.r, t.s);
    }

    function test_RevertWhen_InvalidPermit() public {
        _Temp memory t = _toyData();

        _signPermit(t);

        t.r = keccak256("bad");
        vm.expectRevert(ERC20.InvalidPermit.selector);
        principalToken.permitCollector(t.owner, t.collector, t.deadline, t.v, t.r, t.s);
    }

    function _signPermit(_Temp memory t) internal view {
        bytes32 typeHash = keccak256("PermitCollector(address owner,address collector,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, t.owner, t.collector, t.nonce, t.deadline));
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", principalToken.DOMAIN_SEPARATOR(), structHash));

        t.digest = expectedDigest;
        (t.v, t.r, t.s) = vm.sign(t.privateKey, expectedDigest);
    }
}
