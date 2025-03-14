// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {Base} from "../Base.t.sol";
import {TwoCryptoZapAMMTest} from "../shared/Zap.t.sol";

import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

import {Factory} from "src/zap/TwoCryptoZap.sol";
import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import {FeePctsLib, FeePcts} from "src/utils/FeePctsLib.sol";
import {Errors} from "src/Errors.sol";
import "src/Types.sol";
import "src/Constants.sol";

contract CreateAndcreateAndAddLiquidityTest is TwoCryptoZapAMMTest {
    using LibTwoCryptoNG for TwoCrypto;

    function setUp() public override {
        Base.setUp();
        _deployTwoCryptoDeployer();
        _setUpModules();
        // No need to deploy instances
        _deployPeriphery();

        _label();
    }

    function getParams(uint256 shares) public view returns (TwoCryptoZap.CreateAndAddLiquidityParams memory params) {
        FeePcts feePcts = FeePctsLib.pack(DEFAULT_SPLIT_RATIO_BPS, 310, 100, 830, 2183);

        bytes memory poolArgs = abi.encode(twocryptoParams);
        bytes memory resolverArgs = abi.encode(address(target)); // Add appropriate resolver args if needed
        Factory.ModuleParam[] memory moduleParams = new Factory.ModuleParam[](1);
        moduleParams[0] = Factory.ModuleParam({
            moduleType: FEE_MODULE_INDEX,
            implementation: constantFeeModule_logic,
            immutableData: abi.encode(feePcts)
        });
        Factory.Suite memory suite = Factory.Suite({
            accessManagerImpl: address(accessManager_logic),
            resolverBlueprint: address(resolver_blueprint),
            ptBlueprint: address(pt_blueprint),
            poolDeployerImpl: address(twocryptoDeployer),
            poolArgs: poolArgs,
            resolverArgs: resolverArgs
        });

        params = TwoCryptoZap.CreateAndAddLiquidityParams({
            suite: suite,
            modules: moduleParams,
            expiry: expiry,
            curator: curator,
            shares: shares,
            minLiquidity: 0,
            minYt: 0,
            deadline: block.timestamp
        });
    }

    function _setInstances(address twoCrypto) internal {
        twocrypto = TwoCrypto.wrap(twoCrypto);
        principalToken = PrincipalToken(twocrypto.coins(PT_INDEX));
        yt = principalToken.i_yt();
        resolver = principalToken.i_resolver();
        accessManager = principalToken.i_accessManager();
    }

    function test_Deposit() public {
        uint256 shares = 10 * 10 ** target.decimals();

        deal(address(target), alice, shares);

        _test_Deposit(alice, shares);
    }

    function testFuzz_Deposit(uint256 shares) public {
        shares = bound(shares, 0, type(uint88).max);

        address caller = alice;
        deal(address(target), alice, shares);

        _test_Deposit(caller, shares);
    }

    function _test_Deposit(address caller, uint256 shares) internal {
        shares = bound(shares, 0, SafeTransferLib.balanceOf(address(target), caller));
        _approve(target, caller, address(zap), shares);

        TwoCryptoZap.CreateAndAddLiquidityParams memory params = getParams(shares);

        vm.prank(caller);
        (bool s, bytes memory ret) = address(zap).call(abi.encodeCall(zap.createAndAddLiquidity, (params)));
        vm.assume(s);
        ( /* address pt */ , /* address yt */, address twoCrypto, uint256 liquidity, uint256 principal) =
            abi.decode(ret, (address, address, address, uint256, uint256));

        _setInstances(twoCrypto);

        assertEq(twocrypto.balanceOf(alice), liquidity, "liquidity balance");
        assertEq(yt.balanceOf(alice), principal, "yt balance");
        assertNoFundLeft();
        assertEq(accessManager.owner(), curator, "Owner is curator");
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientYtOut() public {
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = toyParams();

        deal(address(target), alice, params.shares);
        _approve(target, alice, address(zap), type(uint256).max);

        params.minYt = 100001e18;
        params.minLiquidity = 0;
        vm.expectRevert(Errors.Zap_InsufficientYieldTokenOutput.selector);
        vm.prank(alice);
        zap.createAndAddLiquidity(params);
    }

    function test_RevertWhen_SlippageTooLarge_InsufficientLiquidity() public {
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = toyParams();

        deal(address(target), alice, params.shares);
        _approve(target, alice, address(zap), type(uint256).max);

        params.minYt = 0;
        params.minLiquidity = 1e55;
        vm.expectRevert();
        vm.prank(alice);
        zap.createAndAddLiquidity(params);
    }

    function test_RevertWhen_TransactionTooOld() public {
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = toyParams();
        params.deadline = block.timestamp - 1;

        vm.expectRevert(Errors.Zap_TransactionTooOld.selector);
        zap.createAndAddLiquidity(params);
    }

    function test_RevertWhen_Zap_BadPoolDeployer() public {
        TwoCryptoZap.CreateAndAddLiquidityParams memory params = toyParams();
        params.suite.poolDeployerImpl = address(0xcafe);

        vm.expectRevert(Errors.Zap_BadPoolDeployer.selector);
        zap.createAndAddLiquidity(params);
    }

    function toyParams() internal view returns (TwoCryptoZap.CreateAndAddLiquidityParams memory) {
        return getParams({shares: tOne});
    }
}
