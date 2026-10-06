// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {TwoCryptoBase, Base} from "../../TwoCryptoBase.t.sol";
import {RewardProxyBaseTest} from "../RewardProxy.t.sol";
import {IMerkl} from "src/interfaces/external/IMerkl.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

import {IMerkl} from "src/interfaces/external/IMerkl.sol";
import {MerklRewardProxy} from "src/modules/reward-proxies/MerklRewardProxy.sol";

import {Factory} from "src/Factory.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";

import "src/Types.sol";
import "src/Constants.sol";
import "src/Errors.sol";

contract MockMerkleDistributor is IMerkl {
    event Claimed(address indexed account, address indexed reward, uint256 amount);

    mapping(address account => mapping(address reward => IMerkl.Claim)) s_claimed;

    function claimed(address account, address reward) public view returns (IMerkl.Claim memory) {
        return s_claimed[account][reward];
    }

    function claim(address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs)
        external
    {
        proofs; // Skip proof for testing
        for (uint256 i = 0; i < users.length; i++) {
            require(ERC20(tokens[i]).balanceOf(address(this)) >= amounts[i], "Merkl: insufficient balance");

            uint256 amount = amounts[i] - s_claimed[users[i]][tokens[i]].amount;
            s_claimed[users[i]][tokens[i]] =
                IMerkl.Claim({amount: uint208(amounts[i]), timestamp: uint48(block.timestamp), merkleRoot: bytes32(0)});

            ERC20(tokens[i]).transfer(users[i], amount);

            emit Claimed(users[i], tokens[i], amount);
        }
    }

    function operators(address, /* user */ address /* operator */ ) external pure returns (uint256) {
        return 1;
    }

    function toggleOperator(address user, address operator) external {}
}

contract MerklRewardProxyTest is RewardProxyBaseTest {
    MockMerkleDistributor distributor;
    address operator = address(0x1234567890123456789012345678901234567890);

    function setUp() public virtual override {
        distributor = new MockMerkleDistributor();
        rewardProxy_logic = address(new MerklRewardProxy());

        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        _deployInstance();

        /// Prepare distributor
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            deal(rewardTokens[i], address(distributor), type(uint64).max);
        }
    }

    function getCustomArgs() public view override returns (bytes memory) {
        return abi.encode(rewardTokens, distributor, operator, treasury);
    }

    /// @dev Helper to get the last claimed amount for a reward token stored in PrincipalToken storage.
    function getLastClaimed(address reward) public view returns (uint256, uint256) {
        bytes32 MERKL_REWARD_PROXY_STORAGE_LOCATION = keccak256(
            abi.encode(uint256(keccak256("napier-v2.storage.merkl-reward-proxy")) - 1)
        ) & ~bytes32(uint256(0xff));
        // Inside struct, the mapping is the first element.
        uint256 offset = 0;
        bytes32 slot = keccak256(abi.encode(reward, uint256(MERKL_REWARD_PROXY_STORAGE_LOCATION) + offset));
        bytes32 value = vm.load(address(principalToken), slot);
        return (uint256(uint208(uint256(value))), uint256(uint48(uint256(value) >> 208)));
    }

    function test_ClaimRewards() public {
        // Prepare - Alice is eligible for rewards
        uint256 shares = 0.01e18;
        deal(address(base), alice, shares);

        _approve(base, alice, address(target), shares);
        vm.prank(alice);
        target.deposit(shares, alice);

        _approve(target, alice, address(principalToken), shares);
        vm.prank(alice);
        principalToken.supply(shares, alice);

        // Execution

        skip(1 hours);
        uint256 totalClaimable = 1000;
        address[] memory users = new address[](1);
        users[0] = address(principalToken);
        address[] memory tokens = new address[](1);
        tokens[0] = rewardTokens[0];
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalClaimable;
        deal(rewardTokens[0], address(distributor), totalClaimable);
        distributor.claim(users, tokens, amounts, new bytes32[][](0));

        // Accrued reward is updated
        vm.prank(alice);
        principalToken.supply(0, alice);

        (uint256 lastClaimedAmount,) = getLastClaimed(rewardTokens[0]);
        assertEq(lastClaimedAmount, totalClaimable);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable);

        skip(2 hours);
        uint256 claimable2 = 2030;
        uint256 totalClaimable2 = claimable2 + totalClaimable;
        address[] memory users2 = new address[](1);
        users2[0] = address(principalToken);
        address[] memory tokens2 = new address[](1);
        tokens2[0] = rewardTokens[0];
        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = totalClaimable2;
        deal(rewardTokens[0], address(distributor), totalClaimable2);
        distributor.claim(users2, tokens2, amounts2, new bytes32[][](0));

        // Accrued reward is updated
        vm.prank(alice);
        principalToken.supply(0, alice);

        (lastClaimedAmount,) = getLastClaimed(rewardTokens[0]);
        assertEq(lastClaimedAmount, totalClaimable2);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable2);

        skip(3 hours);
        uint256 claimable3 = 30003;
        uint256 totalClaimable3 = claimable3 + totalClaimable2;
        // Nobody claimed yet

        vm.prank(alice);
        principalToken.combine(0, alice);

        (lastClaimedAmount,) = getLastClaimed(rewardTokens[0]);
        assertEq(lastClaimedAmount, totalClaimable2);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable2);

        vm.warp(expiry);
        address[] memory users3 = new address[](1);
        users3[0] = address(principalToken);
        address[] memory tokens3 = new address[](1);
        tokens3[0] = rewardTokens[0];
        uint256[] memory amounts3 = new uint256[](1);
        amounts3[0] = totalClaimable3;
        deal(rewardTokens[0], address(distributor), totalClaimable3);
        distributor.claim(users3, tokens3, amounts3, new bytes32[][](0));

        // Accrued reward is updated
        vm.prank(alice);
        principalToken.combine(0, alice);

        (lastClaimedAmount,) = getLastClaimed(rewardTokens[0]);
        assertEq(lastClaimedAmount, totalClaimable3);
        assertEq(ERC20(rewardTokens[0]).balanceOf(treasury), totalClaimable3);
        assertEq(ERC20(rewardTokens[0]).balanceOf(address(principalToken)), 0, "Reward token balance");
    }

    function test_GetCustomArgs() public view {
        (address[] memory _rewardTokens, address _distributor, address _operator, address _treasury) =
            MerklRewardProxy(address(rewardProxy)).getCustomArgs();

        assertEq(_distributor, address(distributor));
        assertEq(_operator, address(operator));
        assertEq(_treasury, treasury);
        assertEq(_rewardTokens.length, rewardTokens.length);
        assertEq(keccak256(abi.encode(_rewardTokens)), keccak256(abi.encode(rewardTokens)));
    }

    function test_RevertWhen_RewardTokensEmpty() public {
        bytes memory customArgs = abi.encode(new address[](0), distributor, operator, treasury);
        _test_RevertWhen_RewardTokensEmpty(customArgs);
    }

    function test_RevertWhen_DuplicatedRewardTokens() public {
        rewardTokens.push(rewardTokens[0]);
        bytes memory customArgs = abi.encode(rewardTokens, distributor, operator, treasury);
        _test_RevertWhen_DuplicatedRewardTokens(customArgs);
    }

    function test_RevertWhen_BadRewardTokens() public {
        address[] memory badRewardTokens = new address[](2);
        badRewardTokens[0] = address(0x02);
        badRewardTokens[1] = address(0x01); // Descending order
        bytes memory customArgs = abi.encode(badRewardTokens, distributor, operator, treasury);
        _test_RevertWhen_BadRewardTokens(customArgs);
    }

    function test_RevertWhen_BadDistributor() public {
        address badDistributor = address(0xbbbbb); // EOA
        bytes memory customArgs = abi.encode(rewardTokens, badDistributor, operator, treasury);
        cloneRewardProxy(customArgs);
        vm.expectRevert(Errors.MerklRewardProxy_InvalidDistributor.selector);
        rewardProxy.initialize();
    }
}

contract MerklRewardProxyForkTest is Test {
    address alice = makeAddr("alice");

    address[] rewardTokens = [0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270, 0x8505b9d2254A7Ae468c0E9dd10Ccea3A837aef5c];
    IMerkl distributor = IMerkl(0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae);
    address operator = makeAddr("operator");
    address treasury = makeAddr("treasury");
    // https://polygonscan.com/token/0xe77c0fb993beb15c9b68eb30588526f955100d4d
    PrincipalToken principalToken = PrincipalToken(0xE77c0FB993BeB15c9b68eB30588526f955100d4d);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("polygon"), 69877161);

        Factory factory = principalToken.i_factory();

        address implementation = address(new MerklRewardProxy());

        address owner = factory.i_accessManager().owner();

        vm.startPrank(owner);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = factory.setModuleImplementation.selector;
        factory.i_accessManager().grantRoles(owner, DEV_ROLE);
        factory.i_accessManager().grantTargetFunctionRoles(owner, selectors, DEV_ROLE);

        factory.setModuleImplementation(REWARD_PROXY_MODULE_INDEX, implementation, true);
        vm.stopPrank();

        address curator = principalToken.i_accessManager().owner();
        vm.startPrank(curator);
        selectors[0] = factory.updateModules.selector;
        principalToken.i_accessManager().grantRoles(curator, DEV_ROLE);
        principalToken.i_accessManager().grantTargetFunctionRoles(address(factory), selectors, DEV_ROLE);

        Factory.ModuleParam[] memory params = new Factory.ModuleParam[](1);
        params[0] = Factory.ModuleParam({
            moduleType: REWARD_PROXY_MODULE_INDEX,
            implementation: implementation,
            immutableData: abi.encode(rewardTokens, distributor, operator, treasury)
        });
        factory.updateModules(address(principalToken), params);
        vm.stopPrank();
    }

    function test_ImmutableParams() public view {
        (address[] memory _rewardTokens, address _distributor, address _operator, address _treasury) = MerklRewardProxy(
            principalToken.i_factory().moduleFor(address(principalToken), REWARD_PROXY_MODULE_INDEX)
        ).getCustomArgs();

        assertEq(keccak256(abi.encode(_rewardTokens)), keccak256(abi.encode(rewardTokens)));
        assertEq(_distributor, address(distributor));
        assertEq(_operator, operator);
        assertEq(_treasury, treasury);
    }

    function test_ClaimRewards() public {
        principalToken.supply(0, alice); // Make a call to `approveOperator()`

        (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) =
            getMerklParams();

        vm.prank(operator);
        distributor.claim(users, tokens, amounts, proofs);

        principalToken.supply(0, alice);

        address whale = 0x303715a9da8043Bfb2ec65C4D5Daf3eb63c7a9dD; // YT whale
        vm.prank(whale);
        (, TokenReward[] memory rewards1) = principalToken.collect(whale, whale);
        for (uint256 i = 0; i < rewards1.length; i++) {
            assertEq(rewards1[i].token, rewardTokens[i]);
            assertEq(rewards1[i].amount, 0, "Rewards go to treasury first");
            assertEq(ERC20(rewardTokens[i]).balanceOf(treasury), amounts[i], "Rewards go to treasury first");
        }

        principalToken.supply(0, alice); // It doesn't revoke operator
        assertEq(distributor.operators(address(principalToken), operator), 1);

        vm.prank(whale);
        (, TokenReward[] memory rewards2) = principalToken.collect(whale, whale);
        for (uint256 i = 0; i < rewards2.length; i++) {
            assertEq(rewards2[i].token, rewardTokens[i]);
            assertEq(rewards2[i].amount, 0, "Already claimed");
            assertEq(ERC20(rewardTokens[i]).balanceOf(treasury), amounts[i], "Already claimed");
        }
    }

    error NotWhitelisted(); // Merkl

    function test_RevertWhenNotWhitelisted() public {
        (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) =
            getMerklParams();

        vm.expectRevert(NotWhitelisted.selector);
        vm.prank(operator);
        distributor.claim(users, tokens, amounts, proofs);
    }

    function getMerklParams()
        public
        pure
        returns (address[] memory, address[] memory, uint256[] memory, bytes32[][] memory)
    {
        address[] memory users = new address[](2);
        users[0] = 0xE77c0FB993BeB15c9b68eB30588526f955100d4d;
        users[1] = 0xE77c0FB993BeB15c9b68eB30588526f955100d4d;

        address[] memory tokens = new address[](2);
        tokens[0] = 0x8505b9d2254A7Ae468c0E9dd10Ccea3A837aef5c;
        tokens[1] = 0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1393225815401689;
        amounts[1] = 320516352403144867;

        bytes32[][] memory proofs = new bytes32[][](2);

        bytes32[] memory proof0 = new bytes32[](18);
        proof0[0] = 0xe611a42ea7beda682ce467a6bf2f3533b596d6425705ed8d714a29febc0e38ab;
        proof0[1] = 0x0321915a618e653b941dc93ee33ea3178c30845504cec4c3ca20a494b147d8c3;
        proof0[2] = 0xae100561add846b23aba537e350b56067dc3ac2702d5debfb368b63bbcc17cdc;
        proof0[3] = 0x36adfe279872844465e3c3befd433025f15c4bb9f770ab1bdc4408419eb1f69e;
        proof0[4] = 0xbe965dd3ae42c3ec7cccc3463ae45fe7f7147cf3c95842fc1419eefaa1efba50;
        proof0[5] = 0x96c214664007aceb4175236e93f3dc4e0fb60da071c75a083a08e048136f7a1d;
        proof0[6] = 0x0ca4c9ec06c83a8bf0185f0c402d730f77b3092ea1e67ab4e1c060fa4483afb0;
        proof0[7] = 0xcbbc7891b8cb7045bacc76f3c30d12cc88d17534ffc4b950e308403a10f5dab4;
        proof0[8] = 0x9f8ae782eb202e2b5dedb5a21040c88954ca1e33231e00c33327917ad50695ba;
        proof0[9] = 0x71985ccfadc38bbaf6d0a142daf0901851b1073d698c16395d5d2079a68dfa38;
        proof0[10] = 0xbb0b8dc8031e0c7d3fadbba58d4feee665931eb8c7cfbdca3b8fc251244c2512;
        proof0[11] = 0x70e8a52a6d98009b82efefac47a9c517f629c144c950015a5fc6fa261dedf668;
        proof0[12] = 0x3c8fe69b36f4f12d8583e8c086038864e80f1d917b5f76e48a8223693190a19b;
        proof0[13] = 0xffeac5ab3ab18f5d301681687731e16df27389370ae9d9a2c1a2ed1228c0df09;
        proof0[14] = 0x08422aeb2c91ef2912c7afcb225de3df897e2c610efe9dcaf3eac787dadf431c;
        proof0[15] = 0x26390ddaf478e4e9b5c70d7d0c9894dbcd25f9ef281b65869ced3882da294294;
        proof0[16] = 0xd6fbf7265b2bbbdba2f36e341615e8e9fe701a8da89e92d56a7e113a15538458;
        proof0[17] = 0xd2687cd1d5938297b708bed95d95ae5ec283770699cf2f7569532f6a6bc04ac3;

        bytes32[] memory proof1 = new bytes32[](18);
        proof1[0] = 0x74b60b4cf77efc966193526442268010a215176e2d804eb9d7c460d5d1f13b2d;
        proof1[1] = 0xad9b520b2b028fd7b87a41b9dc5c7d9c9f06378426e214d8b1cef96a4d268928;
        proof1[2] = 0x8bb0c5b3dcdbbb8320ba32bfbd202654e6ad478ef7227b512d08e55fd3c0a7d9;
        proof1[3] = 0xe336d257c1c499fec285bdabab34b892c09cff6385ad8995f5ac1d6161c57303;
        proof1[4] = 0x9cee35a374faa328e0312c9b691091ef337628259fe5ded20b1030646d86255b;
        proof1[5] = 0x48d6f09e0278f9d15875af6d5e3bd178fc76e1b2e3944bebe03fb7d6d9a0bfb6;
        proof1[6] = 0x039bbbb321021ffb55f180142494ea4a9fb3ee08e6bb18c49f5dc12302c849d3;
        proof1[7] = 0x75f49f352017b5ac85949a364a35c15485eaad0b1e54783f17bc0625cd8b098b;
        proof1[8] = 0x2add778027ef8aa7a3dbb42c7afdc46cb1fb7d18ea96287e6ae5794184b760cb;
        proof1[9] = 0x5962166af503e47c2809946b79325559b3c54158d0fa927df1ba9c9449bcfe07;
        proof1[10] = 0xc137a57983d2d27a7d43f5502fcc29e6462b1a24cd29378d15f9f7d5661d8a3e;
        proof1[11] = 0xaa155abd2c3f9f184223fd1526aafd8ac3034e3e67efdb7ca54bc7149b9c85cd;
        proof1[12] = 0x1107f22159d2af196220355c8b15ee6539756c84b1e0c659120436215e7fad35;
        proof1[13] = 0x1b2a3fad4b8b8116507f018d70618fd3181282f502c0d5c385d5f7b1f0a054b4;
        proof1[14] = 0x9f292b12097c308ca382b5f2dc71233c76d017fff9e936696717fc74fadfd938;
        proof1[15] = 0xf55470e22c399e2b208038cedd76e9f3b2e7df88f8cf591d9ba7b08461cc507b;
        proof1[16] = 0x03d28d1bd243818c80ff493910b7fd484a286fafcb537839ccb296e4534fa119;
        proof1[17] = 0xd2687cd1d5938297b708bed95d95ae5ec283770699cf2f7569532f6a6bc04ac3;

        proofs[0] = proof0;
        proofs[1] = proof1;

        return (users, tokens, amounts, proofs);
    }
}
