# Uniswap v4 release snapshot

## Provenance and scope

- Source: `napierfi/napier-v2`, `release/uniswap-v4` at `4475064276a0fc782e4a18a6fe0be3e01381bd63`.
- Public base: `napierfi/napier-v2-public`, `main` at `9a3cb443574d8979a1a2bb46e92b6bf5936489c5`.
- Contract and test trees are exact committed snapshots, including obsolete-path deletions and executable modes. No private Git history is imported.

| Path | Files | Verified Git tree SHA |
| --- | ---: | --- |
| `src/` | 138 | `e12b96014c892fd082344bed96b21c01b8e4d637` |
| `test/` | 225 | `87dadc128fb853cf840bd996ee0b9c2786b70c88` |

The build configuration, dependency manifest, and pnpm lockfile match the source revision. Public CI uses Foundry v1.3.6 and a frozen dependency installation. The environment example uses the RPC/explorer variable names required by that build configuration.

The snapshot includes TokiHook/TokiHookLogic, TokiPoolToken and its deployer, UniswapV4Router, pool-specific lenses/quoters/oracles, rehypothecation utilities, wrapper/resolver additions, and the corresponding tests. TwoCrypto contracts remain available at their release paths. No compatibility contracts or release-local Solidity edits are added.

Operational `script/`, private environment files, internal agent/editor configuration, research/planning documents, and deployment records are not imported. Public `audits/` and existing `deployments/` records are preserved. The root `LICENSE` contains the canonical BUSL-1.1 text, matching the source's license declaration. Historical audits and addresses are not presented as verification of this release. The public integration guide documents the current contract/artifact boundaries.

## Local verification

Toolchain: Foundry `1.3.6-dev`, commit `d2415887096b10226d13af9240b5bef5e6b0d815`; pnpm `10.33.0`. CI pins the tagged Foundry v1.3.6 release.

Verified:

- `pnpm install --frozen-lockfile`: succeeded.
- `forge fmt --check`: succeeded.
- `forge build --dynamic-test-linking --skip test --threads 2`: succeeded with Solc 0.8.24 and 0.8.26.
- Staged `src` and `test` tree hashes: match the table above.
- Uniswap v4 unit/fuzz selection: **59 suites, 406 passed, 0 failed, 47 skipped**. Skips are already present in the source tests.
- Credential-free CI unit/fuzz/bounded-invariant selection from README: **228 suites, 1338 passed, 0 failed, 80 skipped**.
- Codespell 2.4.3 with the workflow's filename/skip/ignore options: succeeded.
- Morpho MEVUSDC Uniswap v4 fork integration: **7 passed, 0 failed, 0 skipped**, including pool creation/liquidity, PT/YT buy/sell, lifecycle, and pre-maturity withdrawal.

```sh
forge test --dynamic-test-linking \
  --match-path 'test/{hooks,oracles,zap/uniswap,lens/uniswap,factory/uniswap-v4}/**' \
  --skip integrations twocrypto wrapper invariant \
  --no-match-test testFork --threads 2 --summary
```

An isolated, throwaway `forge script` scenario also deployed the real TokiHook with a mined CREATE2 hook address and its library, deployed a market/router using the release fixtures, funded mock base assets, deposited vault shares, issued PT/YT, added liquidity, and executed an underlying-to-YT swap through Permit2 and UniswapV4Router. It checked the recipient's YT output floor, payer maximum input, and absence of router token/ETH residue. Observed base-unit results:

| Observable | Value |
| --- | ---: |
| LP minted | `63245570547` |
| Underlying shares spent | `323455559` |
| YT received | `6917265175` |

The scenario ran in Foundry's local EVM; no live transactions were broadcast. Fixtures supplied mocked assets and the precompiled PoolManager/Permit2 deployments. The oversized scenario runner had the code-size limit disabled; this is not proof of a production deployment ceremony. The throwaway script and snapshot-helper scaffolding are not part of the deliverable.

## Test selection and external dependencies

The credential-free command in [README](../../README.md) and public CI includes local unit/fuzz tests and bounded invariants. It excludes RPC-backed contracts whose constructors or setup create forks, in addition to `testFork` functions. Compilation skips reduce the build scope but do not reliably exclude cached test artifacts from execution; explicit contract exclusions enforce the offline boundary. No imported test contracts are changed.

Excluded fork suites remain available for explicit runs with valid RPC access. The Morpho MEVUSDC fork suite was exercised with locally supplied RPC credentials; the remaining fork integrations, live aggregator API, and symbolic suites were not run. `AggregationRouterTest` additionally requires opt-in FFI, `bash`, `curl`, `jq`, and live external API access. Local script evidence does not establish a live deployment.

## Publication review and merge requirements

Two independent read-only reviews covered publication exposure and migration consistency. No evidence-backed production credential leak was identified in the selected files; patterned fixture keys and embedded deployment bytecode were classified as test data, not production secrets. The reviews were scoped migration checks, not a complete smart-contract audit or exhaustive secret scan. Upstream attribution, including the exact Pendle oracle reference in `LibOracle`, is preserved.

Napier-authored code follows the source's BUSL-1.1 declarations. The root `LICENSE` contains the unmodified canonical [Business Source License 1.1 text](https://spdx.org/licenses/BUSL-1.1.html). Imported Solidity headers and package metadata remain exact source snapshots; other imported files retain their file-specific MIT/GPL/UNLICENSED declarations.

The pinned source contains no project-specific BUSL license document or values for Licensor, Additional Use Grant, Change Date, or Change License. Its README states a BUSL effective date of March 17, 2026; that date is not a declared Change Date. The canonical license covenants require an Additional Use Grant (or explicit `None`), Change Date, and compatible Change License. These terms must be supplied by the licensor; none is inferred from a prior public license or from the source README's effective date. The public pull request remains draft until the project-specific parameters are supplied.
