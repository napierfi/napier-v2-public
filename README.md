# Napier V2

Napier V2 is a yield-stripping protocol with Principal Tokens (PT), Yield Tokens (YT), and pluggable liquidity pools. The contract snapshot includes the Uniswap v4 TokiHook AMM and Curve TwoCrypto integration.

## Documentation

- [Integration guide](./docs/Integration.md): contract boundaries, routing, quoting, and artifact paths.
- [Release snapshot](./docs/releases/uniswap-v4-port.md): source revision, scope, verification, and licensing review requirements.

## Toolchain

Use Foundry **v1.3.6**, Node.js 22, and pnpm 9 or 10. The build targets Cancun, including transient storage, and does not use `via_ir`.

```sh
pnpm install --frozen-lockfile
forge build --dynamic-test-linking --skip test --threads 2
forge fmt --check
```

## Tests

The public CI selection runs local unit, fuzz, and bounded invariant tests without RPC credentials or FFI:

```sh
FOUNDRY_PROFILE=ci forge test --dynamic-test-linking \
  --skip test/integrations test/wrapper/ConvexWrapper.t.sol test/wrapper/SNukeWrapper.t.sol script \
  --no-match-test=testFork \
  --no-match-contract='(Fork|ConvexWrapperTest|^(PYUSDTest|PXETH_STETH_Test|REUSD_SCRVUSD_Test|RSUP_WETH_Test|AggregationRouterTest|RobinhoodStockTokenResolverTest|SNukeWrapperTest|apyUSDWrapperTest|aWETHWrapperTest|AddLiquidityAnyOneTokenTest|ZapCombineToAnyTokenTest|RedeemAnyTokenTest|RemoveLiquidityAnyOneTokenTest|ZapSupplyAnyTokenTest|SwapAnyTokenForPtTest|SwapAnyTokenForYTTest|SwapPtForAnyTokenTest|SwapYtForAnyTokenTest)$)' \
  --threads=2 --show-progress --suppress-successful-traces
```

RPC-backed integrations, fork fixtures, and live aggregator tests remain in `test/` but are excluded from this credential-free command. Filtering only `testFork` names is insufficient: some fixtures fork in constructors or `setUp`. Set the required RPC variables from `.env.example` locally before selecting a fork suite explicitly, for example:

```sh
forge test --dynamic-test-linking \
  --match-path test/integrations/morpho/MEVUSDC.t.sol --threads 2
```

`test/modules/AggregationRouter.t.sol` additionally needs `--ffi`, `bash`, `curl`, `jq`, and external API access. Do not enable FFI for untrusted code or expose credentials to public pull-request workflows.

## Networks and deployments

Contracts require a Cancun-compatible EVM. TokiHook additionally requires Uniswap v4 PoolManager and Permit2 deployments. Operational deployment scripts are outside the public port's scope; the build and local tests do not deploy to a live network.

The 17 YAML manifests in `deployments/chains/` are copied byte-for-byte from `dev/uniswap` at `3b5bc6ddbbb692221f41d4fa15c25e6b7bfc3fbf`. They include production, Ethereum/Arbitrum staging, and Napier devnet configurations, using the source's `avax/` path for Avalanche. Deployment logs are not included. Empty entries and environment-variable placeholders are preserved. These records are not an on-chain verification or a guarantee that deployed bytecode matches this contract snapshot.

To generate an environment file containing the scalar contract addresses, use `deployments/scripts/get-env.sh` with [Mike Farah's yq v4](https://github.com/mikefarah/yq). Address lists such as `pyth_oracles` remain in the YAML and are not exported as scalar environment variables.

```sh
bash deployments/scripts/get-env.sh robinhood prod /tmp/napier-robinhood.env
```

## Known limitations

- Interest or reward income can be frozen by extreme share-price/accounting conditions. Review the rounding and precision constraints in `YieldMathLib`, `RewardMathLib`, and `PrincipalToken` before integrating.
- TwoCrypto YT routing can revert when Curve's `get_dx`/`get_dy` previews diverge from execution during parameter ramping. A preview is not an execution guarantee.

## Audit and licensing status

The existing reports in `audits/` are preserved; their presence does not establish audit coverage for this release snapshot.

Napier-authored code follows the `BUSL-1.1` declarations in `release/uniswap-v4`. The root [LICENSE](./LICENSE) contains the canonical Business Source License 1.1 text. Imported Solidity headers and package metadata are preserved exactly; upstream-derived files and fixtures retain their file-specific MIT/GPL/UNLICENSED declarations.

The source revision does not publish the license parameters: Licensor, Additional Use Grant, Change Date, or Change License. These have not been inferred or invented. The canonical license requires these parameters to be specified by the licensor before a complete project-specific license can be published.
