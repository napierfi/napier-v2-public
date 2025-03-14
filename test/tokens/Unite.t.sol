// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {PrincipalTokenTest} from "../shared/PrincipalToken.t.sol";
import {CombineAccrualTest} from "./Combine.t.sol";
import "../Property.sol" as Property;

import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";

import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {IUniteHook} from "src/interfaces/IHook.sol";
import {Snapshot} from "src/utils/YieldMathLib.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";

contract UnitePreExpiryTest is PrincipalTokenTest {
    function setUp() public override {
        super.setUp();
        _delta_ = 2;
    }

    function test_Unite() public {
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(bOne)
        });

        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // 70% split fee
        setFeePcts(newFeePcts);
        _test_Unite(init, shares);
    }

    function testFuzz_Unite(Init memory init, uint256 shares, FeePcts newFeePcts) public boundInit(init) {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        _test_Unite(init, shares);
    }

    /// @notice Test `unite` function
    function _test_Unite(Init memory init, uint256 shares) internal {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        shares = bound(shares, 0, _max_unite(caller));
        prop_unite(caller, receiver, shares);
    }

    function test_RevertWhen_CollectRewardFailed() public {
        vm.skip(true);
    }

    function test_RevertWhen_BadRewardProxy() public {
        setUpVault(
            Init({
                user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
                share: [uint256(1e18), 90331, 381039, 0],
                principal: [uint256(2192092), 189310, 0, 0],
                yield: 31093213131
            })
        );

        setBadRewardProxy();

        vm.prank(alice);
        vm.expectRevert(Errors.PrincipalToken_UnderlyingTokenBalanceChanged.selector);
        principalToken.unite(100, alice);
    }
}

contract UniteSettlementTest is PrincipalTokenTest {
    function test_Settle() public {
        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // 0 % performance fee
        setFeePcts(newFeePcts);

        _delta_ = 2;
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(bOne)
        });

        // Execution
        _test_Unite(init, shares, expiry);

        address caller = init.user[0];
        uint256 newAccrued = principalToken.getUserYield(caller).accrued;

        // Assertions
        assertGt(newAccrued, 0, Property.T01_INTEREST_ACCURAL);
        assertTrue(principalToken.isSettled(), "Settlement should be done");
    }

    /// @notice Test `unite` function at the timestamp of `ts`
    function _test_Unite(Init memory init, uint256 shares, uint256 ts) internal {
        require(ts >= expiry, "TEST: Invalid ts");
        setUpVault(init);

        vm.warp(ts);

        address caller = init.user[0];
        address receiver = init.user[1];
        shares = bound(shares, 0, _max_unite(caller));
        prop_unite(caller, receiver, shares);
    }
}

contract UnitePostSettlementTest is PrincipalTokenTest {
    function test_Unite() public {
        FeePcts newFeePcts = FeePctsLib.pack(7000, 0, 0, 0, BASIS_POINTS); // 0 % performance fee
        setFeePcts(newFeePcts);

        _delta_ = 2;
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("bocchi"), makeAddr("nijika")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: int256(bOne)
        });

        setUpVault(init); // Yield before settlement

        // Settle
        address caller = init.user[0];
        vm.warp(expiry);
        prop_unite(caller, caller, 0); // unite 0 shares to trigger settlement
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        setUpYield(int256(bOne)); // Yield after settlement

        // Execution
        address receiver = init.user[1];
        vm.recordLogs();
        _test_Unite(init, shares); // Unite all shares

        // Post state
        Vm.Log memory log = getLatestLogByTopic0(keccak256("Unite(address,address,uint256,uint256)"));
        (uint256 sharesReceived,) = abi.decode(log.data, (uint256, uint256)); // Interest from the settlement to the last interaction

        // Assertions
        assertApproxEqAbs(target.balanceOf(receiver), sharesReceived + init.share[1], _delta_, "shares mismatch");
    }

    function testFuzz_Unite(Init memory init, uint256 shares, FeePcts newFeePcts) public boundInit(init) {
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);

        setUpVault(init);

        address caller = init.user[0];
        vm.warp(expiry); // Settle
        prop_unite(caller, caller, 0); // unite 0 shares to trigger settlement
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        _test_Unite(init, shares);
    }

    /// @notice Test `unite` function at the timestamp of `ts`
    function _test_Unite(Init memory init, uint256 shares) internal {
        address caller = init.user[0];
        address receiver = init.user[1];

        Snapshot memory oldS = principalToken.getSnapshot();
        uint256 oldAccrued = principalToken.getUserYield(caller).accrued;

        shares = bound(shares, 0, _max_unite(caller));
        prop_unite(caller, receiver, shares);

        Snapshot memory newS = principalToken.getSnapshot();
        uint256 newAccrued = principalToken.getUserYield(caller).accrued;

        assertEq(newS.globalIndex.unwrap(), oldS.globalIndex.unwrap(), "Post settlement globalIndex should not change");
        // TEST-ASSUMPTION: the caller has already accrued interest produced before making `unite` call.
        assertEq(newAccrued, oldAccrued, Property.T01_INTEREST_ACCURAL);
    }
}

contract PreviewUniteTest is PrincipalTokenTest {
    /// @notice Test `previewUnite` function
    function testFuzz_Preview(Init memory init, uint256 shares, uint64 timeJump, FeePcts newFeePcts)
        public
        boundInit(init)
    {
        setUpVault(init);
        address caller = init.user[0];
        address receiver = init.user[1];
        address other = init.user[2];
        shares = bound(shares, 0, _max_unite(caller));
        _approve(target, caller, address(principalToken), type(uint256).max);

        skip(timeJump);
        newFeePcts = boundFeePcts(newFeePcts);
        setFeePcts(newFeePcts);
        prop_previewUnite(caller, receiver, other, shares);
    }
}

contract Dummy is IUniteHook {
    function onUnite(uint256 shares, uint256 principal, bytes calldata data) external override {}
}

contract UniteWithCallbackPreExpiryTest is UnitePreExpiryTest {
    function prop_unite(address caller, address receiver, uint256 shares) public override {
        assumeNotPrecompile(caller);
        vm.etch(caller, type(Dummy).runtimeCode);

        super.prop_unite(caller, receiver, shares);
    }

    function _pt_unite(uint256 shares, address receiver) internal override returns (uint256) {
        (bool success, bytes memory retdata) =
            address(principalToken).call(abi.encodeWithSignature("unite(uint256,address,bytes)", shares, receiver, ""));
        if (success) return abi.decode(retdata, (uint256));
        vm.assume(false);
        return 0; // Silence warning
    }

    error InsufficientBalance(); // from solady SafeTransferLib

    function test_RevertWhen_InsufficientPtBalance() public {
        deal(address(target), address(principalToken), type(uint64).max); // donate

        vm.etch(alice, type(Dummy).runtimeCode);

        uint256 shares = 1e18;
        deal(address(principalToken), alice, shares - 1); // Insufficient PT
        deal(address(yt), alice, shares);

        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        principalToken.unite(shares, alice, abi.encode("junk"));
    }

    function test_RevertWhen_InsufficientYtBalance() public {
        deal(address(target), address(principalToken), type(uint64).max); // donate

        vm.etch(alice, type(Dummy).runtimeCode);

        uint256 shares = 1e18;
        deal(address(principalToken), alice, shares);
        deal(address(yt), alice, shares - 1); // Insufficient YT

        vm.prank(alice);
        vm.expectRevert(InsufficientBalance.selector);
        principalToken.unite(shares, alice, abi.encode("junk"));
    }
}

abstract contract UniteAccrualTest is CombineAccrualTest {
    function execute_accrue(Context memory context) internal virtual override {
        uint256 shares = bound(context.seed, 0, _max_unite(context.src));
        prop_unite({caller: context.users[0], receiver: context.users[1], shares: shares});
    }

    function assert_accrue(Context memory context) internal view override {
        super.assert_accrue(context);
    }
}

contract UnitePreSettlementAccrualTest is UniteAccrualTest {
    function setUp() public override {
        super.setUp();

        // For the sake of simplicity, issuance fee is zero.
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 100, 0, BASIS_POINTS); // 30% split fee, 1% perf fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function test_Accrue_1() public {
        // 0 % performance fee for the sake of simplicity
        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, BASIS_POINTS); // 30% split fee
        setFeePcts(newFeePcts);

        Init memory init = Init({
            user: [alice, bob, makeAddr("L"), makeAddr("kira")],
            share: [uint256(0), 0, 0, 0],
            principal: [uint256(10e6), 10e6, 0, 0],
            yield: 60e6
        });
        Context memory context;
        context.yield = init.yield;
        context.users = init.user;
        context.src = init.user[0]; // caller

        // 1th update
        init.yield = 0;
        setUpVault(init);

        // 2nd update
        uint256 prev = resolver.scale();
        prop_accrue(context, execute_accrue, assert_accrue);
        assertApproxEqAbs(resolver.scale(), 4 * prev, 1, "4x previous scale");
        assertApproxEqAbs(context.poststate.accrued, tOne * 75 / 10, 1, "Alice accrued 7.5 shares equivalent interest");
    }

    /// @dev Conditions:
    /// - Single user accrues yield
    function testFuzz_Accrue_0(Init memory init) public {
        _testFuzz_Accrue_0({init: init, settle: false});
    }

    /// @dev Conditions:
    /// - Single user accrues yield multiple times with different accrued yield
    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) public {
        _testFuzz_Accrue_1({init: init, yields: yields, settle: false});
    }
}

contract CombinePostSettlementAccuralTest is CombineAccrualTest {
    function setUp() public override {
        super.setUp();

        FeePcts newFeePcts = FeePctsLib.pack(3000, 0, 0, 0, 3113); // 30% split fee
        setFeePcts(newFeePcts);

        _delta_ = 3;
    }

    function test_Accrue_1() public {
        uint256 shares = 10 * tOne;

        Init memory init = Init({
            user: [alice, bob, makeAddr("goku"), makeAddr("vegeta")],
            share: [shares, 1000, 38934923, 31287],
            principal: [uint256(10 * bOne), 0, 0, 0],
            yield: 0
        });

        setUpVault(init);

        // Settle
        vm.warp(expiry);
        prop_unite(init.user[2], init.user[2], 0); // combine 0 principal to trigger settlement
        assertTrue(principalToken.isSettled(), "Settlement should be done");

        Context memory context;
        context.yield = int256(2 * bOne);
        context.users = init.user;
        context.src = init.user[0]; // caller

        // 1th update after settlement
        vm.recordLogs();
        context.yield = int256(10 * bOne);
        prop_accrue(context, execute_accrue, assert_accrue);

        Vm.Log memory log = getLatestLogByTopic0(keccak256("YieldFeeAccrued(uint256)"));
        uint256 fee = abi.decode(log.data, (uint256));
        uint256 profit =
            target.convertToShares(uint256(context.yield)) * context.prestate.totalShares / context.prestate.shareSupply;
        uint256 expectFee = profit * getPostSettlementFeePctBps(feeModule.getFeePcts()) / BASIS_POINTS;
        assertApproxEqAbs(fee, expectFee, 10, "Fee should be approx equal to profit");
        assertApproxEqAbs(context.poststate.accrued, profit - fee, 10, "Interest should be accrued");

        // 2nd update after settlement
        context.yield = int256(12 * bOne);
        prop_accrue(context, execute_accrue, assert_accrue);

        // 3rd update: Redeem all principal and YT
        prop_unite(init.user[0], init.user[0], _max_unite(init.user[0]));

        // Assertions: Solvency check
        assertEq(principalToken.balanceOf(init.user[0]), 0, "PT should be zero");
        assertEq(yt.balanceOf(init.user[0]), 0, "YT should be zero");
        uint256 totalShares = target.balanceOf(address(principalToken));
        (uint256 curatorFee, uint256 protocolFee) = principalToken.getFees();
        assertApproxEqAbs(totalShares, curatorFee + protocolFee + context.poststate.accrued, _delta_, "Solvency check");
    }

    /// @dev Conditions:
    /// - Single user accrues yield
    function testFuzz_Accrue_0(Init memory init) public {
        _testFuzz_Accrue_0({init: init, settle: true});
    }

    /// @dev Conditions:
    /// - Single user accrues yield multiple times with different accrued yield
    function testFuzz_Accrue_1(Init memory init, int40[3] memory yields) public {
        _testFuzz_Accrue_1({init: init, yields: yields, settle: true});
    }
}
