// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";
import {TwoCryptoZapAMMTest} from "./Zap.t.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ERC4626} from "solady/src/tokens/ERC4626.sol";

import {TwoCryptoZap} from "src/zap/TwoCryptoZap.sol";
import {AggregationRouter, RouterPayload} from "src/modules/aggregator/AggregationRouter.sol";
import {DefaultConnectorFactory} from "src/modules/connectors/DefaultConnectorFactory.sol";
import {VaultConnectorRegistry} from "src/modules/connectors/VaultConnectorRegistry.sol";

import {Token} from "src/Types.sol";
import "src/types/Token.sol" as TokenType;

using {TokenType.intoToken} for address;

abstract contract ZapForkTest is TwoCryptoZapAMMTest {
    Token constant WETH = Token.wrap(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    Token constant PUFFER = Token.wrap(0xD9A442856C234a39a81a089C06451EBAa4306a72);
    Token constant USDC = Token.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address payable constant ROUTER_ADDRESS = payable(address(0x1234567890123456789012345678901234567890));
    address payable constant ZAP_ADDRESS = payable(address(0x000c632910D6bE3ef6601420bb35DAB2A6F2EDe7)); // Random address

    function _deployTokens() internal virtual override {
        target = ERC4626(PUFFER.unwrap());
        base = ERC20(WETH.unwrap());
    }

    function _deployPeriphery() internal override {
        defaultConnectorFactory = new DefaultConnectorFactory(WETH.unwrap());
        connectorRegistry = new VaultConnectorRegistry(accessManager, address(defaultConnectorFactory));
        address[] memory initialRouters = new address[](2);
        initialRouters[0] = ONE_INCH_ROUTER;
        initialRouters[1] = OPEN_OCEAN_ROUTER;
        deployCodeTo(
            "src/modules/aggregator/AggregationRouter.sol",
            abi.encode(address(accessManager), initialRouters),
            ROUTER_ADDRESS
        );
        aggregationRouter = AggregationRouter(ROUTER_ADDRESS);
        deployCodeTo(
            "src/zap/TwoCryptoZap.sol",
            abi.encode(factory, connectorRegistry, address(twocryptoDeployer), aggregationRouter),
            ZAP_ADDRESS
        );
        zap = TwoCryptoZap(ZAP_ADDRESS);
        _deployQuoter();
    }

    function _label() internal virtual override {
        super._label();
        vm.label(USDC.unwrap(), "USDC");
        vm.label(WETH.unwrap(), "WETH");
        vm.label(PUFFER.unwrap(), "pufETH");
        vm.label(ROUTER_ADDRESS, "aggregationRouter");
        vm.label(ZAP_ADDRESS, "zap");
    }
}
