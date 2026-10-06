# Napier V2 integration

## Assets and lifecycle

- **Underlying / shares**: the yield-bearing ERC-20 token deposited into a market.
- **Asset / assets**: the base asset used by the market's resolver to value those shares.
- **Principal / principals**: PT or YT amounts, denominated in the base asset's decimals.
- **Curator**: the authority for one market's access manager, optional modules, and pool configuration.

Before expiry, users can issue PT and YT through `PrincipalToken.supply`, and combine matched PT/YT through `unite` or `combine`. After expiry, PT redemption withdraws principal; settlement is triggered by the first post-expiry accounting interaction. Yield and rewards are accounted for by the PT/YT contracts and configured modules. Integrators must account for market permissions, verification, fees, expiry, and rounding rather than treating a preview as a guaranteed execution amount.

The core contracts are [PrincipalToken](../src/tokens/PrincipalToken.sol), [YieldToken](../src/tokens/YieldToken.sol), [Factory](../src/Factory.sol), and the [resolver implementations](../src/modules/resolvers/). The ERC-4626 resolver implementation is `ERC4626InfoResolver`; its initialization payload encodes the vault address.

## Contract and artifact map

| Capability | Contract source |
| --- | --- |
| Market deployment and module registry | `src/Factory.sol` |
| Pool-independent PT previews and token routing | `src/lens/PrincipalTokenQuoter.sol` |
| Uniswap v4 pool deployment | `src/modules/deployers/TokiPoolDeployer.sol` |
| Uniswap v4 AMM and liquidity management | `src/hooks/TokiHook.sol`, `src/hooks/TokiHookLogic.sol` |
| Uniswap v4 LP token | `src/tokens/TokiPoolToken.sol` |
| Uniswap v4 execution | `src/zap/uniswap/UniswapV4Router.sol` |
| Uniswap v4 quotes | `src/lens/uniswap/TokiQuoter.sol` |
| Uniswap v4 pool state and application reads | `src/lens/uniswap/StateView.sol`, `src/lens/uniswap/TokiLens.sol` |
| Pool pricing and oracles | `src/oracles/`, `src/oracles/chainlink/` |
| TwoCrypto execution | `src/zap/twocrypto/TwoCryptoZap.sol` |
| TwoCrypto lens, quoter, and simulation | `src/lens/twocrypo/Lens.sol`, `Quoter.sol`, `Impersonator.sol` |

The directory spelling `twocrypo` is the actual Solidity source path. Generate ABIs from this checkout rather than using artifacts from another release:

```sh
forge inspect src/zap/uniswap/UniswapV4Router.sol:UniswapV4Router abi --json
forge inspect src/lens/uniswap/TokiQuoter.sol:TokiQuoter abi --json
forge inspect src/lens/twocrypo/Lens.sol:Lens abi --json
```

## Deployment configuration

`Factory.Suite` supplies the access-manager implementation, PT blueprint, resolver blueprint, pool-deployer implementation, and ABI-encoded pool/resolver arguments. `Factory.ModuleParam[]` supplies module types, registered implementations, and their initialization data. `deploy` and `deployDeterministic` return PT, YT, and pool addresses; the expiry must be in the future. The curator receives the per-market authority. Consult the actual struct declarations and deployment implementation for the payload and registration requirements.

For TokiHook, encode [ITokiHook.TokiPoolDeploymentParams](../src/interfaces/ITokiHook.sol) in `suite.poolArgs`. The configured hook and LP implementation must be enabled in `TokiPoolDeployer`; the PT address must sort after the underlying address. A pool's `PoolKey` uses underlying as currency0, PT as currency1, and the configured TokiHook as its hook. Its returned pool address is the LP token, not a standalone Uniswap pool contract. Pool liquidity is managed through TokiHook; direct PoolManager liquidity modifications are blocked.

Curator-selected hooklets and rehypothecation vaults are trust dependencies for that market. Rehypothecation vaults must use the matching pool currency as their asset. Vault losses affect LP balances. Do not infer vault safety or market permissions from registration alone.

## Uniswap v4 routing

The router accepts:

```solidity
execute(bytes commands, bytes[] inputs)
execute(bytes commands, bytes[] inputs, uint256 deadline)
```

Each command byte has one corresponding ABI-encoded input entry. The deadline overload rejects expired transactions. Command IDs and flags are defined in [Commands](../src/zap/uniswap/Commands.sol); the exact input layouts are defined by [Dispatcher](../src/zap/uniswap/Dispatcher.sol). This router extends Uniswap's command model with PT operations, vault connectors, Toki liquidity, and YT swaps; it is not a drop-in Universal Router ABI for removed V2/V3 commands.

ERC-20 payments using Permit2 require both token allowance to Permit2 and a Permit2 allowance or signed permit authorizing this router. Set explicit recipients, refund recipients, slippage bounds, and deadlines. Do not leave change in the router; compose the required settlement/sweep commands for the chosen flow.

For `YT_SWAP_UNDERLYING_FOR_YT`, the input layout is:

```solidity
abi.encode(poolKey, amountIn, amountOutMinimum, recipient, refundReceiver, approxParams)
```

`approxParams` uses [ApproximationParams](../src/types/ApproximationParams.sol). The payer's net underlying cost can be below `amountIn` because the flow refunds unused input. Check the actual recipient YT balance delta and payer cost, not an assumed equality to the maximum input.

Use `TokiQuoter` to preview pool-specific operations and `PrincipalTokenQuoter` for pool-independent conversions. Quotes do not override execution slippage constraints. Use `StateView`, `TokiLens`, and the oracle contracts for their respective raw-state, application, and pricing surfaces.

Uniswap v4 represents native currency with the zero address. Napier's pool-independent [Token](../src/types/Token.sol) representation uses its own native-token sentinel; encode according to the specific contract boundary, not a shared assumption.

## TwoCrypto routing

TwoCrypto uses its own deployer, zap, lens, and quoter. Its pool address represents the Curve AMM/LP contract rather than a Toki LP token. Use the ABIs under `src/zap/twocrypto/` and `src/lens/twocrypo/`; Uniswap command payloads are not interchangeable with TwoCrypto entry points.

## Errors, events, and address verification

[Errors](../src/Errors.sol), [Events](../src/Events.sol), and contract-local declarations define the actual failure and indexing surfaces. Decode nested router failures with the matching release ABI.

The retained `deployments/chains/` records and `audits/` reports are historical public artifacts. They are not verified deployment addresses or proof of audit coverage for this snapshot. Before constructing transactions, verify the chain, Factory, pool deployer, hook, router, Permit2, module registrations, market assets, and expiry against the intended deployment.
