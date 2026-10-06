// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import {MockFactory} from "./MockFactory.sol";

contract MockPrincipalToken {
    MockFactory public immutable i_factory;

    constructor(address _factory) {
        i_factory = MockFactory(_factory);
    }

    function i_accessManager() external view returns (address) {
        return i_factory.i_accessManager();
    }
}
