// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {LiquidityHookBase} from "test/hooks/LiquidityHookBase.t.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {LibClone} from "solady/src/utils/LibClone.sol";

import {TokiTWAPChainlinkOracle} from "src/oracles/chainlink/TokiTWAPChainlinkOracle.sol";
import {ChainlinkOracleFactory} from "src/oracles/chainlink/ChainlinkOracleFactory.sol";
import {TokiOracle} from "src/oracles/TokiOracle.sol";
import {PrincipalToken} from "src/tokens/PrincipalToken.sol";
import {LibOracle} from "src/utils/LibOracle.sol";

import "src/Constants.sol" as Constants;

/// Abstract test suite that wires up a pool + oracle infra for TWAP Chainlink oracles
abstract contract TWAPChainlinkOracleTest is LiquidityHookBase {
    TokiTWAPChainlinkOracle implementation;
    ChainlinkOracleFactory oracleFactory;
    TokiOracle tokiOracle;
    uint32 window; // default test window

    function setUp() public virtual override {
        super.setUp();
        _addInitialLiquidity(alice, alice);

        // Deploy TokiOracle (ERC1967I immutable: factory)
        address oracleImpl = address(new TokiOracle());
        tokiOracle = TokiOracle(LibClone.deployERC1967I(oracleImpl, abi.encode(factory)));
        tokiOracle.initialize(1000); // 1s block interval (test)

        // Deploy implementation + factory; grant permission on factory via Napier AccessManager
        implementation = new TokiTWAPChainlinkOracle(tokiOracle);
        oracleFactory = new ChainlinkOracleFactory(factory);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ChainlinkOracleFactory.setImplementation.selector;
        _grantRoles(napierAccessManager, admin, admin, address(oracleFactory), selectors, Constants.DEV_ROLE);
        vm.prank(admin);
        oracleFactory.setImplementation(address(implementation), true);

        // Default window and readiness
        window = uint32(5 minutes);
        uint16 need = LibOracle.getCardinalityRequired(window, tokiOracle.blockIntervalMs());
        tokiHook.increaseObservationsCardinalityNext(poolKey, need);

        // Two observations separated by window+1 so oldestObservationSatisfied = true
        _swap({user: alice, zeroForOne: false, amount: -int256(100 * bOne), timeJump: 0});
        _swap({user: alice, zeroForOne: false, amount: -int256(100 * bOne), timeJump: window + 1});
    }

    // ---------- Arg builders ----------
    function _argsPtToAsset(uint32 twapWindow) internal view returns (bytes memory) {
        return abi.encode(
            address(pool),
            Currency.unwrap(poolKey.currency1), // base = PT
            address(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()), // quote = asset
            twapWindow
        );
    }

    function _argsPtToUnderlying(uint32 twapWindow) internal view returns (bytes memory) {
        return abi.encode(
            address(pool),
            Currency.unwrap(poolKey.currency1), // base = PT
            Currency.unwrap(poolKey.currency0), // quote = underlying
            twapWindow
        );
    }

    function _argsLpToAsset(uint32 twapWindow) internal view returns (bytes memory) {
        return abi.encode(
            address(pool),
            address(pool), // base = LP token (liquidity token address)
            address(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()), // quote = asset
            twapWindow
        );
    }

    function _argsLpToUnderlying(uint32 twapWindow) internal view returns (bytes memory) {
        return abi.encode(address(pool), address(pool), Currency.unwrap(poolKey.currency0), twapWindow);
    }

    // ---------- Clone helper ----------
    function _clone(bytes memory args) internal returns (TokiTWAPChainlinkOracle) {
        return TokiTWAPChainlinkOracle(oracleFactory.clone(address(implementation), args, hex""));
    }
}

contract TWAPChainlinkOracle_Negative_Test is TWAPChainlinkOracleTest {
    function setUp() public override {
        super.setUp();
    }

    function test_Initialize_RevertWhen_TwapWindowTooShort() public {
        uint32 tooShort = 60; // 1 minute < 5 minutes
        bytes memory args = abi.encode(
            address(pool),
            Currency.unwrap(poolKey.currency1),
            address(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()),
            tooShort
        );
        vm.expectRevert(TokiTWAPChainlinkOracle.TWAPChainlinkOracle_InvalidConfiguration.selector);
        _clone(args);
    }

    function test_Initialize_RevertWhen_NotReady_Capacity() public {
        // Choose a large window that doesn’t overflow cardinality but still requires growth
        uint32 largeWindow = uint32(10 hours);
        bytes memory args = abi.encode(
            address(pool),
            Currency.unwrap(poolKey.currency1),
            address(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()),
            largeWindow
        );
        vm.expectRevert(TokiTWAPChainlinkOracle.TWAPChainlinkOracle_InvalidConfiguration.selector);
        _clone(args);
    }

    function test_Initialize_RevertWhen_NotReady_OldestData() public {
        // Increase capacity to satisfy cardinalityNext, but do not have old enough observations
        uint32 largeWindow = window + 10;
        uint16 need = LibOracle.getCardinalityRequired(largeWindow, tokiOracle.blockIntervalMs());
        tokiHook.increaseObservationsCardinalityNext(poolKey, need);

        bytes memory args = abi.encode(
            address(pool),
            Currency.unwrap(poolKey.currency1),
            address(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()),
            largeWindow
        );
        vm.expectRevert(TokiTWAPChainlinkOracle.TWAPChainlinkOracle_InvalidConfiguration.selector);
        _clone(args);
    }

    function test_Initialize_RevertWhen_BaseOrQuoteMisconfigured() public {
        // Base must be PT or LP
        bytes memory badBaseArgs = abi.encode(address(pool), randomToken, Currency.unwrap(poolKey.currency0), window);
        vm.expectRevert(TokiTWAPChainlinkOracle.TWAPChainlinkOracle_InvalidConfiguration.selector);
        _clone(badBaseArgs);

        // Quote must be underlying (currency0) or PT's asset
        bytes memory badQuoteArgs = abi.encode(address(pool), Currency.unwrap(poolKey.currency1), randomToken, window);
        vm.expectRevert(TokiTWAPChainlinkOracle.TWAPChainlinkOracle_InvalidConfiguration.selector);
        _clone(badQuoteArgs);
    }
}

contract TWAPChainlinkOracle_PtToAsset_Test is TWAPChainlinkOracleTest {
    TokiTWAPChainlinkOracle internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = _clone(_argsPtToAsset(window));
    }

    // Happy path
    function test_LatestRoundData() public view {
        uint8 qDec = ERC20(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()).decimals();
        uint256 expected = tokiOracle.convertPtToAssets(address(pool), window, bOne) * 10 ** (18 - qDec);

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, int256(expected), "PT->Asset price mismatch");
        assertEq(updatedAt, block.timestamp, "updatedAt should equal current timestamp");
        assertEq(oracle.decimals(), 18, "decimals must be 18");
    }
}

contract TWAPChainlinkOracle_PtToUnderlying_Test is TWAPChainlinkOracleTest {
    TokiTWAPChainlinkOracle internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = _clone(_argsPtToUnderlying(window));
    }

    function test_LatestRoundData() public view {
        uint8 qDec = ERC20(Currency.unwrap(poolKey.currency0)).decimals();
        uint256 expected = tokiOracle.convertPtToUnderlying(address(pool), window, bOne) * 10 ** (18 - qDec);

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, int256(expected), "PT->Underlying price mismatch");
        assertEq(updatedAt, block.timestamp, "updatedAt should equal current timestamp");
        assertEq(oracle.decimals(), 18, "decimals must be 18");
    }
}

contract TWAPChainlinkOracle_LpToAsset_Test is TWAPChainlinkOracleTest {
    TokiTWAPChainlinkOracle internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = _clone(_argsLpToAsset(window));
    }

    function test_LatestRoundData() public view {
        uint8 qDec = ERC20(PrincipalToken(Currency.unwrap(poolKey.currency1)).i_asset()).decimals();
        uint256 expected = tokiOracle.convertLpToAssets(address(pool), window, 1 ether) * 10 ** (18 - qDec);

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, int256(expected), "LP->Asset price mismatch");
        assertEq(updatedAt, block.timestamp, "updatedAt should equal current timestamp");
        assertEq(oracle.decimals(), 18, "decimals must be 18");
    }
}

contract TWAPChainlinkOracle_LpToUnderlying_Test is TWAPChainlinkOracleTest {
    TokiTWAPChainlinkOracle internal oracle;

    function setUp() public override {
        super.setUp();
        oracle = _clone(_argsLpToUnderlying(window));
    }

    function test_LatestRoundData() public view {
        uint8 qDec = ERC20(Currency.unwrap(poolKey.currency0)).decimals();
        uint256 expected = tokiOracle.convertLpToUnderlying(address(pool), window, 1 ether) * 10 ** (18 - qDec);

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, int256(expected), "LP->Underlying price mismatch");
        assertEq(updatedAt, block.timestamp, "updatedAt should equal current timestamp");
        assertEq(oracle.decimals(), 18, "decimals must be 18");
    }
}
