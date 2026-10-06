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

Contracts require a Cancun-compatible EVM. TokiHook additionally requires Uniswap v4 PoolManager and Permit2 deployments. The records in `deployments/chains/` are retained historical public records, not a verified address manifest for this contract snapshot. Operational deployment scripts are outside the public port's scope; the build and local tests do not deploy to a live network.

## Known limitations

- Interest or reward income can be frozen by extreme share-price/accounting conditions. Review the rounding and precision constraints in `YieldMathLib`, `RewardMathLib`, and `PrincipalToken` before integrating.
- TwoCrypto YT routing can revert when Curve's `get_dx`/`get_dy` previews diverge from execution during parameter ramping. A preview is not an execution guarantee.

## Audit and licensing status

The existing reports in `audits/` are preserved; their presence does not establish audit coverage for this release snapshot.

The root `LICENSE` contains GPL v3, while imported Napier Solidity headers and `package.json` declare BUSL-1.1. Some upstream-derived fixtures have other file-specific declarations, including `UNLICENSED`. These declarations have not been rewritten, and the root license has not been changed. The responsible rights holders must reconcile the publication terms before this release is merged; this repository does not establish a uniform resolved license for the imported snapshot.
