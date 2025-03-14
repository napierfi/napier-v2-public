// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import "../../Property.sol" as Property;

import {Ghost} from "../Ghost.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {IHook} from "src/interfaces/IHook.sol";

struct HookData {
    address target;
    uint256 value;
    bytes data;
}

/// @notice A contract that can be used to test supply/unite hooks.
/// @notice `s_currentSender` should be set to this contract before calling `supply`/`unite`.
contract HookActor is IHook, StdUtils, StdCheats {
    ERC20 s_pt;
    ERC20 s_target;

    constructor(PrincipalToken pt) {
        s_pt = pt;
        s_target = ERC20(pt.underlying());
    }

    function onSupply(uint256 shares, uint256, /* principal */ bytes calldata data) external {
        // Verify caller is PT
        if (msg.sender != address(s_pt)) return;
        HookData memory hook = abi.decode(data, (HookData));

        if (hook.target == address(0)) {
            // Behave as if nothing happens
            s_target.transfer(address(s_pt), shares);
        } else {
            hook.value = _bound(hook.value, 0, 1e9 ether);
            deal(address(this), hook.value);

            // We don't care about success/failure of the hook
            (bool s, bytes memory ret) = hook.target.call{value: hook.value}(hook.data);
            s;
            ret;
        }
    }

    function onUnite(uint256, /* shares */ uint256, /* principal */ bytes calldata data) external {
        // Verify caller is PT
        if (msg.sender != address(s_pt)) return;

        HookData memory hook = abi.decode(data, (HookData));

        if (hook.target == address(0)) {
            // Behave as if nothing happens
            // Principal token automatically burns the principal at the end of unite()/combine()
        } else {
            hook.value = _bound(hook.value, 0, 1e9 ether);
            deal(address(this), hook.value);

            (bool s, bytes memory ret) = hook.target.call{value: hook.value}(hook.data);
            s;
            ret;
        }
    }
}
