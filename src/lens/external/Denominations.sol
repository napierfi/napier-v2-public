// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Currency} from "./FeedRegistry.sol";

library Denominations {
    // Fiat currencies follow https://en.wikipedia.org/wiki/ISO_4217
    Currency constant USD = Currency.wrap(address(840));
    Currency constant ETH = Currency.wrap(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    Currency constant BTC = Currency.wrap(0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB);
}
