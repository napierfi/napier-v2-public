// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.25;

import "forge-std/src/Test.sol";

import {UniswapV4ZapBase} from "../../UniswapV4Base.t.sol";

import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import "src/Types.sol";
import "src/Errors.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";
import {PrincipalTokenRouter} from "src/zap/modules/PrincipalTokenRouter.sol";

contract CollectTest is UniswapV4ZapBase {
    // Test wallet for permit signatures
    Vm.Wallet testWallet = vm.createWallet("collector");

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployPeriphery();
        _deployInstance();

        // Setup user with base tokens and convert to target vault shares
        deal(address(base), testWallet.addr, 1000 * bOne);

        vm.startPrank(testWallet.addr);
        base.approve(address(target), type(uint256).max);
        target.deposit(500 * bOne, testWallet.addr);
        vm.stopPrank();

        // Supply PT/YT tokens to users for collect testing
        _supplyPrincipal(testWallet.addr);

        // Pump up and generate some yield
        deal(address(base), alice, 1000 * bOne);
        vm.prank(alice);
        base.transfer(address(target), 100 * bOne);
    }

    function _supplyPrincipal(address user) internal {
        uint256 supplyAmount = 100 * tOne;

        _approve(address(target), user, address(principalToken), supplyAmount);
        vm.prank(user);
        principalToken.supply(supplyAmount, user);
    }

    function _createPermitSignature(address owner, uint256 privateKey, uint256 deadline)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 typeHash = keccak256("PermitCollector(address owner,address collector,uint256 nonce,uint256 deadline)");
        uint256 nonce = principalToken.nonces(owner);
        bytes32 structHash = keccak256(abi.encode(typeHash, owner, address(zap), nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", principalToken.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(privateKey, digest);
    }

    function test_PrincipalTokenCollect() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _createPermitSignature(testWallet.addr, testWallet.privateKey, deadline);

        // Check initial balances
        uint256 targetBalanceBefore = target.balanceOf(bob);
        uint256 shares = principalToken.previewCollect(testWallet.addr);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COLLECT)));
        bytes[] memory inputs = new bytes[](1);

        PrincipalTokenRouter.PermitCollectInput memory permit =
            PrincipalTokenRouter.PermitCollectInput({deadline: deadline, v: v, r: r, s: s});

        inputs[0] = abi.encode(principalToken, bob, permit);

        vm.prank(testWallet.addr);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Bob should have received collected yield
        assertApproxEqAbs(targetBalanceAfter, targetBalanceBefore + shares, 1, "bob");

        assertNoFundLeftInZap();
    }

    function test_PrincipalTokenCollectWhen_SkipPermit() public {
        // Pre-approve the zap to collect on behalf of testWallet
        vm.prank(testWallet.addr);
        principalToken.setApprovalCollector(address(zap), true);

        // Check initial balances
        uint256 targetBalanceBefore = target.balanceOf(bob);
        uint256 shares = principalToken.previewCollect(testWallet.addr);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COLLECT)));
        bytes[] memory inputs = new bytes[](1);

        // Use zero deadline to skip permit
        PrincipalTokenRouter.PermitCollectInput memory permit;

        inputs[0] = abi.encode(principalToken, bob, permit);

        vm.prank(testWallet.addr);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Bob should have received collected yield
        assertGt(targetBalanceAfter, targetBalanceBefore, "Bob should receive yield");

        assertApproxEqAbs(targetBalanceAfter, targetBalanceBefore + shares, 1, "bob");
    }

    function test_PrincipalTokenCollectWhen_AddressThis() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _createPermitSignature(testWallet.addr, testWallet.privateKey, deadline);

        // Check initial balances
        uint256 targetBalanceBefore = target.balanceOf(address(zap));
        uint256 yield = principalToken.previewCollect(testWallet.addr);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COLLECT)));
        bytes[] memory inputs = new bytes[](1);

        PrincipalTokenRouter.PermitCollectInput memory permit =
            PrincipalTokenRouter.PermitCollectInput({deadline: deadline, v: v, r: r, s: s});

        inputs[0] = abi.encode(principalToken, ActionConstants.ADDRESS_THIS, permit);

        vm.prank(testWallet.addr);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 targetBalanceAfter = target.balanceOf(address(zap));

        assertApproxEqAbs(targetBalanceAfter, targetBalanceBefore + yield, 1, "zap");
    }

    function test_PrincipalTokenCollectWhen_MsgSender() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _createPermitSignature(testWallet.addr, testWallet.privateKey, deadline);

        // Check initial balances
        uint256 targetBalanceBefore = target.balanceOf(testWallet.addr);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COLLECT)));
        bytes[] memory inputs = new bytes[](1);

        PrincipalTokenRouter.PermitCollectInput memory permit =
            PrincipalTokenRouter.PermitCollectInput({deadline: deadline, v: v, r: r, s: s});

        inputs[0] = abi.encode(principalToken, ActionConstants.MSG_SENDER, permit);

        vm.prank(testWallet.addr);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 targetBalanceAfter = target.balanceOf(testWallet.addr);

        // testWallet should have received collected yield
        assertGt(targetBalanceAfter, targetBalanceBefore, "testWallet should receive yield");

        // No funds should be left in the zap
        assertNoFundLeftInZap();
    }

    function test_RevertWhen_InvalidPrincipalToken() public {
        // Create a fake principal token address
        address fakePrincipalToken = address(0x123);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COLLECT)));
        bytes[] memory inputs = new bytes[](1);

        PrincipalTokenRouter.PermitCollectInput memory permit;

        inputs[0] = abi.encode(fakePrincipalToken, bob, permit);

        vm.prank(testWallet.addr);
        vm.expectRevert(Errors.Zap_BadPrincipalToken.selector);
        zap.execute(commands, inputs);
    }

    function test_PrincipalTokenCollectWhen_PermitFrontrun() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _createPermitSignature(testWallet.addr, testWallet.privateKey, deadline);

        // Simulate frontrunning by using the permit signature first
        vm.prank(bob); // Different user frontruns
        principalToken.permitCollector(testWallet.addr, address(zap), deadline, v, r, s);

        // Check initial balances
        uint256 targetBalanceBefore = target.balanceOf(bob);
        uint256 shares = principalToken.previewCollect(testWallet.addr);

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.PT_COLLECT)));
        bytes[] memory inputs = new bytes[](1);

        PrincipalTokenRouter.PermitCollectInput memory permit =
            PrincipalTokenRouter.PermitCollectInput({deadline: deadline, v: v, r: r, s: s});

        inputs[0] = abi.encode(principalToken, bob, permit);

        vm.prank(testWallet.addr);
        zap.execute(commands, inputs);

        // Check final balances
        uint256 targetBalanceAfter = target.balanceOf(bob);

        // Bob should have received collected yield
        assertApproxEqAbs(targetBalanceAfter, targetBalanceBefore + shares, 1, "bob");
    }

    function test_CanNotAbusePermit() public {
        vm.skip(true);
    }
}
