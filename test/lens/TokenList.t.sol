// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";

import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {Quoter} from "src/lens/Quoter.sol";
import "src/Types.sol";

contract TokenListTest is TwoCryptoZapAMMTest {
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

    function test_TokenInList_WhenConnectorRegistered() public {
        vm.skip({skipTest: true});
    }

    function test_TokenInList_WhenERC4626() public view {
        Token[] memory tokens = quoter.getTokenInList(twocrypto);

        checkTokenInList(tokens, address(target));
        checkTokenInList(tokens, address(base));
    }

    function test_TokenInList_WhenNotERC4626() public {
        // Mock target is not ERC4626
        vm.etch(address(target), address(base).code);

        Token[] memory tokens = quoter.getTokenInList(twocrypto);
        assertEq(tokens.length, 1, "Token length mismatch");
        checkTokenInList(tokens, address(target));
    }

    function test_TokenInList_WhenDepositDisabled() public {
        vm.mockCall(address(target), abi.encodeWithSelector(target.maxDeposit.selector), abi.encode(0));

        Token[] memory tokens = quoter.getTokenInList(twocrypto);
        assertEq(tokens.length, 1, "Token length mismatch");
        checkTokenInList(tokens, address(target));
    }

    function checkTokenInList(Token[] memory tokens, address token) internal pure {
        uint256[] memory tokenAddresses = toUint256Array(tokens);
        assertTrue(DynamicArrayLib.contains(tokenAddresses, uint256(uint160(token))), "Token not in list");
    }

    function toUint256Array(Token[] memory a) internal pure returns (uint256[] memory result) {
        /// @solidity memory-safe-assembly
        assembly {
            result := a
        }
    }
}
