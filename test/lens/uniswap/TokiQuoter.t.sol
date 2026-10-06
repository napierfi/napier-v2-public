// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.10;

import "forge-std/src/Test.sol";

import {LiquidityHookBase} from "../../hooks/LiquidityHookBase.t.sol";

import {LibClone} from "solady/src/utils/LibClone.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {TokiQuoter} from "src/lens/uniswap/TokiQuoter.sol";
import {TokiSwapBinSearch} from "src/utils/TokiSwapBinSearch.sol";
import {TokiPoolDeployer} from "src/modules/deployers/TokiPoolDeployer.sol";
import {PrincipalTokenQuoter} from "src/lens/PrincipalTokenQuoter.sol";
import {VaultConnectorRegistry} from "src/modules/connectors/VaultConnectorRegistry.sol";
import {DefaultConnectorFactory} from "src/modules/connectors/DefaultConnectorFactory.sol";

import "src/Types.sol";
import "src/Errors.sol";
import "src/Constants.sol" as Constants;

contract TokiQuoterTest is LiquidityHookBase {
    TokiQuoter quoter;

    function setUp() public virtual override {
        _setUp({enableRehypothecation0: true});
        _setupVault0();

        DefaultConnectorFactory defaultConnectorFactory = new DefaultConnectorFactory(Constants.WETH_ETHEREUM_MAINNET);
        VaultConnectorRegistry vaultConnectorRegistry =
            new VaultConnectorRegistry(napierAccessManager, address(defaultConnectorFactory));

        TokiSwapBinSearch tokiSwapBinSearch = new TokiSwapBinSearch(factory);

        // Deploy PrincipalTokenQuoter (factory, wrappedNativeToken, vaultConnectorRegistry)
        address ptQuoterImplementation = address(new PrincipalTokenQuoter());
        // Note: Using `target` as the wrapped native token placeholder in tests
        address ptQuoter = LibClone.deployERC1967I(
            ptQuoterImplementation, abi.encode(factory, address(target), vaultConnectorRegistry)
        );

        // Deploy TokiQuoter with new immutable args: (tokiSwapBinSearch, tokiPoolDeployer, principalTokenQuoter)
        address tokiQuoterImplementation = address(new TokiQuoter());
        bytes memory args = abi.encode(tokiSwapBinSearch, TokiPoolDeployer(tokiPoolDeployer), ptQuoter);
        quoter = TokiQuoter(LibClone.deployERC1967I(tokiQuoterImplementation, args));

        rehypothecationConfig0 = RehypothecationConfig({
            targetRawTokenRatio: 6_000, // 60%
            maxRawTokenRatio: 8_000, // 80%
            minRawTokenRatio: 3_000 // 30%
        });

        rehypothecationConfig1 = RehypothecationConfig({
            targetRawTokenRatio: 10,
            maxRawTokenRatio: 6_000, // 60%
            minRawTokenRatio: 10
        });

        deal(Currency.unwrap(poolKey.currency0), chika, MAX_BALANCE);
        deal(Currency.unwrap(poolKey.currency1), chika, MAX_BALANCE);
    }
}
