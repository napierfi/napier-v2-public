// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {V4IntegrationTest} from "../V4Integration.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {SafeCastLib} from "solady/src/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";

import {Factory} from "src/Factory.sol";
import {SNukeWrapper, ISNuke} from "src/wrapper/SNukeWrapper.sol";
import {WrapperFactory} from "src/wrapper/WrapperFactory.sol";
import {Commands} from "src/zap/uniswap/Commands.sol";

import "src/Types.sol";
import "src/Constants.sol" as Constants;

interface INukeStaking {
    function epoch() external view returns (uint64 length, uint64 number, uint64 end, uint256 distribute);
    function stake(address to, uint256 amount) external returns (uint256);
    function rebase() external;
}

using SafeCastLib for uint256;

contract SNUKE_UniV4ForkTest is V4IntegrationTest {
    uint256 constant FORK_BLOCK = 70_350_000;
    address constant NUKE = 0x0000000005aCa17e8bd5779Fc87E13cb433aEd24;
    address constant SNUKE = 0x4BEF5C76A50bc68f63B8E2628CDB3b33cB445934;
    INukeStaking constant STAKING = INukeStaking(0x9c648d57e929f59b483b2903390725449F990CB8);

    SNukeWrapper wrapper;
    address donor = makeAddr("donor");

    constructor() {
        vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK);
    }

    function setUp() public override {
        super.setUp();

        // Stake once up front: Staking rejects stakes once a rebase is a full epoch overdue, which warped tests reach.
        uint256 nuke = 20_371_958_413_907;
        deal(NUKE, donor, nuke);
        vm.startPrank(donor);
        SafeTransferLib.safeApprove(NUKE, address(STAKING), nuke);
        STAKING.stake(donor, nuke);
        SafeTransferLib.safeApprove(SNUKE, address(wrapper), type(uint256).max);
        vm.stopPrank();
    }

    function _deployTokens() internal override {
        // sNUKE stands in for the wrapper until the periphery deploys WrapperFactory.
        assembly {
            sstore(target.slot, SNUKE)
            sstore(base.slot, NUKE)
        }
    }

    function _deployInstance() internal override {
        address implementation = address(new SNukeWrapper());

        vm.startPrank(admin);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = WrapperFactory.setWrapperImplementation.selector;
        napierAccessManager.grantTargetFunctionRoles(address(wrapperFactory), selectors, Constants.DEV_ROLE);
        wrapperFactory.setWrapperImplementation(implementation, true);
        wrapper = SNukeWrapper(wrapperFactory.createWrapper(implementation, abi.encode(SNUKE, NUKE), bytes32(0)));
        vm.stopPrank();

        assembly {
            sstore(target.slot, sload(wrapper.slot))
        }
        tOne = 10 ** wrapper.decimals();

        super._deployInstance();
    }

    function getDeploymentParams()
        public
        view
        override
        returns (Factory.Suite memory suite, Factory.ModuleParam[] memory params)
    {
        (suite, params) = getParamsForERC4626Resolver();
        suite.resolverBlueprint = share_price_resolver_blueprint;
        suite.resolverArgs = abi.encode(address(target), NUKE, SNukeWrapper.assetsPerShare.selector);
    }

    function _connectorToken() internal pure override returns (address) {
        return SNUKE;
    }

    /// @dev `deal` cannot write sNUKE's gons balances, and wrapper shares must stay backed by custody. Funding adds
    ///      to the recipient's balance, and a wrapper deposit or transfer checkpoints any unobserved rebase.
    function _dealToken(address token, address to, uint256 amount) internal override {
        if (token == SNUKE) {
            vm.prank(donor);
            SafeTransferLib.safeTransfer(SNUKE, to, amount);
        } else if (token == address(wrapper)) {
            // One raw sNUKE above the claim of `amount` shares mints at least `amount` shares.
            uint256 tokens = wrapper.convertToAssets(amount) + 1;
            vm.startPrank(donor);
            wrapper.deposit(Token.wrap(SNUKE), tokens, donor);
            wrapper.transfer(to, amount);
            vm.stopPrank();
        } else {
            super._dealToken(token, to, amount);
        }
    }

    function testFork_redeem_rebaseVestingAcrossExpiryPaysSNuke() public {
        uint256 initialDeposit = 5000 * tOne;
        _testFork_DepositInitialLiquidity(initialDeposit);

        vm.warp(expiry - 2 hours);
        // The overdue epoch rebases in place; `_rebase` would warp back to the pending epoch end.
        STAKING.rebase();
        wrapper.checkpoint();
        vm.warp(expiry + 1);
        // The release started just before expiry is still in flight at settlement.
        assertLt(resolver.scale(), ISNuke(SNUKE).index(), "vesting at expiry");

        bytes memory commands = abi.encodePacked(
            bytes1(uint8(Commands.TP_REMOVE_LIQUIDITY)),
            bytes1(uint8(Commands.PT_REDEEM)),
            bytes1(uint8(Commands.VAULT_CONNECTOR_REDEEM)),
            bytes1(uint8(Commands.SWEEP))
        );
        bytes[] memory inputs = new bytes[](4);
        inputs[0] = abi.encode(poolKey, SafeTransferLib.balanceOf(pool, alice), 0, 0, ActionConstants.ADDRESS_THIS);
        inputs[1] = abi.encode(principalToken, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
        inputs[2] = abi.encode(target, base, SNUKE, ActionConstants.CONTRACT_BALANCE, ActionConstants.ADDRESS_THIS);
        inputs[3] = abi.encode(SNUKE, bob, 0);

        vm.startPrank(alice);
        SafeTransferLib.safeApprove(pool, address(permit2), type(uint256).max);
        permit2.approve(pool, address(zap), type(uint160).max, type(uint48).max);
        zap.execute(commands, inputs, block.timestamp + 1000 seconds);
        (uint256 collected,) = principalToken.collect(alice, alice);
        vm.stopPrank();

        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        uint256 sNukeRedeemed = ERC20(SNUKE).balanceOf(bob);
        // PT and YT sides together return the deposit whatever share of the yield the lag moved between them.
        assertApproxEqRel(
            sNukeRedeemed + wrapper.convertToAssets(collected + curatorFee + protocolFee),
            wrapper.convertToAssets(initialDeposit),
            0.001e18,
            "value conserved"
        );
        assertGe(ERC20(SNUKE).balanceOf(address(wrapper)), wrapper.convertToAssets(wrapper.totalSupply()), "custody");
        assertNoFundLeftInZap();
        assertEq(ERC20(SNUKE).balanceOf(address(zap)), 0, "sNUKE left in zap");
    }

    function testFork_collect_rebaseAccruesToYieldToken() public {
        _testFork_DepositInitialLiquidity(5000 * tOne);
        uint256 principal = yt.balanceOf(alice);
        uint256 scaleBefore = resolver.scale();

        _rebase();
        // An observed rebase starts vesting from the current price, so no yield is claimable yet.
        vm.prank(alice);
        (uint256 collectedAtRebase,) = principalToken.collect(alice, alice);
        assertEq(collectedAtRebase, 0, "collected at rebase");

        vm.warp(block.timestamp + 8 hours);
        uint256 scaleAfter = resolver.scale();
        assertEq(scaleAfter, ISNuke(SNUKE).index(), "fully vested");

        vm.prank(alice);
        (uint256 collected,) = principalToken.collect(alice, alice);
        assertGt(collected, 0, "collected");
        // Fees only reduce the payout below the gross yield on `principal`.
        assertLe(collected * scaleAfter, principal * (scaleAfter - scaleBefore) * 1e18 / scaleBefore, "yield cap");
    }

    function testFork_swap_rebaseRoundTripDoesNotProfit() public {
        _testFork_DepositInitialLiquidity(5000 * tOne);
        uint256 principals = 397_518_213_947;
        deal(address(principalToken), bob, principals);
        _dealToken(address(target), bob, 13 * tOne);
        (,, uint64 epochEnd,) = STAKING.epoch();
        vm.warp(uint256(epochEnd) + 1);

        uint256 snapshot = vm.snapshotState();
        int256 control = _roundTrip(bob, principals, false);
        vm.revertToState(snapshot);
        int256 withRebase = _roundTrip(bob, principals, true);

        assertLt(control, 0, "fees");
        assertEq(withRebase, control, "rebase round trip");
    }

    /// @dev Sells `principals` PT for shares and buys the same PT back, optionally rebasing in between.
    function _roundTrip(address user, uint256 principals, bool rebase) internal returns (int256 sharesDelta) {
        uint256 sharesBefore = target.balanceOf(user);
        _swap(user, false, -principals.toInt256(), 0);
        if (rebase) {
            uint256 indexBefore = ISNuke(SNUKE).index();
            STAKING.rebase();
            wrapper.checkpoint();
            assertGt(ISNuke(SNUKE).index(), indexBefore, "rebased");
        }
        _swap(user, true, principals.toInt256(), 0);
        assertEq(principalToken.balanceOf(user), principals, "principals");
        sharesDelta = target.balanceOf(user).toInt256() - sharesBefore.toInt256();
    }

    function _rebase() internal {
        (,, uint64 epochEnd,) = STAKING.epoch();
        vm.warp(uint256(epochEnd) + 1);
        STAKING.rebase();
        wrapper.checkpoint();
    }
}
