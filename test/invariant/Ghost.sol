// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {EnumerableSetLib} from "solady/src/utils/EnumerableSetLib.sol";

import {HookActor} from "./handler/HookActor.sol";

contract Ghost is TestBase, StdUtils {
    using EnumerableSetLib for EnumerableSetLib.AddressSet;

    struct Ghost_Fees {
        uint256 sumCollectedFee;
    }

    Ghost_Fees ghost_protocolFees;
    Ghost_Fees ghost_curatorFees;

    struct Ghost_Yield {
        uint256 ghost_sumCollected;
    }

    EnumerableSetLib.AddressSet ghost_receivers;
    mapping(address user => Ghost_Yield) ghost_userYields;

    // Hook actors
    HookActor[] s_hookActors;
    EnumerableSetLib.AddressSet s_fuzzedHookActors;

    constructor(HookActor[] memory actors) {
        s_hookActors = actors;
    }

    function add_fuzzed_hook_actor(address actor) external {
        for (uint256 i; i != s_hookActors.length; ++i) {
            if (s_hookActors[i] == HookActor(actor)) {
                s_fuzzedHookActors.add(actor);
                return;
            }
        }
    }

    function hookActors() external view returns (address[] memory actors) {
        HookActor[] memory a = s_hookActors;
        assembly {
            actors := a
        }
    }

    function random_hook_actor(uint256 seed) external view returns (address) {
        if (s_fuzzedHookActors.length() == 0) return address(0);
        return s_fuzzedHookActors.at(seed % s_fuzzedHookActors.length());
    }

    /// @dev Adds a PT / YT holder to the list of receivers.
    function add_receiver(address receiver) external {
        bool added = ghost_receivers.add(receiver);
        if (added) vm.label(receiver, string.concat("user", vm.toString(ghost_receivers.length())));
    }

    function rand(uint256 seed) external view returns (address) {
        if (ghost_receivers.length() == 0) return address(0);
        return ghost_receivers.at(seed % ghost_receivers.length());
    }

    function receivers() external view returns (address[] memory) {
        return ghost_receivers.values();
    }
}
