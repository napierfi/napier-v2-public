// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TokiQuoterTest} from "./TokiQuoter.t.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract TokenListTest is TokiQuoterTest {
    /// @dev Low priority. Tested through TwoCrypto Quoter
    function test_TokenListIn() public {
        vm.skip(true);
    }

    function test_TokenListOut() public {
        vm.skip(true);
    }
}
