# Uniswap v4 public port (preparation only)

## Status

This draft does **not** contain the release's Solidity changes yet. It records the pinned source and provides a local, dry-run-first snapshot helper. Do not merge it as a completed release port.

The connected environment could inspect the repositories but could not complete a bulk transfer or run Foundry. No import workflow was installed. The helper never fetches, stages, commits, pushes, or deploys anything.

## Pinned inputs

- Source: `napierfi/napier-v2`, `release/uniswap-v4` at `4475064276a0fc782e4a18a6fe0be3e01381bd63`.
- Public base: `napierfi/napier-v2-public`, `main` at `9a3cb443574d8979a1a2bb46e92b6bf5936489c5`.
- Public PR branch: `chore/import-uniswap-v4-4475064`.

Expected source Git trees:

| Path | Tree SHA |
| --- | --- |
| `src` | `e12b96014c892fd082344bed96b21c01b8e4d637` |
| `test` | `87dadc128fb853cf840bd996ee0b9c2786b70c88` |
| `script` | `e71022751aa743c0a604007cb636e3871a1532d5` |

## Scope and publication review

The helper replaces the tracked `src/`, `test/`, and `script/` snapshots, including obsolete-file deletions and executable bits. It copies `.env.example`, `.gitignore`, `foundry.toml`, `package.json`, `pnpm-lock.yaml`, and `slither.config.json` from the pinned source. It reads committed blobs, never the source checkout's uncommitted files, and does not import private Git history.

It deliberately leaves the public `LICENSE`, `audits/`, `README.md`, `docs/`, `deployments/`, and `.github/` untouched. Internal agent/editor settings and non-example environment files outside the selected code trees are not selected. Public documentation, deployment configuration, and CI must be reviewed separately before this port is ready; this helper alone is not a complete release publication.

The source `package.json` declares `BUSL-1.1`, and its README states BUSL licensing. The public repository currently contains GPL v3 in `LICENSE`. A maintainer must resolve and document the intended publication terms; this draft does not choose new terms, relabel Solidity headers, or overwrite the public license. `--license-reviewed` is an explicit acknowledgement, not a license-resolution mechanism.

The helper rejects symlinks/submodules in its selected trees, destination symlinks, local-file collisions, a dirty public checkout, and selected public-code changes since the pinned base. It checks a small set of credential patterns before writing. This is only a guardrail, **not** a complete secret scan or publication approval. Review all selected operational scripts and fixtures before pushing them.

## Finish the port locally

Use existing local checkouts with access to the pinned commits. Check out the public PR branch in `napier-v2-public`; do not work on `main`.

```sh
cd /path/to/napier-v2-public
python3 tools/port_uniswap_v4.py --source /path/to/napier-v2 --target .
```

The default is a dry run. After resolving/documenting the license discrepancy and reviewing the selected content:

```sh
python3 tools/port_uniswap_v4.py --source /path/to/napier-v2 --target . --apply --license-reviewed
git diff --stat
git diff --check
```

The helper verifies copied blob hashes and file modes. It changes only the working tree; review, stage, and commit the changes on this same PR branch yourself. After staging, compare `git rev-parse "$(git write-tree):src"` (and `:test`, `:script`) to the expected trees above. Resolve the public README, documentation, deployment data, and CI as separate, explicitly reviewed changes.

With the release toolchain (Foundry v1.3.6; pnpm 9 / Node.js 22), run:

```sh
pnpm install --frozen-lockfile
forge fmt --check
forge build --dynamic-test-linking --skip=test
forge test --dynamic-test-linking --no-match-test='(invariant_|testFork)'
```

Run the relevant invariant, fork, and integration tests separately with locally configured RPC access. Do not paste credentials into the PR, source files, or workflow definitions.

## Validation recorded for this draft

Seven offline Python helper tests passed in the authoring environment:

```sh
python3 -m unittest discover -s tools -p 'test_port_uniswap_v4.py' -v
```

These cover scope selection, add/modify/delete and mode handling, public-license/audit preservation, collision/symlink rejection, committed-blob reads, and a synthetic credential sentinel. They do **not** establish Solidity build/test success. The helper has not yet been run against a full local copy of the real release.

Before marking ready: complete the real snapshot import, reconcile licensing and public-facing material, inspect the final diff for publication safety, verify tree hashes, and record actual build/test/CI results. The public base branch and deployed contracts must remain unchanged until the normal review process completes.
