// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {MockFactory} from "./MockFactory.sol";

contract MockPrincipalToken {
    MockFactory public immutable i_factory;

    constructor(MockFactory _factory) {
        i_factory = _factory;
    }
}
