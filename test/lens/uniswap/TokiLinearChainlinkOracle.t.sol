// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {UniswapV4Base} from "test/UniswapV4Base.t.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {TokiLinearChainlinkOracle} from "src/oracles/chainlink/TokiLinearChainlinkOracle.sol";
import {ChainlinkOracleFactory} from "src/oracles/chainlink/ChainlinkOracleFactory.sol";
import {LinearPrice} from "src/oracles/LinearPrice.sol";
import "src/Constants.sol" as Constants;

contract LinearChainlinkOracleTest is UniswapV4Base {
    TokiLinearChainlinkOracle internal implementation;
    ChainlinkOracleFactory internal oracleFactory;
    TokiLinearChainlinkOracle internal oracle;

    uint256 internal rateBps;

    function setUp() public override {
        super.setUp();
        _deployV4PoolDeployer();
        _setUpModules();
        _deployInstance();
        _label();

        implementation = new TokiLinearChainlinkOracle(factory);
        oracleFactory = new ChainlinkOracleFactory(factory);

        // Grant permission to set implementation on oracle factory via Napier's AccessManager
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ChainlinkOracleFactory.setImplementation.selector;
        _grantRoles(napierAccessManager, admin, admin, address(oracleFactory), selectors, Constants.DEV_ROLE);

        vm.prank(admin);
        oracleFactory.setImplementation(address(implementation), true);

        rateBps = 1000; // 10% APR
        bytes memory args = abi.encode(address(pool), address(principalToken), address(base), rateBps);
        oracle = TokiLinearChainlinkOracle(oracleFactory.clone(address(implementation), args, hex""));
    }

    /// Happy path: initialize and compute discounted price
    function test_LatestRoundData_HappyPath() public view {
        uint256 discountBps = LinearPrice.getDiscountBps(expiry, rateBps);
        uint256 expected = Constants.WAD * (Constants.BASIS_POINTS - discountBps) / Constants.BASIS_POINTS;

        (, int256 answer,, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(answer, int256(expected), "discounted PT price mismatch");
        assertEq(updatedAt, block.timestamp, "updatedAt should equal current timestamp");
        assertEq(oracle.decimals(), 18, "decimals must be 18");
    }

    /// Revert when pool is not registered in factory
    function test_Initialize_RevertWhenBadPool() public {
        address fakeLp = makeAddr("fakeLp");
        bytes memory args = abi.encode(fakeLp, address(principalToken), address(base), uint256(1000));
        vm.expectRevert(TokiLinearChainlinkOracle.LinearChainlinkOracle_BadPool.selector);
        TokiLinearChainlinkOracle(oracleFactory.clone(address(implementation), args, hex""));
    }

    /// Revert when `base` is not PT (currency1)
    function test_Initialize_RevertWhenBaseNotPT() public {
        address wrongBase = Currency.unwrap(poolKey.currency0);
        bytes memory args = abi.encode(address(pool), wrongBase, address(base), uint256(1000));
        vm.expectRevert(TokiLinearChainlinkOracle.LinearChainlinkOracle_InvalidConfiguration.selector);
        TokiLinearChainlinkOracle(oracleFactory.clone(address(implementation), args, hex""));
    }

    /// Revert when `quote` is not PT's asset
    function test_Initialize_RevertWhenQuoteNotAsset() public {
        address wrongQuote = makeAddr("wrongQuote");
        bytes memory args = abi.encode(address(pool), address(principalToken), wrongQuote, uint256(1000));
        vm.expectRevert(TokiLinearChainlinkOracle.LinearChainlinkOracle_InvalidConfiguration.selector);
        TokiLinearChainlinkOracle(oracleFactory.clone(address(implementation), args, hex""));
    }

    /// Revert when discount rate per year is zero (invalid)
    function test_Initialize_RevertWhenZeroDiscountRate() public {
        bytes memory args = abi.encode(address(pool), address(principalToken), address(base), uint256(0));
        vm.expectRevert(LinearPrice.LinearPrice_InvalidDiscountRatePerYear.selector);
        TokiLinearChainlinkOracle(oracleFactory.clone(address(implementation), args, hex""));
    }

    /// After expiry, oracle should return 1.0 in WAD
    function test_LatestRoundData_ReturnsOneAfterExpiry() public {
        vm.warp(expiry);

        (, int256 answer,,,) = oracle.latestRoundData();
        assertEq(answer, int256(Constants.WAD), "price should be 1.0 after expiry");
    }
}
