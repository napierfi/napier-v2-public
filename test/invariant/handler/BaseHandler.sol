// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import {CommonBase} from "forge-std/src/Base.sol";
import {StdCheats} from "forge-std/src/StdCheats.sol";
import {StdUtils} from "forge-std/src/StdUtils.sol";

import {Ghost} from "../Ghost.sol";

abstract contract BaseHandler is CommonBase, StdCheats, StdUtils {
    /// @dev A mapping from function names to the number of times they have been called.
    mapping(bytes32 => uint256) public s_calls;

    /// @dev Ghost variable store.
    Ghost s_ghost;

    /// @dev The current `msg.sender` to be pranked.
    address internal s_currentSender;

    /// @dev The current `owner` params
    address internal s_currentFrom;

    modifier countCall(bytes32 key) {
        s_calls[key]++;
        _;
    }

    /// @dev Checks user assumption.
    modifier checkActor(address actor) {
        // Protocol doesn't allow the zero address to be a user.
        // Prevent the contract itself from playing the role of any user.
        if (actor == address(0) || actor == address(this)) {
            return;
        }

        _;
    }

    /// @dev Makes a previously provided recipient the source of the tokens.
    modifier useFuzzedFrom(uint256 actorIndexSeed) {
        s_currentFrom = s_ghost.rand(actorIndexSeed);
        if (s_currentFrom == address(0)) return;
        _;
        delete s_currentFrom;
    }

    /// @dev Makes the provided sender the caller.
    modifier useSender(address actor) {
        if (actor == address(0) || actor == address(this)) {
            return;
        }
        s_currentSender = actor;
        vm.startPrank(actor);
        _;
        vm.stopPrank();
    }

    modifier useFrom(address actor) {
        if (actor == address(0) || actor == address(this)) {
            return;
        }
        s_currentFrom = actor;
        _;
        delete s_currentFrom;
    }

    modifier useHookActor(uint256 seed) {
        address[] memory hookActors = s_ghost.hookActors();
        if (hookActors.length == 0) return;
        s_currentSender = hookActors[seed % hookActors.length];
        vm.startPrank(s_currentSender);
        _;
        vm.stopPrank();
    }

    modifier useFuzzedHookActor(uint256 seed) {
        s_currentSender = s_ghost.random_hook_actor(seed);
        if (s_currentSender == address(0)) return;
        vm.startPrank(s_currentSender);
        _;
        vm.stopPrank();
    }

    modifier skipTime(uint256 timeJumpSeed) {
        uint256 timeJump = _bound(timeJumpSeed, 0 minutes, 20 days);
        vm.warp(block.timestamp + timeJump);
        _;
    }

    function callSummary() public view virtual;
}
