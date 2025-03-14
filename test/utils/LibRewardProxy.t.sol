// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.24;

import "forge-std/src/Test.sol";
import {SymTest} from "halmos-cheatcodes/src/SymTest.sol";

import {Errors} from "src/Errors.sol";
import {TokenReward} from "src/Types.sol";
import {IRewardProxy} from "src/interfaces/IRewardProxy.sol";

import {LibRewardProxy} from "src/utils/LibRewardProxy.sol";

contract Dummy {
    function collectReward(address rewardProxy) external pure returns (TokenReward[] memory) {
        rewardProxy; // Silence the unused parameter warning
        return new TokenReward[](0);
    }
}

/// @notice Symbolic test for LibRewardProxy.
/// @custom:halmos --mc=LibRewardProxyTest
contract LibRewardProxySymTest is Test, SymTest {
    // Symbolic storage
    TokenReward[] sym_rewards;

    function setUp() public {
        for (uint256 i = 0; i < 5; i++) {
            sym_rewards.push(TokenReward({token: svm.createAddress("token"), amount: svm.createUint256("amount")}));
        }
    }

    /// @dev IRewardProxy implementation for testing.
    function collectReward(address rewardProxy) public view returns (TokenReward[] memory) {
        rewardProxy; // Silence the unused parameter warning
        return sym_rewards;
    }

    function check_Unit() public {
        TokenReward[] memory result = LibRewardProxy.delegateCallCollectReward(address(this));
        for (uint256 i = 0; i < result.length; i++) {
            assert(result[i].token == sym_rewards[i].token);
            assert(result[i].amount == sym_rewards[i].amount);
        }
    }

    function check_DiffFuzz() public {
        (bool s, bytes memory ret) =
            address(this).call(abi.encodeCall(this.nativeDelegateCallCollectReward, (address(this))));
        (bool s2, bytes memory ret2) =
            address(this).call(abi.encodeCall(this.optimizedDelegateCallCollectReward, (address(this))));
        assert(s == s2);

        assert(keccak256(ret) == keccak256(ret2));
    }

    function optimizedDelegateCallCollectReward(address rewardProxy) external returns (TokenReward[] memory) {
        return LibRewardProxy.delegateCallCollectReward(rewardProxy);
    }

    function nativeDelegateCallCollectReward(address rewardProxy) external returns (TokenReward[] memory) {
        (bool s, bytes memory data) =
            rewardProxy.delegatecall(abi.encodeCall(IRewardProxy.collectReward, (address(this))));
        if (!s) revert Errors.PrincipalToken_CollectRewardFailed();
        return abi.decode(data, (TokenReward[]));
    }
}

contract LibRewardProxyTest is Test {
    address dummy;

    function setUp() public {
        dummy = address(new Dummy());
    }

    function test_Unit() external {
        TokenReward[] memory rewards = new TokenReward[](3);
        for (uint256 i = 0; i < rewards.length; i++) {
            rewards[i] = TokenReward({
                token: address(uint160(uint256(keccak256(abi.encode(i))))),
                amount: uint256(keccak256(abi.encode(i)))
            });
        }
        test_Fuzz(rewards);
    }

    function test_When_LengthZero() external {
        assertEq(Dummy(dummy).collectReward(dummy).length, 0);
        assertEq(this.optimizedDelegateCallCollectReward(dummy).length, 0);
    }

    function test_Fuzz(TokenReward[] memory rewards) public {
        vm.mockCall(dummy, abi.encodeWithSelector(Dummy.collectReward.selector, dummy), abi.encode(rewards));

        TokenReward[] memory result = LibRewardProxy.delegateCallCollectReward(dummy);
        for (uint256 i = 0; i < result.length; i++) {
            assertEq(result[i].token, rewards[i].token);
            assertEq(result[i].amount, rewards[i].amount);
        }
    }

    function test_DiffFuzz(bytes memory data) public {
        vm.mockCall(dummy, abi.encodeWithSelector(Dummy.collectReward.selector, dummy), data);

        (bool s, bytes memory ret) = address(this).call(abi.encodeCall(this.nativeDelegateCallCollectReward, (dummy)));
        (bool s2, bytes memory ret2) =
            address(this).call(abi.encodeCall(this.optimizedDelegateCallCollectReward, (dummy)));
        assertEq(s, s2);
        if (!s) return;

        TokenReward[] memory expect = abi.decode(ret, (TokenReward[]));
        TokenReward[] memory result = abi.decode(ret2, (TokenReward[]));
        for (uint256 i = 0; i < result.length; i++) {
            assertEq(result[i].token, expect[i].token);
            assertEq(result[i].amount, expect[i].amount);
        }
    }

    function test_RevertWhen_DelegateCallFailed() public {
        vm.mockCallRevert(dummy, abi.encodeWithSelector(Dummy.collectReward.selector, dummy), abi.encode(""));
        vm.expectRevert(Errors.PrincipalToken_CollectRewardFailed.selector);
        this.optimizedDelegateCallCollectReward(dummy);
    }

    function test_RevertWhen_WrongReturnType() public {
        vm.mockCall(dummy, abi.encodeWithSelector(Dummy.collectReward.selector, dummy), abi.encode(uint256(0x20)));
        vm.expectRevert();
        this.optimizedDelegateCallCollectReward(dummy);
    }

    function test_RevertWhen_LengthMismatchDataSize() public {
        bytes memory badReturndata = abi.encodePacked(
            uint256(0x20), // Offset
            uint256(0x02), // Length of the array
            uint256(0xcafe), // Token
            uint256(0xbabebabe) // Amount
        );
        vm.mockCall(dummy, abi.encodeWithSelector(Dummy.collectReward.selector, dummy), badReturndata);
        vm.expectRevert();
        this.optimizedDelegateCallCollectReward(dummy);
    }

    function test_RevertWhen_DirtyBits() public {
        bytes memory badReturndata = abi.encodePacked(
            uint256(0x20), // Offset
            uint256(0x01), // Length of the array
            uint256(0xffffffffffff << 160 | 0xcafe), // Token
            uint256(0xbabebabe) // Amount
        );

        vm.mockCall(dummy, abi.encodeWithSelector(Dummy.collectReward.selector, dummy), badReturndata);

        vm.expectRevert();
        this.optimizedDelegateCallCollectReward(dummy);
    }

    function optimizedDelegateCallCollectReward(address rewardProxy) external returns (TokenReward[] memory) {
        return LibRewardProxy.delegateCallCollectReward(rewardProxy);
    }

    function nativeDelegateCallCollectReward(address rewardProxy) external returns (TokenReward[] memory) {
        (bool s, bytes memory data) = rewardProxy.delegatecall(abi.encodeCall(Dummy.collectReward, (dummy)));
        if (!s) revert Errors.PrincipalToken_CollectRewardFailed();
        return abi.decode(data, (TokenReward[]));
    }
}
