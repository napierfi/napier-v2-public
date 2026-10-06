// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {TwoCryptoZapAMMTest} from "../../shared/twocrypto/Zap.t.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";
import {UUPSUpgradeable} from "solady/src/utils/UUPSUpgradeable.sol";

import {Lens} from "src/lens/twocrypo/Lens.sol";

import {AssetPriceProvider} from "src/lens/AssetPriceProvider.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {VerifierModule} from "src/modules/VerifierModule.sol";
import {VaultInfoResolver} from "src/modules/resolvers/VaultInfoResolver.sol";
import {Factory} from "src/Factory.sol";
import {LibTwoCryptoNG} from "src/utils/LibTwoCryptoNG.sol";
import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

using {TokenType.intoToken} for address;

contract Dummy {}

abstract contract LensTest is TwoCryptoZapAMMTest {
    Lens lens;
    AssetPriceProvider priceProvider;

    function setUp() public virtual override {
        super.setUp();

        priceProvider = new AssetPriceProvider();

        Lens implementation = new Lens();
        lens = Lens(LibClone.deployERC1967(address(implementation)));
        lens.initialize(factory, address(twocryptoDeployer), admin, address(priceProvider));

        _label();
        vm.label(address(lens), "Lens");

        Init memory init = Init({
            user: [alice, bob, makeAddr("shikanoko"), makeAddr("koshitan")],
            share: [uint256(1e18), 768143, 38934923, 31287],
            principal: [uint256(131311313), 0, 313130, 0],
            yield: 30009218913
        });
        setUpVault(init);
    }
}

contract LensSetterTest is LensTest {
    function test_SetPriceProvider() public {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = Lens.setPriceProvider.selector;
        _grantRoles(napierAccessManager, admin, admin, address(lens), selectors, Constants.DEV_ROLE);
        vm.prank(admin);
        lens.setPriceProvider(makeAddr("priceProvider"));
        assertEq(address(lens.s_priceProvider()), makeAddr("priceProvider"), "Price provider address mismatch");
    }

    function test_SetPriceProvider_RevertWhen_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        lens.setPriceProvider(makeAddr("priceProvider"));
    }

    function test_Upgrade_RevertWhen_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        lens.upgradeToAndCall(makeAddr("newImpl"), "");
    }
}

contract LensPriceDataTest is LensTest {
    /// @dev It should NOT revert even if expired
    function test_NotRevert_WhenExpired() public {
        vm.warp(expiry + 1);
        lens.getPriceData(twocrypto);
    }

    function test_WhenNotExpired() public {
        // Example
        // - PT expires in 3 months=1/4 years
        // - PT price in share is 0.972
        // - 1 Underlying token is 1 asset
        uint256 scale = 1e18;
        uint256 ptPriceInShare = 0.972e18;
        vm.warp(expiry - (365 days / 4));
        vm.mockCall(address(resolver), abi.encodeWithSelector(resolver.scale.selector), abi.encode(scale));
        vm.mockCall(twocrypto.unwrap(), abi.encodeWithSignature("last_prices()"), abi.encode(ptPriceInShare));

        Lens.PriceData memory data = lens.getPriceData(twocrypto);
        assertApproxEqRel(data.impliedAPY, 0.1203e18, 0.0001e18, "implied rate should be 12.03%");
    }

    function test_WhenExpired() public {
        vm.warp(expiry);

        Lens.PriceData memory data = lens.getPriceData(twocrypto);
        assertEq(data.impliedAPY, 0);
    }
}

contract LensPriceDataForkTest is Test {
    using LibTwoCryptoNG for TwoCrypto;

    address implementation;
    Lens lens;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22_087_000);

        implementation = address(new Lens());
        lens = Lens(0x0000006178Ee874E0AE58B131B8A5FcBe78cab2F);
        vm.prank(lens.owner());
        lens.upgradeToAndCall(implementation, "");
    }

    function test_Price_Decimals_18_6() public view {
        TwoCrypto usualUSDCTwoCrypto = TwoCrypto.wrap(0xaeA5e50b41EdD6E86eBc631caB64ac32Bc9D87D7);
        Lens.PriceData memory data = lens.getPriceData(usualUSDCTwoCrypto);

        VaultInfoResolver resolver = PrincipalToken(usualUSDCTwoCrypto.coins(Constants.PT_INDEX)).i_resolver();
        uint256 assetPriceInShare =
            1e18 * (10 ** (18 + resolver.assetDecimals() - resolver.decimals())) / resolver.scale();

        assertApproxEqAbs(data.assetPriceInUSD, 1e18, 0.5e18, "assetPriceInUSD should be approx 1e18");
        assertLe(data.ptPriceInShare, 1e18, "ptPriceInShare should be less than 1 underlying token");
        assertGe(data.ptPriceInShare, 0.1e18, "ptPriceInShare should be greater than 0.1 underlying token");
        assertApproxEqAbs(data.ytPriceInShare + data.ptPriceInShare, assetPriceInShare, 0.0001e18);
        assertLe(data.ptPriceInUSD, 1.2e18, "ptPriceInUSD should be less than 1.2 USD");
        assertGe(data.ptPriceInUSD, 0.7e18, "ptPriceInUSD should be greater than 0.7 USD");
        assertLe(data.ytPriceInUSD, 0.5e18, "ytPriceInUSD should be less than 0.5 USD");
        assertGe(data.ytPriceInUSD, 0.001e18, "ytPriceInUSD should be greater than 0.001 USD");
        assertApproxEqAbs(data.lpPriceInUSD, 1.8e18, 0.5e18, "lpPriceInUSD should be approx 1.3 ~ 2.3 USD");
        assertApproxEqAbs(data.impliedAPY, 0.1e18, 0.05e18, "impliedAPY should be approx 0.10e18");
    }

    function test_Price_Decimals_6_6() public view {
        TwoCrypto superUSDCTwoCrypto = TwoCrypto.wrap(0x7Cb27098C046d70c6783D07759813E5591E7789a);
        Lens.PriceData memory data = lens.getPriceData(superUSDCTwoCrypto);

        VaultInfoResolver resolver = PrincipalToken(superUSDCTwoCrypto.coins(Constants.PT_INDEX)).i_resolver();
        uint256 assetPriceInShare =
            1e18 * (10 ** (18 + resolver.assetDecimals() - resolver.decimals())) / resolver.scale();

        assertApproxEqAbs(data.assetPriceInUSD, 1e18, 0.5e18, "assetPriceInUSD should be approx 1e18");
        assertLe(data.ptPriceInShare, 1e18, "ptPriceInShare should be less than 1 underlying token");
        assertGe(data.ptPriceInShare, 0.1e18, "ptPriceInShare should be greater than 0.1 underlying token");
        assertApproxEqAbs(data.ytPriceInShare + data.ptPriceInShare, assetPriceInShare, 0.0001e18);
        assertLe(data.ptPriceInUSD, 1.2e18, "ptPriceInUSD should be less than 1.2 USD");
        assertGe(data.ptPriceInUSD, 0.7e18, "ptPriceInUSD should be greater than 0.7 USD");
        assertLe(data.ytPriceInUSD, 0.5e18, "ytPriceInUSD should be less than 0.5 USD");
        assertGe(data.ytPriceInUSD, 0.001e18, "ytPriceInUSD should be greater than 0.001 USD");
        assertApproxEqAbs(data.lpPriceInUSD, 1.8e18, 0.5e18, "lpPriceInUSD should be approx 1.3 ~ 2.3 USD");
        assertApproxEqAbs(data.impliedAPY, 0.08e18, 0.05e18, "impliedAPY should be approx 0.08e18");
    }

    function test_Price_Decimals_18_18() public view {
        TwoCrypto scrvUSDTwoCrypto = TwoCrypto.wrap(0xb310AAa0242b660c509981f36f7C0FC3e387EBC7);
        Lens.PriceData memory data = lens.getPriceData(scrvUSDTwoCrypto);

        VaultInfoResolver resolver = PrincipalToken(scrvUSDTwoCrypto.coins(Constants.PT_INDEX)).i_resolver();
        uint256 assetPriceInShare =
            1e18 * (10 ** (18 + resolver.assetDecimals() - resolver.decimals())) / resolver.scale();

        assertApproxEqAbs(data.assetPriceInUSD, 1e18, 0.5e18, "assetPriceInUSD should be approx 1e18");
        assertLe(data.ptPriceInShare, 1e18, "ptPriceInShare should be less than 1 underlying token");
        assertGe(data.ptPriceInShare, 0.1e18, "ptPriceInShare should be greater than 0.1 underlying token");
        assertApproxEqAbs(data.ytPriceInShare + data.ptPriceInShare, assetPriceInShare, 0.0001e18);
        assertLe(data.ptPriceInUSD, 1.2e18, "ptPriceInUSD should be less than 1.2 USD");
        assertGe(data.ptPriceInUSD, 0.7e18, "ptPriceInUSD should be greater than 0.7 USD");
        assertLe(data.ytPriceInUSD, 0.5e18, "ytPriceInUSD should be less than 0.5 USD");
        assertGe(data.ytPriceInUSD, 0.001e18, "ytPriceInUSD should be greater than 0.001 USD");
        assertApproxEqAbs(data.lpPriceInUSD, 1.8e18, 0.5e18, "lpPriceInUSD should be approx 1.3 ~ 2.3 USD");
        assertApproxEqAbs(data.impliedAPY, 0.18e18, 0.05e18, "impliedAPY should be approx 0.08e18");
    }
}

contract LensTwoCryptoDataForkTest is Test {
    address implementation;
    Lens lens;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22_087_000);

        implementation = address(new Lens());
        lens = Lens(0x0000006178Ee874E0AE58B131B8A5FcBe78cab2F);
        vm.prank(lens.owner());
        lens.upgradeToAndCall(implementation, "");
    }

    function test_TwoCryptoData_Decimals_18_6() public view {
        TwoCrypto usualUSDCTwoCrypto = TwoCrypto.wrap(0xaeA5e50b41EdD6E86eBc631caB64ac32Bc9D87D7);
        Lens.TwoCryptoData memory data = lens.getTwoCryptoData(usualUSDCTwoCrypto);

        assertLe(data.ptPriceInShare, 1e18, "ptPriceInShare should be less than 1 underlying token");
        assertGe(data.ptPriceInShare, 0.1e18, "ptPriceInShare should be greater than 0.1 underlying token");

        uint256 poolValueInShare = data.totalSupply * data.lpPriceInShare / 1e18;
        uint256 poolValueInAsset = poolValueInShare * 1e6 / 1e18; // 6 decimals
        assertApproxEqRel(data.poolValueInShare, poolValueInShare, 0.5e18, "poolValueInShare should be approx eq");
        assertApproxEqRel(data.poolValueInAsset, poolValueInAsset, 0.5e18, "poolValueInAsset should be approx eq");
        assertApproxEqRel(
            data.poolValueInUSD, poolValueInAsset * 1e18 / 1e6, 0.5e18, "poolValueInUSD should be in 1e18 decimals"
        );
    }

    function test_TwoCryptoData_Decimals_6_6() public view {
        TwoCrypto superUSDCTwoCrypto = TwoCrypto.wrap(0x7Cb27098C046d70c6783D07759813E5591E7789a);
        Lens.TwoCryptoData memory data = lens.getTwoCryptoData(superUSDCTwoCrypto);

        assertLe(data.ptPriceInShare, 1e18, "ptPriceInShare should be less than 1 underlying token");
        assertGe(data.ptPriceInShare, 0.1e18, "ptPriceInShare should be greater than 0.1 underlying token");

        uint256 poolValueInShare = data.totalSupply * data.lpPriceInShare / 1e18;
        uint256 poolValueInAsset = poolValueInShare; // Approximation
        assertApproxEqRel(data.poolValueInShare, poolValueInShare, 0.5e18, "poolValueInShare should be approx eq");
        assertApproxEqRel(data.poolValueInAsset, poolValueInAsset, 0.5e18, "poolValueInAsset should be approx eq");
        assertApproxEqRel(
            data.poolValueInUSD, poolValueInAsset * 1e18 / 1e6, 0.5e18, "poolValueInUSD should be in 1e18 decimals"
        );
    }
}

contract LensPrincipalTokenDataForkTest is Test {
    address implementation;
    Lens lens;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 22_087_000);

        implementation = address(new Lens());
        lens = Lens(0x0000006178Ee874E0AE58B131B8A5FcBe78cab2F);
        vm.prank(lens.owner());
        lens.upgradeToAndCall(implementation, "");
    }

    function test_PrincipalTokenData_Decimals_18_6() public {
        // PT-UsualUSDC
        PrincipalToken principalToken = PrincipalToken(0x5873596f9781f9F75Ef262836Fb2086C8472961C);

        vm.mockCall(
            principalToken.i_factory().moduleFor(address(principalToken), VERIFIER_MODULE_INDEX),
            abi.encodeWithSelector(VerifierModule.depositCap.selector),
            abi.encode(1_000e18)
        );
        Lens.TrancheData memory data = lens.getTrancheData(principalToken);

        assertLe(data.ptTVLInUSD, 100e18, "TVL should be less than 100 USD");
        assertGe(data.ptTVLInUSD, 1e18, "TVL should be greater than 1 USD");

        assertEq(data.depositCapInShare, 1_000e18, "deposit cap in underlying token should be 1000 UsualUSD");
        assertApproxEqRel(data.depositCapInAsset, 1_000e6, 0.1e18, "deposit cap in asset should be approx 1000 USDC");
        assertApproxEqRel(data.depositCapInUSD, 1_000e18, 0.1e18, "deposit cap in USD should be 1000 USD");
    }

    function test_PrincipalTokenData_Decimals_6_6() public {
        PrincipalToken principalToken = PrincipalToken(0xDDfB1bCFE41d8bd90fa57Ee2cFC8EC7C94981cEd);

        vm.mockCall(
            principalToken.i_factory().moduleFor(address(principalToken), VERIFIER_MODULE_INDEX),
            abi.encodeWithSelector(VerifierModule.depositCap.selector),
            abi.encode(1_000e6)
        );
        vm.mockCall(
            principalToken.underlying(),
            abi.encodeWithSignature("balanceOf(address)", address(principalToken)),
            abi.encode(2e6)
        );
        Lens.TrancheData memory data = lens.getTrancheData(principalToken);

        assertLe(data.ptTVLInUSD, 3e18, "TVL should be less than 3 USD");
        assertGe(data.ptTVLInUSD, 1e18, "TVL should be greater than 1 USD");

        assertEq(data.depositCapInShare, 1_000e6, "deposit cap in underlying token should be 1000 UsualUSD");
        assertApproxEqRel(data.depositCapInAsset, 1_000e6, 0.1e18, "deposit cap in asset should be approx 1000 USDC");
        assertApproxEqRel(data.depositCapInUSD, 1_000e18, 0.1e18, "deposit cap in USD should be 1000 USD");
    }
}

contract LensUpgradeForkTest is Test {
    TwoCrypto constant USUALUSDC_TWOCRYPTO = TwoCrypto.wrap(0xaeA5e50b41EdD6E86eBc631caB64ac32Bc9D87D7);

    address alice = makeAddr("alice");
    address admin = makeAddr("admin");

    address newImplementation;
    Lens lens;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 23_250_000);

        newImplementation = address(new Lens());
        lens = Lens(0x0000006178Ee874E0AE58B131B8A5FcBe78cab2F);
        admin = lens.s_factory().i_accessManager().owner();

        _grantRoles();
        _upgrade();

        // Assert
        assertEq(address(lens.s_priceProvider()), address(0));
    }

    function _upgrade() internal {
        // Check if the current implementation is the new implementation
        (bool isNewImplementation,) = address(lens).staticcall(abi.encodeWithSignature("s_priceProvider()"));

        // If the current implementation is the new implementation, it switch the access control to the factory.i_accessManager().
        address caller = isNewImplementation ? admin : lens.owner();
        vm.startPrank(caller);
        lens.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }

    function _grantRoles() internal {
        vm.startPrank(admin);
        lens.s_factory().i_accessManager().grantRoles(admin, Constants.DEV_ROLE);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = UUPSUpgradeable.upgradeToAndCall.selector;
        selectors[1] = Lens.setPriceProvider.selector;
        lens.s_factory().i_accessManager().grantTargetFunctionRoles(address(lens), selectors, Constants.DEV_ROLE);
        vm.stopPrank();
    }

    function test_SetPriceProvider() public {
        _grantRoles();

        vm.prank(admin);
        lens.setPriceProvider(address(0xcafe));

        assertEq(address(lens.s_priceProvider()), address(0xcafe));
        assertGt(lens.getPriceData(USUALUSDC_TWOCRYPTO).ptPriceInUSD, 0, "fallback should work");
    }

    function test_Upgrade() public {
        _grantRoles();
        _upgrade();
    }

    function test_Initialize_RevertWhen_Reinitialized() public {
        Factory factory = lens.s_factory();
        address twoCryptoDeployer = address(0xbaadf00d);
        address priceProvider = address(0x21212121);
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        lens.initialize(factory, twoCryptoDeployer, admin, priceProvider);
    }

    function test_Upgrade_RevertWhen_NotAuthorized() public {
        vm.prank(alice);
        vm.expectRevert(Errors.AccessManaged_Restricted.selector);
        lens.upgradeToAndCall(newImplementation, "");
    }
}
