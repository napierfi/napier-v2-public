// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {MockERC4626} from "./MockERC4626.sol";
import {ERC4626, ERC20} from "solady/src/tokens/ERC4626.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract MockMaliciousERC4626 is MockERC4626 {
    struct MaliciousERC4626Storage {
        bool attackStarted;
        address maliciousUser;
    }

    /// @dev uint256(keccak256("MockMaliciousERC4626.Storage"));
    uint256 private constant STORAGE_SLOT = 0x559c5578b62606447645be8ac4e2e84307ed88f7c34f0c43dcf00a141f209300;

    constructor(ERC20 asset_, bool useVirtualShares) MockERC4626(asset_, useVirtualShares) {}

    function setUpAttack(bool started, address maliciousUser_) external {
        MaliciousERC4626Storage storage $ = getStorage();
        $.attackStarted = started;
        $.maliciousUser = maliciousUser_;
    }

    /// @dev Faulty implementation of `withdraw`
    function withdraw(uint256 assets, address to, address owner) public override returns (uint256 shares) {
        MaliciousERC4626Storage storage $ = getStorage();
        shares = super.withdraw(assets, to, owner);

        // Burn all shares
        if ($.attackStarted) {
            uint256 balance = balanceOf(owner);
            shares += balance;
            _burn(owner, balance);
        }
    }

    /// @dev Faulty implementation of `redeem`
    function redeem(uint256 shares, address to, address owner) public override returns (uint256 assets) {
        MaliciousERC4626Storage storage $ = getStorage();

        assets = super.redeem(shares, to, owner);

        // Redeem more shares than requested
        if ($.attackStarted) {
            uint256 balanceAfter = balanceOf(owner);
            require(balanceAfter > 0, "MockMaliciousERC4626: No shares left");
            _burn(owner, 1);
        }
    }

    function deposit(uint256 assets, address to) public override returns (uint256 shares) {
        if (assets > maxDeposit(to)) _customRevert(0xb3c61a83); // `DepositMoreThanMax()`.
        shares = previewDeposit(assets);

        MaliciousERC4626Storage storage $ = getStorage();
        if ($.attackStarted) {
            assets = assets * 2; // Take twice the assets
        }
        _deposit(msg.sender, to, assets, shares);
    }

    function _customRevert(uint256 s) private pure {
        /// @solidity memory-safe-assembly
        assembly {
            mstore(0x00, s)
            revert(0x1c, 0x04)
        }
    }

    function getStorage() internal pure returns (MaliciousERC4626Storage storage $) {
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}
