## Napier V2

## Documentation

https://book.getfoundry.sh/

![overview](./docs/overview.svg)

## Usage

### Install

```shell
pnpm install
```

### Build

```shell
$ forge build
```

### Test

Set the following environment variables in `.env`:

```shell
ALCHEMY_KEY=
ETHERSCAN_API_KEY=
```

```shell
$ forge test -vvv
```

For running symbolic tests with Halmos:

```shell
python3.10 -m venv .venv
source .venv/bin/activate
pip install halmos
```

```shell
halmos --mc=LibRewardProxySymTest
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Slither

```
python3 -m pip install slither-analyzer
pip install solc-select
solc-select install 0.8.24
solc-select use 0.8.24
```

```shell
slither . --config-file slither.config.json --checklist --json result.json --skip-assembly > result.md
```

## Supported Networks

- EVM networks supporting `PUSH0` opcode except for ZkSync Era

## Deployments

All deployments are stored in the [deployments/chains](./deployments/chains) directory.

For generating environment variables for a specific chain and environment, run:

```shell
./deployments/scripts/get-env.sh <chain> <environment> <output_file>
```

Example:

```shell
./deployments/scripts/get-env.sh eth prod .env.generated
```

## Known Issues

1. The whole interest income for a user may be frozen.
   See [YieldMathLib.sol](./src/utils/YieldMathLib.sol) and [PrincipalToken#supply](./src/tokens/PrincipalToken.sol) for more details.
   The issue is similar to [the one](https://github.com/spearbit/portfolio/blob/master/pdfs/Pendle-Spearbit-Security-Review-July-2024.pdf)
2. The whole rewards income for a user may be frozen.
   The root cause is the same as interest income freezing.

3. Swap YT for token may revert because the `TwoCrypto.get_dy` is not accurate when the ramping of the pool is not considered.
   `Zap` ands `Quoter` depend on `get_dx` and `get_dy` functions in `TwoCrypto` for simulating `exchange` function but the ramping of the pool is not considered in the view functions.
