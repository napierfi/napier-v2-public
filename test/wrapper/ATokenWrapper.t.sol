// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {BaseWrapperTest} from "./StandardERC4626Wrapper.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {DynamicArrayLib} from "solady/src/utils/DynamicArrayLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import "src/Types.sol";
import "src/Errors.sol";
import {IPool} from "src/wrapper/aave-v3/interfaces/IPool.sol";
import {IAToken} from "src/wrapper/aave-v3/interfaces/IAToken.sol";
import {IMerkl} from "src/interfaces/external/IMerkl.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {StandardERC4626Wrapper} from "src/wrapper/StandardERC4626Wrapper.sol";
import "src/Constants.sol" as Constants;

import {ATokenWrapper} from "src/wrapper/aave-v3/ATokenWrapper.sol";
import {WrapperConnector, toDynamicArray} from "src/modules/connectors/WrapperConnector.sol";

using DynamicArrayLib for DynamicArrayLib.DynamicArray;

contract MockMerkl is IMerkl {
    function claim(address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs)
        external
    {
        proofs;
        for (uint256 i = 0; i < users.length; i++) {
            require(ERC20(tokens[i]).balanceOf(address(this)) >= amounts[i], "Merkl: insufficient balance");
            ERC20(tokens[i]).transfer(users[i], amounts[i]);
        }
    }

    function claimed(address account, address token) external view override returns (Claim memory) {}

    function operators(address, /* user */ address /* operator */ ) external pure override returns (uint256) {
        return 1;
    }

    function toggleOperator(address user, address operator) external override {}
}

abstract contract ATokenWrapperTest is BaseWrapperTest {
    address donor = makeAddr("donor");
    address treasury = makeAddr("treasury");

    IPool pool;

    struct Init {
        uint256 underlyings;
        uint256 assets;
    }

    Init init;
    address base;
    address aToken;

    uint256 bOne;
    uint256 aTokenOne;

    /// @notice Override setUp to use mainnet fork
    /// function setUp() public override {
    ///     base = PYUSD;
    ///     aToken = APYUSD;
    ///
    ///     super.setUp();
    /// }
    function setUp() public virtual override {
        pool = IAToken(aToken).POOL();

        super.setUp();

        bOne = 10 ** ERC20(base).decimals();
        aTokenOne = 10 ** ERC20(aToken).decimals();
        init = Init({underlyings: 10000 * bOne, assets: 10000 * aTokenOne});

        deal(base, alice, init.underlyings);
        _approve(base, alice, address(pool), type(uint256).max);
        vm.prank(alice);
        pool.supply(base, init.underlyings, alice, 0);

        deal(base, alice, init.assets);
    }

    function _deployWrapper() internal override returns (address) {
        address implementation = address(new ATokenWrapper());
        bytes memory args = abi.encode(aToken);
        address instance = LibClone.clone(implementation, args);

        ATokenWrapper(instance).initialize(); // Callback is triggered on initialization

        return instance;
    }

    function _label() internal override {
        super._label();

        vm.label(address(pool), "aave-pool");
        vm.label(base, ERC20(base).symbol());
        vm.label(aToken, ERC20(aToken).symbol());
    }

    function donate(uint256 assets) internal {
        deal(base, donor, assets);
        _approve(base, donor, address(pool), type(uint256).max);
        vm.prank(donor);
        pool.supply(base, assets, donor, 0);
    }

    function grantTargetFunctionRoles(address target, bytes4[] memory selectors, uint256 roles) internal {
        vm.startPrank(admin);
        ATokenWrapper(wrapper).i_accessManager().grantTargetFunctionRoles(target, selectors, roles);
        vm.stopPrank();
    }

    function test_Immutables() public view {
        assertEq(ATokenWrapper(wrapper).asset(), base, "asset");
        assertEq(ATokenWrapper(wrapper).vault(), aToken, "vault");
        assertEq(address(ATokenWrapper(wrapper).i_accessManager()), address(napierAccessManager), "access manager");
    }

    function test_RevertWhen_Reinitialize() public {
        vm.expectRevert(bytes4(0xf92ee8a9)); // `InvalidInitialization()`
        ATokenWrapper(wrapper).initialize();
    }

    function test_DepositAsset() public {
        uint256 assets = init.assets;
        uint256 preview = ATokenWrapper(wrapper).previewDeposit(Token.wrap(base), assets);
        _approve(base, alice, wrapper, assets);
        vm.prank(alice);
        uint256 shares = ATokenWrapper(wrapper).deposit(Token.wrap(base), assets, bob);

        assertEq(preview, shares, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), assets, 2, "totalAssets");

        donate(ATokenWrapper(wrapper).totalAssets() / 9); // Donate and Inflate share price

        // deposit again
        uint256 assets2 = init.assets;
        deal(base, alice, assets2);

        uint256 preview2 = ATokenWrapper(wrapper).previewDeposit(Token.wrap(base), assets2);
        _approve(base, alice, wrapper, assets2);
        vm.prank(alice);
        uint256 shares2 = ATokenWrapper(wrapper).deposit(Token.wrap(base), assets, alice);

        assertEq(preview2, shares2, "preview2");
        assertEq(ERC20(wrapper).balanceOf(alice), shares2, "shares2");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), assets + assets2, 2, "totalAssets");
    }

    function test_DepositAToken() public {
        uint256 amount = 33 * bOne;

        uint256 totalAssets = ATokenWrapper(wrapper).totalAssets();
        uint256 preview = ATokenWrapper(wrapper).previewDeposit(Token.wrap(aToken), amount);
        _approve(aToken, alice, wrapper, amount);
        vm.prank(alice);
        uint256 shares = ATokenWrapper(wrapper).deposit(Token.wrap(aToken), amount, bob);

        assertEq(preview, shares, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssets + amount, 2, "totalAssets");

        donate(ATokenWrapper(wrapper).totalAssets() / 9); // Donate and Inflate share price

        // deposit again
        uint256 bobBalanceBefore = ERC20(wrapper).balanceOf(bob);

        uint256 amount2 = 55 * bOne;
        uint256 preview2 = ATokenWrapper(wrapper).previewDeposit(Token.wrap(aToken), amount2);
        _approve(aToken, alice, wrapper, amount2);
        vm.prank(alice);
        uint256 shares2 = ATokenWrapper(wrapper).deposit(Token.wrap(aToken), amount2, bob);

        assertEq(preview2, shares2, "preview2");
        assertEq(ERC20(wrapper).balanceOf(bob), bobBalanceBefore + shares2, "shares2");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssets + amount + amount2, 2, "totalAssets");
    }

    function test_RedeemAsset() public {
        test_ERC4626_Deposit(); // Bob has shares of wrapper
        require(ERC20(wrapper).balanceOf(bob) > 0, "bob has no shares");

        donate(ATokenWrapper(wrapper).totalAssets() / 9); // Donate and Inflate share price

        uint256 totalAssetsPrior = ATokenWrapper(wrapper).totalAssets();
        uint256 bobBalancePrior = ERC20(wrapper).balanceOf(bob);

        uint256 shares = ERC20(wrapper).balanceOf(bob) / 3;
        uint256 preview = ATokenWrapper(wrapper).previewRedeem(Token.wrap(base), shares);
        vm.prank(bob);
        uint256 assets = ATokenWrapper(wrapper).redeem(Token.wrap(base), shares, bob);

        assertEq(preview, assets, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), bobBalancePrior - shares, "shares");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssetsPrior - assets, 2, "totalAssets");
    }

    function test_RedeemAToken() public {
        test_ERC4626_Deposit(); // Bob has shares of wrapper
        require(ERC20(wrapper).balanceOf(bob) > 0, "bob has no shares");

        donate(ATokenWrapper(wrapper).totalAssets() / 9); // Donate and Inflate share price

        uint256 totalAssetsPrior = ATokenWrapper(wrapper).totalAssets();
        uint256 bobBalancePrior = ERC20(wrapper).balanceOf(bob);

        uint256 shares = ERC20(wrapper).balanceOf(bob) / 3;
        uint256 preview = ATokenWrapper(wrapper).previewRedeem(Token.wrap(aToken), shares);
        vm.prank(bob);
        uint256 underlyings = ATokenWrapper(wrapper).redeem(Token.wrap(aToken), shares, bob);

        assertEq(preview, underlyings, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), bobBalancePrior - shares, "shares");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssetsPrior - underlyings, 2, "totalAssets");
    }

    function test_ERC4626_Deposit() public {
        uint256 assets = 713431;
        uint256 preview = ATokenWrapper(wrapper).previewDeposit(assets);
        _approve(base, alice, wrapper, assets);
        vm.prank(alice);
        uint256 shares = ATokenWrapper(wrapper).deposit(assets, bob);

        assertEq(preview, shares, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        assertEq(ATokenWrapper(wrapper).totalAssets(), assets, "totalAssets");
    }

    function test_ERC4626_Mint() public {
        uint256 assets = 213903293;
        uint256 preview = ATokenWrapper(wrapper).previewMint(assets);
        _approve(base, alice, wrapper, assets);
        vm.prank(alice);
        uint256 shares = ATokenWrapper(wrapper).mint(assets, bob);

        assertEq(preview, shares, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        assertEq(ATokenWrapper(wrapper).totalAssets(), assets, "totalAssets");
    }

    function test_ERC4626_Redeem() public {
        test_ERC4626_Deposit(); // Bob has shares of wrapper
        require(ERC20(wrapper).balanceOf(bob) > 0, "bob has no shares");

        donate(ATokenWrapper(wrapper).totalAssets() / 9); // Donate and Inflate share price

        uint256 totalAssetsPrior = ATokenWrapper(wrapper).totalAssets();
        uint256 bobBalancePrior = ERC20(wrapper).balanceOf(bob);

        uint256 shares = ERC20(wrapper).balanceOf(bob) / 3;
        uint256 preview = ATokenWrapper(wrapper).previewRedeem(shares);
        vm.prank(bob);
        uint256 assets = ATokenWrapper(wrapper).redeem(shares, bob, bob);

        assertEq(preview, assets, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), bobBalancePrior - shares, "shares");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssetsPrior - assets, 2, "totalAssets");
    }

    function test_ERC4626_Withdraw() public {
        test_ERC4626_Deposit(); // Bob has shares of wrapper
        require(ERC20(wrapper).balanceOf(bob) > 0, "bob has no shares");

        donate(ATokenWrapper(wrapper).totalAssets() / 13); // Donate and Inflate share price

        uint256 totalAssetsPrior = ATokenWrapper(wrapper).totalAssets();
        uint256 bobBalancePrior = ERC20(wrapper).balanceOf(bob);

        uint256 assets = ERC20(wrapper).balanceOf(bob) / 4;
        uint256 preview = ATokenWrapper(wrapper).previewWithdraw(assets);
        vm.prank(bob);
        uint256 shares = ATokenWrapper(wrapper).withdraw(assets, bob, bob);

        assertEq(preview, assets, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), bobBalancePrior - shares, "shares");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssetsPrior - assets, 2, "totalAssets");
    }

    function testFuzz_TokenIn(Token token) public override {
        token = boundTokenIn(token);

        uint256 callerBalance = 10 ether;
        uint256 tokens = 913893305211;

        if (token.unwrap() == aToken) {
            address issuer = makeAddr("issuer");
            deal(base, issuer, type(uint96).max);
            _approve(base, issuer, address(pool), type(uint256).max);
            vm.prank(issuer);
            pool.supply(base, tokens, alice, 0);
            // Actual issue amount may be rounded down
            callerBalance = ERC20(aToken).balanceOf(alice);
            tokens = callerBalance;
        } else {
            deal(token.unwrap(), alice, callerBalance);
        }

        if (token.isNotNative()) {
            _approve(token, alice, wrapper, tokens);
        }

        vm.startPrank(alice);
        uint256 preview = ATokenWrapper(wrapper).previewDeposit(token, tokens);
        uint256 shares = ATokenWrapper(wrapper).deposit{value: token.isNative() ? tokens : 0}(token, tokens, bob);
        vm.stopPrank();

        assertApproxEqAbs(preview, shares, 3, "preview");
        assertEq(ERC20(wrapper).balanceOf(bob), shares, "shares");
        if (token.isNative()) {
            assertEq(address(alice).balance, callerBalance - tokens, "tokens");
        } else {
            assertEq(token.erc20().balanceOf(alice), callerBalance - tokens, "tokens");
        }
    }

    function test_Deposit_RevertWhen_Reentrant() public {
        vm.skip({skipTest: true});
    }

    function test_Redeem_RevertWhen_Reentrant() public {
        vm.skip({skipTest: true});
    }

    function test_ERC4626_Deposit_RevertWhen_Reentrant() public {
        vm.skip({skipTest: true});
    }

    function test_ERC4626_Mint_RevertWhen_Reentrant() public {
        vm.skip({skipTest: true});
    }

    function test_ERC4626_Withdraw_RevertWhen_Reentrant() public {
        vm.skip({skipTest: true});
    }

    function test_ERC4626_Redeem_RevertWhen_Reentrant() public {
        vm.skip({skipTest: true});
    }

    function test_ClaimRewards() public {
        // Setup
        MockMerkl merkl = new MockMerkl();
        uint256 amount = 432580853231313;
        deal(base, address(merkl), amount);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ATokenWrapper.sweepRewards.selector;
        grantTargetFunctionRoles({target: wrapper, selectors: selectors, roles: Constants.DEV_ROLE});

        // Sweep rewards
        address[] memory users = new address[](1);
        users[0] = address(wrapper);
        address[] memory tokens = new address[](1);
        tokens[0] = base;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        ATokenWrapper.MerklParams memory params = ATokenWrapper.MerklParams({
            distributor: merkl,
            users: users,
            tokens: tokens,
            amounts: amounts,
            proofs: new bytes32[][](0)
        });
        vm.prank(dev);
        ATokenWrapper(wrapper).sweepRewards(params, tokens, treasury);

        assertEq(ERC20(base).balanceOf(treasury), amount, "base");
    }

    function test_SweepRewards() public {
        // Setup
        uint256 amount = 8238938;
        deal(base, wrapper, amount);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ATokenWrapper.sweepRewards.selector;
        grantTargetFunctionRoles({target: wrapper, selectors: selectors, roles: Constants.DEV_ROLE});

        // Sweep rewards
        ATokenWrapper.MerklParams memory emptyParams;
        address[] memory tokens = new address[](1);
        tokens[0] = base;
        vm.prank(dev);
        ATokenWrapper(wrapper).sweepRewards(emptyParams, tokens, treasury);

        assertEq(ERC20(base).balanceOf(treasury), amount, "base");
    }

    function test_SweepRewards_RevertWhen_RewardIsUnderlyingToken() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ATokenWrapper.sweepRewards.selector;
        grantTargetFunctionRoles({target: wrapper, selectors: selectors, roles: Constants.DEV_ROLE});

        ATokenWrapper.MerklParams memory emptyParams;
        address[] memory tokens = new address[](1);
        tokens[0] = aToken;
        vm.prank(dev);
        vm.expectRevert(Errors.ATokenWrapper_CannotSweepUnderlyingToken.selector);
        ATokenWrapper(wrapper).sweepRewards(emptyParams, tokens, treasury);
    }

    function test_SweepRewards_RevertWhen_NotAuthorized() public {
        ATokenWrapper.MerklParams memory params = ATokenWrapper.MerklParams({
            distributor: IMerkl(address(0)),
            users: new address[](0),
            tokens: new address[](0),
            amounts: new uint256[](0),
            proofs: new bytes32[][](0)
        });
        address[] memory tokens = new address[](1);
        tokens[0] = base;
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        vm.prank(alice);
        ATokenWrapper(wrapper).sweepRewards(params, tokens, alice);
    }

    function test_GetTokenInList() public view {
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenInList());
        assertEq(tokens.asAddressArray().length, 2, "tokens.length");
        assertTrue(tokens.contains(aToken), "Token not in list");
        assertTrue(tokens.contains(base), "Token not in list");
    }

    function test_GetTokenOutList() public view {
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenOutList());
        assertEq(tokens.asAddressArray().length, 2, "tokens.length");
        assertTrue(tokens.contains(base), "Token not in list");
        assertTrue(tokens.contains(aToken), "Token not in list");
    }

    function test_MaxDeposit() public {
        uint256 maxDeposit = ATokenWrapper(wrapper).maxDeposit(address(0));

        require(maxDeposit > 0, "TEST-ASSUMPTION: maxDeposit > 0");

        deal(base, alice, maxDeposit);
        _approve(base, alice, wrapper, maxDeposit);
        vm.prank(alice);
        ATokenWrapper(wrapper).deposit(Token.wrap(base), maxDeposit, alice);

        assertApproxEqAbs(ATokenWrapper(wrapper).maxDeposit(address(0)), 0, 1, "zero max deposit");
    }

    function test_MaxRedeem() public {
        uint256 assets = 10000000000;
        deal(base, alice, assets);
        _approve(base, alice, wrapper, assets);
        vm.prank(alice);
        uint256 shares = ATokenWrapper(wrapper).deposit(Token.wrap(base), assets, alice);

        uint256 maxRedeem = ATokenWrapper(wrapper).maxRedeem(alice);
        assertEq(maxRedeem, shares, "max redeem");
    }

    function test_MaxDeposit_When_NotActiveOrPaused() public {
        address ACLManagerV3 = 0xc2aaCf6553D20d1e9d78E365AAba8032af9c85b0;
        address poolConfigurator = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;

        vm.mockCall(ACLManagerV3, abi.encodeWithSignature("isPoolAdmin(address)"), abi.encode(true));

        IPoolConfigurator(poolConfigurator).setReservePause(base, true);

        // Max deposit check
        assertEq(ATokenWrapper(wrapper).maxDeposit(address(0)), 0, "zero max deposit");
        assertEq(ATokenWrapper(wrapper).maxMint(address(0)), 0, "zero max mint");

        // Token List check
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenInList());
        assertFalse(tokens.contains(base), "base in list");
        assertTrue(tokens.contains(aToken), "aToken in list");

        tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenOutList());
        assertFalse(tokens.contains(base), "base in list");
        assertTrue(tokens.contains(aToken), "aToken in list");
    }

    function test_MaxRedeem_When_NotActiveOrPaused() public {
        deal(base, alice, 10000000);
        _approve(base, alice, wrapper, 10000000);
        vm.prank(alice);
        ATokenWrapper(wrapper).deposit(Token.wrap(base), 10000000, alice);

        address ACLManagerV3 = 0xc2aaCf6553D20d1e9d78E365AAba8032af9c85b0;
        address poolConfigurator = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;

        vm.mockCall(ACLManagerV3, abi.encodeWithSignature("isPoolAdmin(address)"), abi.encode(true));

        IPoolConfigurator(poolConfigurator).setReservePause(base, true);

        // Max redeem check
        assertEq(ATokenWrapper(wrapper).maxRedeem(alice), 0, "zero max redeem");
        assertEq(ATokenWrapper(wrapper).maxWithdraw(alice), 0, "zero max withdraw");

        // Token List check
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenInList());
        assertFalse(tokens.contains(base), "base in list");
        assertTrue(tokens.contains(aToken), "aToken in list");

        tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenOutList());
        assertFalse(tokens.contains(base), "base in list");
        assertTrue(tokens.contains(aToken), "aToken in list");
    }

    function test_MaxDeposit_When_SupplyCapReached() public {
        address ACLManagerV3 = 0xc2aaCf6553D20d1e9d78E365AAba8032af9c85b0;
        address poolConfigurator = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;

        // The new supply cap of the reserve in whole tokens. A supply cap of 0 signifies that there is no cap
        vm.mockCall(ACLManagerV3, abi.encodeWithSignature("isPoolAdmin(address)"), abi.encode(true));
        IPoolConfigurator(poolConfigurator).setSupplyCap(base, 1); // 1 whole token

        // Max deposit check
        assertEq(ATokenWrapper(wrapper).maxDeposit(address(0)), 0, "zero max deposit");
        assertEq(ATokenWrapper(wrapper).maxMint(address(0)), 0, "zero max mint");
        // Token List check
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(ATokenWrapper(wrapper).getTokenInList());
        assertFalse(tokens.contains(base), "base in list");
        assertTrue(tokens.contains(aToken), "aToken in list");
    }

    function test_MaxDeposit_When_SupplyCapUnlimited() public {
        address ACLManagerV3 = 0xc2aaCf6553D20d1e9d78E365AAba8032af9c85b0;
        address poolConfigurator = 0x64b761D848206f447Fe2dd461b0c635Ec39EbB27;

        // The new supply cap of the reserve in whole tokens. A supply cap of 0 signifies that there is no cap
        vm.mockCall(ACLManagerV3, abi.encodeWithSignature("isPoolAdmin(address)"), abi.encode(true));
        IPoolConfigurator(poolConfigurator).setSupplyCap(base, 0);

        // Max deposit check
        assertEq(ATokenWrapper(wrapper).maxDeposit(address(0)), type(uint256).max, "max deposit");
        assertEq(ATokenWrapper(wrapper).maxMint(address(0)), type(uint256).max, "max mint");
    }
}

interface IPoolConfigurator {
    function setSupplyCap(address asset, uint256 newSupplyCap) external;
    function setBorrowCap(address asset, uint256 newBorrowCap) external;
    function setReservePause(address asset, bool paused) external;
}

contract apyUSDWrapperTest is ATokenWrapperTest {
    address constant PYUSD = 0x6c3ea9036406852006290770BEdFcAbA0e23A0e8;
    address constant APYUSD = 0x0C0d01AbF3e6aDfcA0989eBbA9d6e85dD58EaB1E;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22_087_000);

        base = PYUSD;
        aToken = APYUSD;

        super.setUp();
    }

    function testFork_MaxDeposit_WhenReserveAccrualIsPending() public {
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        address governanceExecutor = 0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A;
        IPoolConfigurator poolConfigurator = IPoolConfigurator(0x64b761D848206f447Fe2dd461b0c635Ec39EbB27);
        uint256 collateral = 20_000 ether;

        vm.startPrank(governanceExecutor);
        poolConfigurator.setBorrowCap(PYUSD, 0);
        poolConfigurator.setSupplyCap(PYUSD, ERC20(APYUSD).totalSupply() / bOne + 10_000_000);
        vm.stopPrank();

        vm.deal(alice, collateral);
        vm.startPrank(alice);
        IWETH(weth).deposit{value: collateral}();
        assertTrue(ERC20(weth).approve(address(pool), collateral), "approve collateral");
        pool.supply(weth, collateral, alice, 0);
        pool.borrow(PYUSD, 5_000_000 * bOne, 2, 0, alice);
        vm.stopPrank();

        uint256 staleMaxDeposit = ATokenWrapper(wrapper).maxDeposit(alice);
        vm.warp(block.timestamp + 365 days);
        uint256 maxDeposit = ATokenWrapper(wrapper).maxDeposit(alice);
        assertGt(maxDeposit, 0, "positive max deposit");
        assertLt(maxDeposit, staleMaxDeposit, "pending accrual reduces capacity");

        deal(PYUSD, alice, staleMaxDeposit);
        _approve(PYUSD, alice, wrapper, staleMaxDeposit);
        _approve(PYUSD, alice, address(pool), staleMaxDeposit);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "51"));
        vm.prank(alice);
        pool.supply(PYUSD, staleMaxDeposit, alice, 0);

        vm.prank(alice);
        ATokenWrapper(wrapper).deposit(maxDeposit, alice);
    }

    function test_MaxWithdraw_WhenUnderlyingSentDirectlyToAToken() public {
        uint256 withdrawCapacity = _prepareDirectATokenDonation();

        uint256 maxWithdraw = ATokenWrapper(wrapper).maxWithdraw(alice);
        assertEq(maxWithdraw, withdrawCapacity, "max withdraw");

        uint256 balanceBefore = ERC20(PYUSD).balanceOf(bob);
        vm.prank(alice);
        ATokenWrapper(wrapper).withdraw(maxWithdraw, bob, alice);
        assertEq(ERC20(PYUSD).balanceOf(bob) - balanceBefore, withdrawCapacity, "withdrawn assets");
    }

    function test_MaxRedeem_WhenUnderlyingSentDirectlyToAToken() public {
        uint256 withdrawCapacity = _prepareDirectATokenDonation();

        uint256 maxRedeem = ATokenWrapper(wrapper).maxRedeem(alice);
        assertGt(maxRedeem, 0, "positive max redeem");
        assertLt(maxRedeem, ERC20(wrapper).balanceOf(alice), "max redeem");

        uint256 balanceBefore = ERC20(PYUSD).balanceOf(bob);
        vm.prank(alice);
        uint256 assets = ATokenWrapper(wrapper).redeem(maxRedeem, bob, alice);
        assertLe(assets, withdrawCapacity, "redeemed assets");
        assertEq(ERC20(PYUSD).balanceOf(bob) - balanceBefore, assets, "receiver assets");
    }

    function _prepareDirectATokenDonation() internal returns (uint256 withdrawCapacity) {
        address weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        uint256 collateral = 20_000 ether;
        uint256 wrapperAssets = 5_372_911;
        withdrawCapacity = 2_143_719;

        vm.prank(0x5300A1a15135EA4dc7aD5a167152C01EFc9b192A);
        IPoolConfigurator(0x64b761D848206f447Fe2dd461b0c635Ec39EbB27).setBorrowCap(PYUSD, 0);

        vm.deal(alice, collateral);
        vm.startPrank(alice);
        IWETH(weth).deposit{value: collateral}();
        assertTrue(ERC20(weth).approve(address(pool), collateral), "approve collateral");
        pool.supply(weth, collateral, alice, 0);

        pool.borrow(PYUSD, wrapperAssets, 2, 0, alice);
        assertTrue(ERC20(PYUSD).approve(wrapper, wrapperAssets), "approve wrapper");
        ATokenWrapper(wrapper).deposit(wrapperAssets, alice);

        uint256 virtualUnderlyingBalance = pool.getVirtualUnderlyingBalance(PYUSD);
        pool.borrow(PYUSD, virtualUnderlyingBalance - withdrawCapacity, 2, 0, alice);

        uint256 rawUnderlyingBalance = ERC20(PYUSD).balanceOf(APYUSD);
        assertTrue(ERC20(PYUSD).transfer(APYUSD, 1), "direct transfer");
        vm.stopPrank();

        assertEq(pool.getVirtualUnderlyingBalance(PYUSD), withdrawCapacity, "virtual pool balance");
        assertEq(ERC20(PYUSD).balanceOf(APYUSD), rawUnderlyingBalance + 1, "raw pool balance");
        uint256 rawPoolBalance = rawUnderlyingBalance + 1;
        uint256 ownerAssets = ATokenWrapper(wrapper).convertToAssets(ERC20(wrapper).balanceOf(alice));
        uint256 overstatedWithdraw = rawPoolBalance < ownerAssets ? rawPoolBalance : ownerAssets;
        assertGt(overstatedWithdraw, withdrawCapacity, "old max withdraw");

        vm.expectRevert();
        vm.prank(wrapper);
        pool.withdraw(PYUSD, overstatedWithdraw, wrapper);
    }
}

contract aWETHWrapperTest is ATokenWrapperTest {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    WrapperConnector connector;

    function setUp() public override {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22_087_000);

        base = WETH;
        aToken = AWETH;

        super.setUp();

        address implementation = address(new WrapperConnector());
        bytes memory args = abi.encode(wrapper, WETH);
        connector = WrapperConnector(payable(LibClone.clone(implementation, args)));

        vm.label(address(connector), "connector");
    }

    function test_DepositNativeETH() public {
        uint256 value1 = 3 ether;

        deal(alice, value1);

        uint256 preview = connector.previewDeposit(Token.wrap(Constants.NATIVE_ETH), value1);
        vm.prank(alice);
        uint256 shares = connector.deposit{value: value1}(Token.wrap(Constants.NATIVE_ETH), value1, alice);

        assertEq(shares, preview, "shares");
        assertEq(address(wrapper).balance, 0, "wrapper native balance");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), value1, 2, "totalAssets");

        donate(ATokenWrapper(wrapper).totalAssets() / 8); // Donate and Inflate share price

        uint256 value2 = 0.8 ether;
        deal(alice, value2);

        uint256 bobBalanceBefore = ERC20(wrapper).balanceOf(bob);
        uint256 totalAssetsBefore = ATokenWrapper(wrapper).totalAssets();

        uint256 preview2 = connector.previewDeposit(Token.wrap(Constants.NATIVE_ETH), value2);
        vm.prank(alice);
        uint256 shares2 = connector.deposit{value: value2}(Token.wrap(Constants.NATIVE_ETH), value2, bob);

        assertEq(address(wrapper).balance, 0, "wrapper native balance");
        assertEq(shares2, preview2, "shares2");
        assertEq(ERC20(wrapper).balanceOf(bob), bobBalanceBefore + shares2, "bob balance");
        assertApproxEqAbs(ATokenWrapper(wrapper).totalAssets(), totalAssetsBefore + value2, 2, "totalAssets");
    }

    function test_RedeemNativeETH() public {
        test_DepositNativeETH(); // Setup

        uint256 shares = ERC20(wrapper).balanceOf(bob);
        require(shares > 0, "bob has no shares");

        uint256 bobBalanceBefore = address(bob).balance;

        _approve(wrapper, bob, address(connector), shares);
        uint256 preview = connector.previewRedeem(Token.wrap(Constants.NATIVE_ETH), shares);
        vm.prank(bob);
        uint256 assets = connector.redeem(Token.wrap(Constants.NATIVE_ETH), shares, bob);

        assertEq(shares, preview, "shares");
        assertEq(address(bob).balance, bobBalanceBefore + assets, "bob balance");
        assertEq(address(wrapper).balance, 0, "wrapper native balance");
    }

    function test_RevertWhen_InvalidETHAmount() public {
        deal(alice, 1 ether);
        vm.expectRevert(Errors.WrapperConnector_InvalidETHAmount.selector);
        vm.prank(alice);
        connector.deposit{value: 1001}(Token.wrap(Constants.NATIVE_ETH), 1000, bob);
    }

    function test_RevertWhen_UnexpectedETHAmount() public {
        deal(alice, 1 ether);
        vm.expectRevert(Errors.WrapperConnector_UnexpectedETH.selector);
        vm.prank(alice);
        connector.deposit{value: 1}(Token.wrap(base), 1000, bob);
    }

    function test_Connector_GetTokenInList() public view {
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(connector.getTokenInList());
        assertEq(tokens.asAddressArray().length, 3, "tokens.length");
        assertTrue(tokens.contains(aToken), "Token not in list");
        assertTrue(tokens.contains(base), "Token not in list");
        assertTrue(tokens.contains(Constants.NATIVE_ETH), "Token not in list");
    }

    function test_Connector_GetTokenOutList() public view {
        DynamicArrayLib.DynamicArray memory tokens = toDynamicArray(connector.getTokenOutList());
        assertEq(tokens.asAddressArray().length, 3, "tokens.length");
        assertTrue(tokens.contains(base), "Token not in list");
        assertTrue(tokens.contains(aToken), "Token not in list");
        assertTrue(tokens.contains(Constants.NATIVE_ETH), "Token not in list");
    }
}
