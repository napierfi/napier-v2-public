// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/src/Test.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {Token} from "src/Types.sol";
import {Errors} from "src/Errors.sol";
import "src/Constants.sol" as Constants;
import {SNukeWrapper, ISNuke} from "src/wrapper/SNukeWrapper.sol";
import {WrapperConnector} from "src/modules/connectors/WrapperConnector.sol";
import {SharePriceResolver} from "src/modules/resolvers/SharePriceResolver.sol";

interface IStakedNukeOnRobinhood {
    function staking() external view returns (address);
    function rebase(uint256 profit, uint256 epoch) external returns (uint256);
}

interface ISNukeStakingOnRobinhood {
    function epoch() external view returns (uint64 length, uint64 number, uint64 end, uint256 distribute);
    function rebase() external;
}

contract SNukeWrapperTest is Test {
    uint256 internal constant FORK_BLOCK = 70_350_000;
    address internal constant NUKE = 0x0000000005aCa17e8bd5779Fc87E13cb433aEd24;
    address internal constant SNUKE = 0x4BEF5C76A50bc68f63B8E2628CDB3b33cB445934;
    address internal constant STAKING = 0x9c648d57e929f59b483b2903390725449F990CB8;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant FUNDED_HOLDER = 0x03aEbF90342f923C9438f9Cb55ECF8A4dd8719b5;

    SNukeWrapper wrapper;
    WrapperConnector connector;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    Token sNukeToken = Token.wrap(SNUKE);

    constructor() {
        vm.createSelectFork(vm.rpcUrl("robinhood"), FORK_BLOCK);
    }

    function setUp() public {
        assertEq(block.number, FORK_BLOCK);
        assertEq(ERC20(SNUKE).decimals(), 9);
        assertEq(ERC20(NUKE).decimals(), 9);
        assertEq(IStakedNukeOnRobinhood(SNUKE).staking(), STAKING);

        wrapper = SNukeWrapper(LibClone.clone(address(new SNukeWrapper()), abi.encode(SNUKE, NUKE)));
        wrapper.initialize();
        connector = WrapperConnector(
            payable(LibClone.clone(address(new WrapperConnector()), abi.encode(address(wrapper), WETH)))
        );

        vm.prank(FUNDED_HOLDER);
        ERC20(SNUKE).transfer(alice, 24_938_271_849);
        vm.prank(alice);
        ERC20(SNUKE).approve(address(wrapper), type(uint256).max);
        vm.prank(alice);
        ERC20(SNUKE).approve(address(connector), type(uint256).max);
    }

    function testFork_deposit_redeemAfterRealEpochRebase() public {
        uint256 aliceTokens = 10_173_619_437;
        uint256 aliceShares = _deposit(alice, alice, aliceTokens);
        uint256 claimBefore = wrapper.previewRedeem(sNukeToken, aliceShares);
        // Wrapping cannot strand more than one raw sNUKE unit at the current index.
        assertGe(claimBefore, aliceTokens - 1);
        uint256 heldBefore = ERC20(SNUKE).balanceOf(alice);
        uint256 indexBefore = ISNuke(SNUKE).index();
        // One whole share tracks the sNUKE index despite its 9-decimal token balance.
        assertEq(wrapper.convertToAssets(1e18), indexBefore);
        (,, uint64 epochEnd, uint256 distribute) = ISNukeStakingOnRobinhood(STAKING).epoch();
        assertGt(distribute, 0);
        vm.warp(uint256(epochEnd) + 1);
        // An elapsed epoch does not change sNUKE balances until the rebase executes.
        assertEq(wrapper.previewRedeem(sNukeToken, aliceShares), claimBefore);
        ISNukeStakingOnRobinhood(STAKING).rebase();
        assertGt(ISNuke(SNUKE).index(), indexBefore);

        // Wrapped shares accrue the rebase at the rate of sNUKE held directly, within index truncation.
        uint256 claimAfter = wrapper.previewRedeem(sNukeToken, aliceShares);
        assertGt(claimAfter, claimBefore);
        assertApproxEqRel(claimAfter * heldBefore, claimBefore * ERC20(SNUKE).balanceOf(alice), 1e10);
        assertGe(ERC20(SNUKE).balanceOf(address(wrapper)), claimAfter);

        uint256 bobTokens = 7_971_731_479;
        uint256 bobShares = _deposit(alice, bob, bobTokens);
        assertEq(wrapper.previewRedeem(sNukeToken, aliceShares), claimAfter);

        uint256 bobReceived = _redeem(bob, bob, bobShares);
        // A round trip at one index never returns more than was deposited.
        assertLe(bobReceived, bobTokens);
        assertApproxEqRel(bobReceived, bobTokens, 1e10);
        assertEq(wrapper.previewRedeem(sNukeToken, aliceShares), claimAfter);

        assertEq(_redeem(alice, alice, aliceShares), claimAfter);
        assertEq(wrapper.totalSupply(), 0);
    }

    function testFork_deposit_donationDoesNotReprice() public {
        uint256 aliceShares = _deposit(alice, alice, 11_387_171_397);
        uint256 claimBefore = wrapper.previewRedeem(sNukeToken, aliceShares);
        uint256 bobTokens = 1_037_193_199;
        uint256 bobPreview = wrapper.previewDeposit(sNukeToken, bobTokens);
        uint256 bobClaim = wrapper.previewRedeem(sNukeToken, bobPreview);
        uint256 donation = 2_319_497_103;
        vm.prank(alice);
        ERC20(SNUKE).transfer(address(wrapper), donation);
        uint256 bobShares = _deposit(alice, bob, bobTokens);
        assertEq(bobShares, bobPreview);
        assertEq(_redeem(alice, alice, aliceShares), claimBefore);
        assertEq(_redeem(bob, bob, bobShares), bobClaim);
        // Every share is redeemed and the donation remains in custody.
        assertEq(wrapper.totalSupply(), 0);
        assertGe(ERC20(SNUKE).balanceOf(address(wrapper)), donation);
    }

    function testFork_deposit_rejectUnlistedConnectorRoutes() public {
        assertEq(connector.getTokenInList().length, 1);
        assertEq(Token.unwrap(connector.getTokenInList()[0]), SNUKE);
        assertEq(Token.unwrap(connector.getTokenOutList()[0]), SNUKE);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        connector.previewDeposit(Token.wrap(NUKE), 17_131_911_337);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        connector.previewRedeem(Token.wrap(NUKE), 2e18);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        connector.previewDeposit(Token.wrap(Constants.NATIVE_ETH), 1e18);
        vm.expectRevert(Errors.ERC4626Wrapper_TokenNotListed.selector);
        wrapper.deposit(Token.wrap(NUKE), 17_131_911_337, alice);
    }

    function testFork_deposit_zeroTokensWithoutApproval() public {
        uint256 aliceShares = _deposit(alice, alice, 10_173_619_437);
        uint256 custodyBefore = ERC20(SNUKE).balanceOf(address(wrapper));
        assertEq(wrapper.previewDeposit(sNukeToken, 0), 0);
        vm.prank(bob);
        assertEq(wrapper.deposit(sNukeToken, 0, bob), 0);
        assertEq(wrapper.balanceOf(bob), 0);
        assertEq(wrapper.balanceOf(alice), aliceShares);
        assertEq(ERC20(SNUKE).balanceOf(address(wrapper)), custodyBefore);
    }

    function testFork_redeem_dustSharesForZeroTokens() public {
        // One raw sNUKE mints shares whose gons claim rounds below one raw unit.
        uint256 shares = _deposit(alice, alice, 1);
        assertGt(shares, 0);
        assertEq(_redeem(alice, alice, shares), 0);
        assertEq(_redeem(alice, alice, 0), 0);
    }

    function testFork_assetsPerShare_releasesRebaseOverEpoch() public {
        uint256 shares = _deposit(alice, alice, 10_173_619_437);
        SharePriceResolver resolver =
            new SharePriceResolver(address(wrapper), NUKE, SNukeWrapper.assetsPerShare.selector);
        uint256 priceBefore = wrapper.assetsPerShare();
        assertEq(priceBefore, ISNuke(SNUKE).index());

        (,, uint64 epochEnd,) = ISNukeStakingOnRobinhood(STAKING).epoch();
        vm.warp(uint256(epochEnd) + 1);
        ISNukeStakingOnRobinhood(STAKING).rebase();
        uint256 indexAfter = ISNuke(SNUKE).index();
        assertGt(indexAfter, priceBefore);
        // Neither the rebase nor the share transfer that observes it moves the market price.
        assertEq(wrapper.assetsPerShare(), priceBefore);
        vm.prank(alice);
        wrapper.transfer(bob, shares / 3);
        assertEq(wrapper.assetsPerShare(), priceBefore);

        vm.warp(block.timestamp + 11_939);
        uint256 midPrice = wrapper.assetsPerShare();
        assertGt(midPrice, priceBefore);
        assertLt(midPrice, indexAfter);
        assertEq(resolver.scale(), midPrice);

        vm.warp(block.timestamp + 8 hours);
        assertEq(wrapper.assetsPerShare(), indexAfter);
        assertEq(wrapper.assetsPerShare(), wrapper.convertToAssets(1e18));
    }

    function testFork_assetsPerShare_releasesUnobservedRebasesOverTheirAccrualTime() public {
        _deposit(alice, alice, 10_173_619_437);
        uint256 observedAt = block.timestamp;
        uint256 priceBefore = wrapper.assetsPerShare();
        for (uint256 i; i < 7; ++i) {
            (,, uint64 epochEnd,) = ISNukeStakingOnRobinhood(STAKING).epoch();
            vm.warp(uint256(epochEnd) + 1);
            ISNukeStakingOnRobinhood(STAKING).rebase();
        }
        uint256 quietTime = block.timestamp - observedAt;
        assertGt(ISNuke(SNUKE).index(), priceBefore);

        wrapper.checkpoint();
        uint256 releaseEnd = block.timestamp + quietTime;
        assertEq(wrapper.assetsPerShare(), priceBefore);
        // A rebase observed mid-release folds into the release without bringing its end forward.
        (,, uint64 nextEpochEnd,) = ISNukeStakingOnRobinhood(STAKING).epoch();
        vm.warp(uint256(nextEpochEnd) + 1);
        ISNukeStakingOnRobinhood(STAKING).rebase();
        wrapper.checkpoint();
        uint256 indexAfter = ISNuke(SNUKE).index();

        vm.warp(releaseEnd - 1);
        assertLt(wrapper.assetsPerShare(), indexAfter);
        vm.warp(releaseEnd);
        assertEq(wrapper.assetsPerShare(), indexAfter);
    }

    /// @dev Only elapsed time moves the price: rebases, checkpoints and share transfers leave it unchanged.
    function testFork_assetsPerShare_movesOnlyWithTime(uint256[10] memory actions) public {
        _deposit(alice, alice, 10_173_619_437);
        uint256 price = wrapper.assetsPerShare();
        for (uint256 i; i < actions.length; ++i) {
            uint256 kind = actions[i] % 4;
            uint256 arg = actions[i] >> 8;
            if (kind == 0) {
                vm.warp(block.timestamp + bound(arg, 1, 16 hours));
                assertGe(wrapper.assetsPerShare(), price);
            } else {
                if (kind == 1) {
                    vm.prank(STAKING);
                    IStakedNukeOnRobinhood(SNUKE).rebase(bound(arg, 1, 95_700_373_172_103), 0);
                } else if (kind == 2) {
                    wrapper.checkpoint();
                } else {
                    uint256 shares = bound(arg, 0, wrapper.balanceOf(alice));
                    vm.prank(alice);
                    wrapper.transfer(bob, shares);
                }
                assertEq(wrapper.assetsPerShare(), price);
            }
            price = wrapper.assetsPerShare();
            assertLe(price, wrapper.convertToAssets(1e18));
        }
        wrapper.checkpoint();
        vm.warp(block.timestamp + type(uint24).max);
        assertEq(wrapper.assetsPerShare(), wrapper.convertToAssets(1e18));
    }

    function _deposit(address sender, address receiver, uint256 tokens) internal returns (uint256 shares) {
        uint256 preview = wrapper.previewDeposit(sNukeToken, tokens);
        uint256 receiverSharesBefore = wrapper.balanceOf(receiver);
        uint256 custodyBefore = ERC20(SNUKE).balanceOf(address(wrapper));
        vm.prank(sender);
        shares = wrapper.deposit(sNukeToken, tokens, receiver);
        assertEq(shares, preview);
        assertEq(wrapper.balanceOf(receiver) - receiverSharesBefore, shares);
        uint256 custodyIncrease = ERC20(SNUKE).balanceOf(address(wrapper)) - custodyBefore;
        assertGe(custodyIncrease, tokens);
        // New shares never claim more sNUKE than the deposit added to custody.
        assertLe(wrapper.convertToAssets(shares), custodyIncrease);
    }

    function _redeem(address owner, address receiver, uint256 shares) internal returns (uint256 tokens) {
        uint256 preview = wrapper.previewRedeem(sNukeToken, shares);
        uint256 ownerSharesBefore = wrapper.balanceOf(owner);
        uint256 supplyBefore = wrapper.totalSupply();
        uint256 receiverBefore = ERC20(SNUKE).balanceOf(receiver);
        vm.prank(owner);
        tokens = wrapper.redeem(sNukeToken, shares, receiver);
        assertEq(tokens, preview);
        assertEq(ownerSharesBefore - wrapper.balanceOf(owner), shares);
        assertEq(supplyBefore - wrapper.totalSupply(), shares);
        assertGe(ERC20(SNUKE).balanceOf(receiver) - receiverBefore, tokens);
    }
}
