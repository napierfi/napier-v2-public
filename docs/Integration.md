# Front-end Integration

## Getting Started

#### Glossary

- Underlying Token (YBT): Yield-bearing token that is deposited into the protocol to earn interest.
- Factory: A single main entry point for creating new instances of the protocol and managing the protocol's configuration.
- Principal Token (PT): ERC20 Token that represents the principal amount deposited into the protocol.
- Yield Token (YT): ERC20 Token that represents the interest earned on the principal amount deposited into the protocol.
- TwoCrypto: An AMM instance that manages the liquidity pool for a PT and its underlying pair.
- Zap: A single main entry point for users to deposit and withdraw funds from the protocol.
- Quoter: A single main entry point for dry-run transactions for Zap and other actions.
- Lens: A single main entry point for fetching read-only data from the protocol.
- AccessManager: A module that manages roles for the PT instance. Each PT instance has its own AccessManager instance. Curator is the initial owner of the PT instance.

- Factory - PT: one-to-many relationship
- YBT - PT - YT - TwoCrypto: one-to-one relationship
- Zap - TwoCrypto: many-to-one relationship

## Principal Token Lifecycle

- Pre expiry: After deployment, before the maturity date, the PT is in the pre-expiry state. Issuance is enabled by default but under the control of the curator. It's disabled under the following conditions:

  - The PT is paused
  - The curator has set the deposit cap and the cap has been reached
  - The whitelist is enabled by the curator and the user is not whitelisted

- Settlement: After expiry, the first interaction with the PT triggers settlement.

- Post expiry: After settlement, the PT is in the post-expiry state. Issuance is disabled and redemption is enabled. The redemption can not be disabled by the curator to prevent curator from rug pulling.

## Permissions

- Napier protocol does NOT have any privileges for any operations against PT instances by default.
- The curator can grant and revoke permissions for the PT instance.

## Constants

- `NATIVE_TOKEN`: The address of the native token on the chain. `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`

## Common Errors

See [Errors](../src/Errors.sol) for the list of errors emitted by the protocol.

- `Zap_BadPrincipalToken`: The `principalToken` parameter is wrong. Please check the `principalToken` is deployed by the same factory as the one used in the `Quoter` and `Zap`.
- `Zap_BadTwoCrypto`: The `principalToken` parameter is wrong. Please check the `principalToken` is deployed by the same factory as the one used in the `Quoter` and `Zap`.
- `Zap_InconsistentETHReceived`: The amount of ETH received from the user does not match the amount encoded in the function call. Please check the amount of ETH sent with the transaction.
- `Zap_InsufficientETH`: The amount of ETH Zap received is less than it needs because of the slippage or other reasons. Please try again with a higher slippage tolerance.

- `PrincipalToken_VerificationFailed(VerificationStatus status)`: The verification failed for the specified `status` code.

- `Quoter_ERC4626FallbackCallFailed`: `Quoter` made a assumption that the token is ERC4626, but didn't work. The token is not supported by Connectors. Try another token.
- `Quoter_ConnectorInvalidToken`: The token is not supported. Review parameters carefully or use another token.
- `ERC4626Connector_*`: The connector throws an error.

```js
enum VerificationStatus {
    InvalidArguments, // Unexpected error
    Success,
    SupplyMoreThanMax, // The deposit cap reached
    Restricted, // The user is restricted from performing the action
    InvalidSelector // The function selector is invalid
}
```

- `Zap_InconsistentETHReceived`: The amount of ETH received is inconsistent with the value sent.
  This error is thrown when the value sent with the transaction is not equal to the amount of ETH encoded in the function call.

## Events

See [Events](../src/Events.sol) for the list of events emitted by the protocol.

## Impersonator

This contract provides functions to simulate an interaction with Zap. This is useful for retrieving return data and revert reasons of contract write functions.
This contract is not meant to ever actually be deployed, only mock deployed and used via a static `eth_call`.

#### Low level API

```solidity
/// @notice Never revert, always return false on failure.
/// @param zap - Target contract that the user interact with
/// @param tokenIns - List of ERC20 and native tokens that the user spends. The user's tokens spend by Zap must be included in this list.
/// @param value - The amount of native token that the user sends to the Zap contract.
/// @param simPayload - The Zap contract function call to be simulated. The params must be abi-encoded, starting with a function selector.
/// @return ret - The return data from the function call with `simulationPayload`.
function query(address zap, Token[] memory tokenIns, uint256 value, bytes memory simPayload) public returns (bytes memory ret)

function query(address zap, Token tokenIn, uint256 value, bytes memory simPayload) public returns (bytes memory ret)
```

For each swap methods, we have type-safe utility functions to encode and decode the function data.
Please refer to each method's documentation for more details.

Runtime code (hex-encoded): (WIP)

```hex

```

### How to use

`Impersonator` depends on `eth_call` with `stateOverride` option.

- Replace the user's `code` with the `Impersonator` bytecode. This means the user's account turns into a contract wallet.
- Override the `account` (The Account to simulate the contract method from.) with the user's address.

See https://viem.sh/docs/contract/simulateContract#stateoverride-optional

#### Example

The example `Zap#swapPtForToken`: Simulate the function call and get the preview and then run the actual transaction.

```js
const simulationPayload = viem.encodeFunctionData({
  abi: ZapABI,
  functionName: "swapPtForToken",
  args: params,
});

const result = await client.simulateContract({
  address: user,
  abi: impersonatorABI,
  functionName: "query",
  args: [zap, pt, simulationPayload],
  stateOverride: [
    {
      account: user,
      code: impersonatorCode,
    },
  ],
});
const { success, returndata } = viem.decodeFunctionResult({
  abi: impersonatorABI,
  functionName: "query",
  data: result,
});
const preview = success
  ? viem.decodeFunctionResult({
      abi: ZapABI,
      functionName: "swapPtForToken",
      data: returndata,
    })
  : 0;

// Calculate slippage and execute
params.amountOutMin = (preview * (10000 - slippageBps)) / 10000;

await pt.approve(zap.address, principal);
const result = await zap.swapPtForToken(params);
```

## Deploying New instances

To deploy a new Principal Token (PT) instance from the frontend, you'll need to prepare the following parameters for the Factory contract's `createAndAddLiquidity` function:

- `caller` creates new instance of PT, YT and TwoCrypto and deposits `shares` of underlying token as an initial liqudity and receives `liquidity` amount of LP token and `principal` amount of PT.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `shares`.
2. **Get Quote**: Preview how many amount of LP token you're going to receive.
3. **Calculate Slippage**: Calculate slippage.
4. **Execute**: Call the function

```solidity
struct CreateAndAddLiquidityParams {
    // Params for new deployment
    Factory.Suite suite;
    Factory.ModuleParam[] modules;
    uint256 expiry;
    address curator;
    // Params for initial liquidity
    uint256 shares; // Amount of underlying token to be deposited as an initial liqudity
    uint256 minYt;
    uint256 minLiquidity;
    uint256 deadline; // Transaction deadline in unix timestamp in seconds
}

// TwoCryptoZap
function createAndAddLiquidity(CreateAndAddLiquidityParams calldata params) external returns (address pt, address yt, address twoCrypto, uint256 liquidity, uint256 principal);

// Impersonator
function queryCreateAndAddLiquidity(
    address zap,
    address quoter,
    Factory.Suite calldata suite,
    Factory.ModuleParam[] calldata modules,
    uint256 expiry,
    address curator, // Address that will have admin access to configure the PT instance
    uint256 shares // Amount of underlying token to be deposited as an initial liqudity
) external returns (uint256 liquidity, uint256 principal);
```

```js
const slippageBps = 100; // 1% slippage
const MINIMUM_LIQUIDITY = 1000; // Minimum liquidity to be deposited

// Validate parameters like AMM parameters, resolver, blueprint addresses etc.

// Expiry check
if (expiry > Date.now() / 1_000)
  throw new Error("Expiry must be in the future");
// Minimum liquidity check
if (shares === MINIMUM_LIQUIDITY)
  throw new Error("Shares must be greater than 0");

// Get quote
const preview = await client.simulateContract({
  address: user,
  abi: impersonatorABI,
  functionName: "queryCreateAndAddLiquidity",
  args: [zap, quoter, suite, modules, expiry, curator, shares],
  stateOverride: [
    {
      account: user,
      code: impersonatorCode,
    },
  ],
});

// Calculate slippage
params.minLiquidity = (preview.liquidity * (10000 - slippageBps)) / 10000;
params.minYt = (preview.principal * (10000 - slippageBps)) / 10000;

await underlyingToken.approve(zap.address, shares);
const result = await zap.createAndAddLiquidity(params);
```

See [Impersonator.sol](../src/lens/Impersonator.sol) for the detail.

The next section describes the parameters in detail:

1. `Suite`: Configuration struct containing implementation addresses and initialization arguments

   ```solidity
   struct Suite {
       address accessManagerImpl;   // Access control implementation
       address ptBlueprint;         // Principal Token blueprint
       address resolverBlueprint;   // Resolver blueprint for yield source integration
       address poolDeployerImpl;    // AMM pool deployer implementation
       bytes poolArgs;              // Pool initialization args (e.g. initial liquidity, fees)
       bytes resolverArgs;          // Resolver initialization args (e.g. yield source address)
   }
   ```

2. `ModuleParam[]`: Array of module configurations that define PT functionality

   ```solidity
   struct ModuleParam {
       ModuleIndex moduleType;
       address implementation;
       bytes immutableData;
   }
   ```

   - `ModuleIndex`: The index of the module in the `modules` array. Please refer to [Types.sol](../src/Types.sol) for the list of module indices.
   - `implementation`: The implementation contract address.
   - `immutableData`: The module-specific initialization immutable data.

3. `expiry`: Unix timestamp in seconds when the PT matures (must be in the future)

4. `curator`: Address that will have admin access to configure the PT instance (set to zero address for no admin control)

Once `Zap.createAndAddLiquidity()` transaction succeed, the following contracts are deployed:

1. `VaultInfoResolver`
2. `AccessManager`: The `curator` is owner of the instance
3. Module instances: Each module is initialized with the PT address and module-specific immutable data
4. `YieldToken (YT)`
5. `PrincipalToken (PT)`
6. AMM instance

### How to set fee configuration

The FeeModule is responsible for managing fees. The module is mandatory and must be included in the `modules` array.

- Split fee ratio (0-10000 basis points): The fee ratio defines how much percentage of the fee will go to the `curator` and the rest will go to Napier protocol.
- Issuance fee (0-10000 basis points): The fee charged when a user issues PT.
- Performance fee (0-10000 basis points): The fee charged when the underlying token accrues yield.
- Redemption fee (0-10000 basis points): The fee charged when a user redeems PT.
- Post-settlement fee (Performance feeafter settlement) (0-10000 basis points): The fee charged when the underlying token accrues yield after settlement.

To configure fees, use the [`FeePctsLib.pack()`](../src/utils/FeePctsLib.sol) function to pack fee parameters into a [`FeePcts`](../src/Types.sol) `uint256` value.

> [!NOTE]
> We only support `ConstantFeeModule` which sets fees only on deployment time. The split fee ratio is 50% by default, changeable through Napier protocol governance.

```js
const feePcts = FeePctsLib.pack(
  splitFee, // 50% by default, changeable through Napier protocol governance
  issuanceFee,
  performanceFee,
  redemptionFee,
  postSettlementFee
);
const immutableData = encodeAbiParameters(
  [{ name: "feePcts", type: "uint256" }],
  [feePcts]
);
```

### How to choose resolver

Resolver is responsible for fetching the yield source data. We support most of the yield sources except rebasing tokens.
Here's a flowchart to help choose the appropriate resolver for your yield source:

```txt
        ____________________                                                                                                    ┌────────────────┐
       ╱                    ╲                                                                                                   │We don't support│
      ╱ Is YBT rebase token? ╲__________________________________________________________________________________________________│natively        │
      ╲                      ╱yes                                                                                               └────────────────┘
       ╲____________________╱
                 │no
         ________▽________
        ╱                 ╲                                                                                ┌───────────────────┐
       ╱ Is YBT compatible ╲_______________________________________________________________________________│Use ERC4626Resolver│
       ╲ with ERC4626?     ╱yes                                                                            └───────────────────┘
        ╲_________________╱
                 │no
   ______________▽______________
  ╱                             ╲                                                   ┌─────────────────────┐
 ╱ YBT doesn't implement any     ╲                                                  │Use                  │
╱  share price method but there   ╲_________________________________________________│ExternalPriceResolver│
╲  is a separate oracle contract  ╱yes                                              └─────────────────────┘
 ╲                               ╱
  ╲_____________________________╱
                 │no
     ____________▽_____________
    ╱                          ╲                          ┌────────────────────────┐
   ╱ Does YBT have a conversion ╲                         │Use                     │
  ╱  method to assets for a      ╲________________________│CustomConversionResolver│
  ╲  given shares?               ╱yes                     └────────────────────────┘
   ╲                            ╱
    ╲__________________________╱
                 │no
   ______________▽______________
  ╱                             ╲     ┌──────────────────┐
 ╱ Does YBT have a share price   ╲    │Use               │
╱  method that returns assets     ╲___│SharePriceResolver│
╲  that corresponds to 1 shares?  ╱yes└──────────────────┘
 ╲                               ╱
  ╲_____________________________╱
                 │no
     ┌───────────▽──────────┐
     │We don't support yet. │
     │Please reach out to us│
     └──────────────────────┘

```

<!--
if ("Is YBT rebase token?")
   "We don't support natively"
else if ("Is YBT compatible with ERC4626?") {
    "Use ERC4626Resolver"
} else if ("YBT doesn't implement any share price method but there is a separate oracle contract") {
   "Use ExternalPriceResolver"
} else if ("Does YBT have a conversion method to assets for a given shares?") {
   "Use CustomConversionResolver"
} else if ("Does YBT have a share price method that returns assets that corresponds to 1 shares?") {
   "Use SharePriceResolver"
} else {
  "We don't support yet. Please reach out to us"
} -->

- Parameters `resolverArgs` - `bytes`: ABI encoded arguments for the resolver implementation.
  Each resolver has its own arguments. For more details, please refer to the resolver implementation.

  - `ERC4626Resolver`:
    - `vault` - `address`: The address of the ERC4626 vault.
  - `CustomConversionResolver`:
    - `vault` - `address`: The address of the underlying token
    - `asset` - `address`: The address of the base asset
    - `convertToAssetsFn` - `bytes4`: The selector of the conversion method.
  - `SharePriceResolver`:
    - `vault` - `address`: The address of the underlying token
    - `asset` - `address`: The address of the base asset
    - `assetsPerShareFn` - `bytes4`: The selector of the share price method on the `vault` contract
  - `ExternalPriceResolver`:
    - `vault` - `address`: The address of the underlying token
    - `asset` - `address`: The address of the base asset
    - `priceFeed` - `address`: The address of the oracle contract
    - `getPriceFn` - `bytes4`: The selector of the price feed method on the `priceFeed` contract
  - `ConstantPriceResolver`:
    - `vault` - `address`: The address of the underlying token
    - `asset` - `address`: The address of the base asset

> [!NOTE]
> For example, `resolverArgs` for `CustomConversionResolver` has to be encoded as follows:
>
> ```js
> const resolverArgs = encodeAbiParameters(
>   [
>     { name: "vault", type: "address" },
>     { name: "asset", type: "address" },
>     { name: "convertToAssetsFn", type: "bytes4" },
>   ],
>   [vault, asset, convertToAssetsFn]
> );
> ```

> [!IMPORTANT]
> Conversion methods and share price methods must return correct decimals, so that the PT can convert between PT and underlying token correctly:
> `principal = scale() * shares / 1e18`

### Choose AMM type

Currently, we support only Curve finance TwoCrypto-NG AMM.

> [!CAUTION]
> The name and symbol of TwoCrypto LP token have a limit on the length. If the length is too long, the pool deployment will fail.

- Parameter `poolArgs`: It depends on the AMM implementation.

- TwoCrypto-NG parameters: Parameters for TwoCrypto-NG AMM should be set based on underlying token properties like volatility and average yield.
  For more details, please refer to the [TwoCrypto-NG](https://docs.curve.fi/cryptoswap-exchange/twocrypto-ng/overview) documentation.

```solidity
/// @notice Parameters for TwoCrypto-NG AMM
/// @custom:field gamma Gamma parameter for the AMM (1e18 unit) -> 0.019 on UI should be converted to 0.019e18 in SC representation
/// @dev Same for other parameters regarding UI representation vs SC representation
struct TwoCryptoNGParams {
    uint256 A; // 0 unit
    uint256 gamma; // 1e18 unit
    uint256 mid_fee; // 1e8 unit
    uint256 out_fee; // 1e8 unit
    uint256 fee_gamma; // 1e18 unit
    uint256 allowed_extra_profit; // 1e18 unit
    uint256 adjustment_step; // 1e18 unit
    uint256 ma_time; // 0 unit
    uint256 initial_price; // Initial price of the PrincipalToken against the underlying token (1e18 unit)
}
```

```js
const poolArgs = encodeAbiParameters(abi[0].inputs, [twocryptoParams]);
```

> [!TIP]
> The `initial_price` should be set based on initial implied APY.
> Define `t` as the time until maturity in seconds (`maturity - block.timestamp`), `i_0` as the initial implied APY in `1e18` unit, `p` as the initial price of the PrincipalToken against the underlying token in `1e18` unit, and `s` as the scale of the underlying token in `1e18` unit.
>
> ```math
> i_0 := \left(\frac{1}{\frac{p \times s}{10^{36}}} \right)^{\frac{365}{t}} - 1
> ```
>
> Let's say we deploy PT-wstETH with the initial price is 0.972 wstETH and the scale is 1.0.
> If the PT matures in 3 months, the initial implied APY is 12.03%.
>
> ```math
> i_0 := \left(\frac{1}{0.972 \times 1.0} \right)^{\frac{1}{0.25}} - 1 = 0.1203
> ```

> [!TIP]
> We have a helper function to calculate the initial PT price in underlying token based on the initial implied APY.
>
> ```solidity
>     /// @notice Impersonator API
>     /// @param zap The address of the Zap contract
>     /// @param expiry The expiry timestamp in seconds (must be in the future)
>     /// @param impliedAPY The initial implied APY in `1e18` unit (should be positive)
>     /// @param resolverBlueprint The blueprint address of the resolver
>     /// @param resolverArg The resolver arguments
>     /// @return initialPtPrice The initial PT price in underlying token (1e18)
>     function queryInitialPrice(
>      address zap,
>      uint256 expiry,
>      int256 impliedAPY,
>      address resolverBlueprint,
>      bytes calldata resolverArg
>  ) external returns (uint256 initialPtPrice);
> ```
>
> Parameters:
>
> - `impliedAPY`: The initial implied APY in `1e18` unit.
>
> Errors:
>
> - `Impersonator_InvalidResolverBlueprint`: Thrown when the resolver blueprint is not registered in the Factory.
> - `Impersonator_ExpiryIsInThePast`: Thrown when the expiry is in the past.
> - `Impersonator_InvalidResolverConfig`: Thrown when the resolver configuration is invalid. Please check the following:
>   - Wrong resolver blueprint argument.
>   - Resolver argument dose not match the parameter type of the given resolver blueprint.
>   - Share price method of underlying token reverts when simulated.
> - `ExpOverflow`: Thrown when the initial price is too big to be represented as an integer.

### How to set deposit cap

To set deposit caps for PT/YT issuance and underlying asset supply, you can use the `DepositCapVerifierModule`. This module allows setting maximum limits for both supply and issuance operations.

```js
const cap = 1000000; // Deposit cap in unit of underlying tokens.
const immutableData = encodeAbiParameters(
  [{ name: "depositCap", type: "uint256" }],
  [cap]
);
```

Initialization parameters:

- `depositCap`: The maximum amount of underlying token that the PrincipalToken contract can have. It includes the deposits from users, fees, unclaimed yield, etc. When the deposit cap is reached, the `PrincipalToken.supply*` and `PrincipalToken.issue*` function will revert.

To update the deposit cap after deployment, use the `DepositCapVerifierModule`'s `setDepositCap` functions.

```js
depositCapModule.setDepositCap(cap);
```

### How to set additional rewards

WIP

### Possible Error Reasons

When deploying a new PT instance, the following errors may occur:

1. `Factory_InvalidSuite`: Thrown when any of the Suite parameters are invalid:

   - `accessManagerImpl` is zero address or not registered
   - `ptBlueprint` is zero address or not registered
   - `resolverBlueprint` is zero address or not registered
   - `poolDeployerImpl` is zero address or not registered

   Solution: Verify all implementation addresses are properly registered in the Factory contract using `s_accessManagerImplementations`, `s_ytBlueprints`, `s_resolverBlueprints`, and `s_poolDeployers` mappings. Only addresses registered by the Factory admin will work.

2. `Factory_InvalidExpiry`: Thrown when expiry timestamp is in the past

   Solution: Ensure the expiry timestamp is set to a future date. The timestamp must be greater than `block.timestamp`.

3. `Factory_FeeModuleRequired`: Thrown when FeeModule is missing

   Solution: Always include a FeeModule in the ModuleParam array. This is a mandatory module for all PT instances.

4. `Factory_InvalidModule`: Thrown when module configuration is invalid

   Solution:

   - Check that module implementations are registered using `Factory.isValidImplementation()`
   - Verify `ModuleIndex` enum values match the Factory's supported types
   - Only use module implementations that have been enabled by Factory admin

5. `FeeModule_InvalidFeeParam`: Thrown when fee parameters are invalid

   Solution:

   - Keep split fee below maximum
   - Keep issuance/performance/redemption fees below maximums

6. `PoolDeployer_FailedToDeployPool`: Thrown when pool deployment fails

   Solution:

   - Verify pool parameters (fees, weights, etc) are within valid ranges
   - TwoCrypto deployer may revert if the underlying token name is too long

7. Specific errors thrown by modules

   Solution:

   - Check module's initialization parameters match its expected format

## Role Management

Roles are defined as a bit in the `uint256` value. Each bit represents a role, using bitwise OR to combine multiple roles.

```js
const PAUSER_ROLE = 1 << 0;
const UNPAUSER_ROLE = 1 << 1;
const FEE_COLLECTOR_ROLE = 1 << 2;

// Examples
const EMERGENCY_PAUSER = PAUSER_ROLE | UNPAUSER_ROLE; // Both PAUSER and UNPAUSER roles
const MULTISIG = PAUSER_ROLE | UNPAUSER_ROLE | FEE_COLLECTOR_ROLE;
```

AccessManager supports the following operations:

- Grant/Revoke role
- Assign/Revoke role to an account
- Check if an account has a role or multiple roles
- Transfer ownership
- Multicall

### Grant/Revoke roles

The curator (owner of the AccessManager instance) can grant and revoke roles for specific functions on target contracts. This allows fine-grained access control over who can call which functions.

```js
// Example role definitions (these should match your contract's role constants)
const PAUSER_ROLE = 1n << 0n; // Role that can pause the contract
const FEE_MANAGER_ROLE = 1n << 1n; // Role that can manage fees
const REWARD_MANAGER_ROLE = 1n << 2n; // Role that can manage rewards

// Grant roles
async function grantTargetFunctionRoles(
  accessManager,
  target,
  selectors,
  roles
) {
  // Only curator can grant roles
  if ((await accessManager.owner()) !== address) {
    throw new Error("Only curator can grant roles");
  }

  await accessManager.grantTargetFunctionRoles(
    target, // Address of contract to grant access to
    selectors, // Array of function selectors [0x12345678, 0x87654321]
    roles // Bitmap of roles to grant
  );
}

// Revoke roles
async function revokeTargetFunctionRoles(
  accessManager,
  target,
  selectors,
  roles
) {
  // Only curator can revoke roles
  if ((await accessManager.owner()) !== address) {
    throw new Error("Only curator can revoke roles");
  }

  await accessManager.revokeTargetFunctionRoles(
    target, // Address of contract to revoke access from
    selectors, // Array of function selectors [0x12345678, 0x87654321]
    roles // Bitmap of roles to revoke
  );
}
```

### Assign roles to an account

```js
async function grantRoles(accessManager, account, roles, signer) {
  // Only curator can assign roles
  if ((await accessManager.owner()) !== signer.address) {
    throw new Error("Only curator can assign roles");
  }

  await accessManager.grantRoles(account, roles);
}

async function revokeRoles(accessManager, account, roles, signer) {
  // Only curator can assign roles
  if ((await accessManager.owner()) !== signer.address) {
    throw new Error("Only curator can revoke roles");
  }

  await accessManager.revokeRoles(account, roles);
}

// Check if an address has permission to call a function
async function canCall(accessManager, caller, target, selector) {
  return await accessManager.canCall(
    caller, // Address attempting to call the function
    target, // Contract being called
    selector // Function selector being called
  );
}
```

**Example Usage:**

```js
const MULTISIG = "0x...";

// Grant PAUSER_ROLE to an address for the pause() function
const pauseSelector = "0x8456cb59"; // pause() function selector
await accessManager.grantTargetFunctionRoles(
  principalToken.address,
  [pauseSelector],
  PAUSER_ROLE
);

// Grant multiple roles for multiple functions
const selectors = [
  "0x8456cb59", // pause()
  "0x4fee13fc", // setFees()
];
const roles = PAUSER_ROLE | FEE_MANAGER_ROLE; // Combine roles with bitwise OR
await accessManager.grantTargetFunctionRoles(
  principalToken.address,
  selectors,
  roles
);

// Revoke target function roles
await accessManager.revokeTargetFunctionRoles(
  principalToken.address,
  [pauseSelector],
  PAUSER_ROLE
);

// Grant roles to an account
await accessManager.grantRoles(MULTISIG, roles);
```

**Events:**

The following events are emitted when roles are granted or revoked:

```solidity
event TargetFunctionRolesGranted(
    address indexed target,
    bytes4 indexed selector,
    uint256 indexed roles
);

event TargetFunctionRolesRevoked(
    address indexed target,
    bytes4 indexed selector,
    uint256 indexed roles
);

/// @dev The `user`'s roles is updated to `roles`.
/// Each bit of `roles` represents whether the role is set.
event RolesUpdated(address indexed user, uint256 indexed roles);
```

**Error Cases:**

- `Ownable_NotOwner`: Only the curator (owner) can grant or revoke roles
- `AccessManaged_Restricted`: Thrown when an address attempts to call a function without having the required role

### Multicall

```solidity
function multicall(bytes[] calldata data) public payable returns (bytes[] memory);
```

```js
const grantRolesPayload = viem.encodeFunctionData({
  abi: AccessManagerABI,
  functionName: "grantRoles",
  args: viem.encodeAbiParameters(
    viem.parseAbiParameters("address user, uint256 roles"),
    [{ user: user, roles: PAUSER_ROLE | UNPAUSER_ROLE }]
  ),
});

const grantTargetFunctionsPayload = viem.encodeFunctionData({
  abi: AccessManagerABI,
  functionName: "grantTargetFunctionRoles",
  args: viem.encodeAbiParameters(
    viem.parseAbiParameters(
      "address target, bytes4[] selectors, uint256 roles"
    ),
    [
      {
        target: principalToken.address,
        selectors: [pauseSelector],
        roles: PAUSER_ROLE,
      },
    ]
  ),
});

const payloads = [grantRolesPayload, grantTargetFunctionsPayload];
await accessManager.multicall(payloads);
```

### Transfer ownership

Two-step ownership handover is implemented.

Documentation: https://vectorized.github.io/solady/#/auth/ownable

> [!WARNING]
> Only the `curator` can transfer ownership.

### Renounce ownership

Documentation: https://vectorized.github.io/solady/#/auth/ownable

> [!WARNING]
> Only the `curator` can renounce ownership.
> Once the owner is renounced, the principalToken is not pausable anymore.

## Managing Configuration

### Update Fee configuration

- Only fee split ratio can be updated through Napier protocol permission.

### Update Modules

WIP

## Emergency Pause

For emergency situations, authorized accounts by `curator` can pause the PT issuance using `pause()` functions. Napier protocol does NOT have any privileges for any operations.

For unpausing, `unpause()` function can be used to resume the PT issuance.

```js
pt.pause();
pt.unpause();
```

> [!WARNING]
> Once the owner is renounced, the principalToken is not pausable anymore.

### Claim fees

There are two types of fee collection functions:

1. `collectCuratorFees`: For curator (owner) to collect their portion of fees
2. `collectProtocolFees`: For Napier protocol to collect protocol fees

#### Curator Fee Collection

```js
// Only accounts authorized by Curator can collect fees
const additionalTokens = []; // Additional reward tokens to collect (optional)
const feeReceiver = "0x..."; // Address to receive the collected fees

const tx = await pt.collectCuratorFees(additionalTokens, feeReceiver);
```

#### Protocol Fee Collection

```js
// Only accounts authorized by Napier's AccessManager can collect fees
const additionalTokens = []; // Additional reward tokens to collect (optional)

const tx = await pt.collectProtocolFees(additionalTokens);
// Fees will be sent to the treasury address configured in the Factory
```

The fees that can be collected include:

- Issuance fees: Charged when users issue PT/YT
- Performance fees: Charged on yield accrual before settlement
- Redemption fees: Charged when users redeem PT/YT
- Post-settlement fees: Charged on yield accrual after settlement

The fee split ratio between curator and protocol:

- Default split ratio is set during deployment
- Only Napier protocol can update the split ratio through `FeeModule.updateFeeSplitRatio()`
- Split ratio has a maximum of 95% (9,500 basis points)
- Split ratio cannot be set to 0

To check accumulated fees:

```js
// Returns [curatorFee, protocolFee] in underlying token units
const [curatorFee, protocolFee] = await pt.getFees();

// For reward tokens, returns [curatorReward, protocolReward] for a specific token
const [curatorReward, protocolReward] = await pt.getFeeRewards(rewardToken);
```

Events emitted:

- `CuratorFeesCollected(address indexed by, address indexed receiver, uint256 shares, TokenReward[] rewards)`
- `ProtocolFeesCollected(address indexed by, address indexed treasury, uint256 shares, TokenReward[] rewards)`

## Issue PT and YT

**Description**:

```solidity
function supply(PrincipalToken pt, address tokenIn, uint256 amountIn, address receiver, uint256 minPrincipal) returns(uint256 principal);
```

- `caller` deposits `amountIn` of `tokenIn` to the specified `pt` and issues at least `minPrincipal` amount of PT and YT to `receiver`.

**Parameters**:

- `tokenIn`: The address of the token to deposit.
  - Its underlying token is always accepted as `tokenIn`.
  - If its underlying token follows ERC4626, `tokenIn` can be its base asset as well.
  - If its underlying token does not follow ERC4626, `tokenIn` must be supported by `vaultConnectorRegistry`.
  - If native token is input, it must be `NATIVE_TOKEN` address.
  - If WETH can be accepted, native token is automatically supported.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `amountIn` of `tokenIn`.
2. **Get Quote**: Ensure that the issued PT meets or exceeds the `minPrincipal`.
3. **Calculate Slippage**: Calculate `minPrincipal` with slippage configuration.
4. **Execute**: Call zap's `supply` function

```js
const tokenIn = "0x..."; // The address of the token to deposit including native token
const slippageBps = 100; // 1% slippage

// Issuance is disabled after expiry
if (Date.now() / 1_000 >= pt.maturity()) throw new Error("PrincipalToken expired");

const principal = await quoter
  .previewSupply(pt, tokenIn, amountIn)
  .catch((e) => 0); // 0 if the token is not supported
if (principal === 0) {
  // The token is not supported or principalToken is expired
  return;
}
if (token.isNotNative()) await tokenIn.approve(zap.address, amountIn);
const minPrincipal = (principal * (10_000 - slippageBps)) / 10_000;
const value = NATIVE_TOKEN === tokenIn ? amountIn : 0;
const result = await zap.supply{value: value}(
  pt,
  tokenIn,
  amountIn,
  receiver,
  minPrincipal
);
```

**Error**:

- Insufficient allowance: Ensure that the allowance for `tokenIn` is sufficient.
- `Zap_InsufficientPrincipalOutput`: The issued PT is less than `minPrincipal`.

**Event Emission**:  
Upon successful execution, the following event is emitted:

- `Supply`
- `YieldAccrued`
- `YieldFeeAccrued`

## Combine PT and YT (Redeem PT and YT)

**Description**:

```solidity
function combine(PrincipalToken pt, address tokenOut, uint256 principal, address receiver, uint256 minAmount) returns(uint256 amountOut);
```

- `caller` redeem `principal` of `pt` nad `yt` for at least `minAmount` amount of `tokenOut` to `receiver`.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `principal` of `pt` and `yt`.
2. **Get Quote**: Preview how many amount of `tokenOut` you're going to receive.
3. **Calculate Slippage**: Calculate `minAmount` with slippage configuration.
4. **Execute**: Call zap's `combine` function

```js
const tokenOut = "0x..."; // The address of the token to deposit including native token
const principal = 1000000;
const slippageBps = 100; // 1% slippage

const preview = await quoter
  .previewCombine(pt, tokenOut, principal)
  .catch((e) => 0); // 0 if the token is not supported
if (preview === 0) {
  return;
}
await pt.approve(zap.address, principal);
await yt.approve(zap.address, principal);
const minAmount = (principal * (10_000 - slippageBps)) / 10_000;
const result = await zap.combine(pt, tokenOut, principal, receiver, minAmount);
```

**Error**:

- Insufficient allowance: Ensure that the allowance for `pt` and `yt` is sufficient.
- `Zap_InsufficientTokenOutput`: The received amount of `tokenOut` is less than `minAmount`.

**Event Emission**:  
Upon successful execution, the following event is emitted:

- `Unite`
- `YieldAccrued`
- `YieldFeeAccrued`

## Redeem PT

**Description**:

```solidity
function redeem(PrincipalToken pt, address tokenOut, uint256 principal, address receiver, uint256 minAmount) returns(uint256 amountOut);
```

- `caller` redeem `principal` of `pt` nad `yt` for at least `minAmount` amount of `tokenOut` to `receiver`.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `principal` of `pt`.
2. **Get Quote**: Preview how many amount of `tokenOut` you're going to receive.
3. **Calculate Slippage**: Calculate `minAmount` with slippage configuration.
4. **Execute**: Call zap's `redeem` function

```js
const tokenOut = "0x..."; // The address of the token to deposit including native token
const principal = 1000000;
const slippageBps = 100; // 1% slippage

const preview = await quoter
  .previewRedeem(pt, tokenOut, principal)
  .catch((e) => 0); // 0 if the token is not supported
if (preview === 0) {
  return;
}
await pt.approve(zap.address, principal);
await yt.approve(zap.address, principal);
const minAmount = (principal * (10_000 - slippageBps)) / 10_000;
const result = await zap.redeem(pt, tokenOut, principal, receiver, minAmount);
```

**Error**:

- Expiry: The `pt` must not be expired to redeem.
- Insufficient allowance: Ensure that the allowance for `pt`.
- `Zap_InsufficientTokenOutput`: The received amount of `tokenOut` is less than `minAmount`.

**Event Emission**:  
Upon successful execution, the following event is emitted:

- `Unite`
- `YieldAccrued`
- `YieldFeeAccrued`

## Preview Collecting interest and additional rewardsÏ

```solidity
  struct PreviewCollectResult {
      uint256 interest;
      TokenReward[] rewards;
  }
function previewCollects(PrincipalToken[] calldata pts, address account) returns(PreviewCollectResult[] memory);
```

> [!NOTE]  
> The rewards will show the amount of rewards since the last time the user interacted with the protocol.
> So, it is always less than the actual amount of rewards that the user will receive.

```js
const account = "0x..."; // The user address
const pts = ["0x..."]; // The addresses of the principal token to collect interest and rewards

const result = await quoter.previewCollects(pt, account);
```

## Batch Collecting interest and additional rewards

**Description**:

```solidity
struct CollectInput {
    address principalToken;
    PermitCollectInput permit;
}

struct PermitCollectInput {
    uint256 deadline; // Unix timestamp in seconds. If the deadline is 0, Zap makes an assumption that the user has already approved the Zap to collect interest and rewards.
    uint8 v;
    bytes32 r;
    bytes32 s;
}
function collectWithPermit(CollectInput[] calldata inputs, address receiver) external;
function isApprovedCollector(address owner, ad dress collector) returns(bool);
```

- `caller` collects interest and rewards in a single transaction for multiple `principalToken`.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to collect interest and rewards.
2. **Get Quote**: Preview how many amount of interest and rewards you're going to receive.
3. **Execute**: Call zap's `collectWithPermit` function

```js
const walletProvider = new PseudoWalletProvider(); // Pseudo wallet instance

const deadline = Math.floor(Date.now() / 1_000) + 60 * 30; // 30 mins in unix timestamp in seconds

const isApproveds = await Promise.all(
  pts.map((pt) => {
    // Check if the user has approved the Zap to collect interest and rewards for each principal token
    return pt.isApprovedCollector(account, zap.address)
  })
);

const permits = await Promise.all(
  pts.map((pt) => {
    // Note If already approved, no need to sign, pass `deadline` as 0 to skip signature verification on the smart contract side.
    if (isApproveds[i]) return { pt, deadline: 0, v: 0, r: 0, s: 0};
    // Get the permit signature for each principal token
    return signPermitCollector(pt, walletProvider, deadline); // Anyway user signs the permit here
  })
);
const inputs = permits.map((permit) => ({
  principalToken: permit.pt
  permit: permit
}));
const result = await zap.collectWithPermit(inputs, receiver);
```

**Error**:

- `InvalidPermit`: Signature is invalid. Check the signature and nonce.
- `PermitExpired`: The signature is expired. The deadline is less than the current timestamp.
- `PrincipalToken_NotApprovedCollector`: The user has not approved the Zap to collect interest and rewards for the specified `principalToken`. The user must pass signature to the function parameter.

## Approve Zap to collect interest and rewards by signature

### pseudocode

```js
/// @dev `keccak256("PermitCollector(address owner,address collector,uint256 nonce,uint256 deadline)")`.
const PERMIT_COLLECTOR_TYPEHASH =
  "0xabaa81be0e21ab93788e05cd5409517fd2908fd1c16213aab992c623ac2cf0a4";

/// @dev const domainSeparator = await pt.DOMAIN_SEPARATOR();
const domain = {
  name: await pt.name(),
  version: "1",
  chainId: 1, // Chain ID of the network
  verifyingContract: pt.address,
};

// The named list of all type definitions
const types = {
  PermitCollector: [
    { name: 'owner', type: 'address' },
    { name: 'collector', type: 'address' },
    { name: 'nonce', type: 'uint256' },
    { name: 'deadline', type: 'uint256' },
  ],
} as const

// User signs the permit
const signature = wallet.signTypedData({
  domain,
  types,
  primaryType: "PermitCollector",
  message: {
    owner: wallet.user,
    collector: ZAP_ADDRESS,
    nonce: await wallet.nonce(),
    deadline,
  },
});
```

See https://viem.sh/docs/actions/wallet/signTypedData

## Add liquidity with PT and underlying token

**Description**:

```solidity
struct AddLiquidityParams {
    TwoCrypto twoCrypto;
    uint256 shares;
    uint256 principal;
    uint256 minLiquidity;
    address receiver;
    uint256 deadline;
}
function addLiquidity(AddLiquidityParams calldata params)    external    returns (uint256 liquidity)
```

- `caller` deposits `shares` of underlying token and `principal` amount of PT to the specified `twoCrypto` and sends `liquidity` of LP token to `receiver`.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `principal` and `shares`.
2. **Get Quote**: Preview how many amount of LP token you're going to receive.
3. **Calculate Slippage**: Calculate `minLiquidity` with slippage configuration.
4. **Execute**: Call the function

```js
const slippageBps = 100; // 1% slippage

// Depositing is disabled after expiry
if (Date.now() / 1_000 >= pt.maturity())
  throw new Error("PrincipalToken expired");

const preview = await quoter
  .previewAddLiquidity(twoCrypto, shares, principal)
  .catch((e) => 0); // 0 if the token is not supported
if (preview === 0) {
  return;
}

await underlyingToken.approve(zap.address, shares);
await pt.approve(zap.address, principal);

const minLiquidity = (preview * (10_000 - slippageBps)) / 10_000;
const params = {
  twoCrypto,
  shares,
  principal,
  minLiquidity,
  receiver,
  deadline: Math.floor(Date.now() / 1_000) + 60 * 30, // 30 mins in unix timestamp in seconds
};
const result = await zap.addLiquidity(params);
```

**Error**:

- Insufficient allowance: Ensure that the allowance for `shares` and `principal` is sufficient.
- Slippage error: The received amount of LP token is less than `minLiquidity`.

**Event Emission**:  
Upon successful execution, the following event is emitted:

WIP

## Add liquidity with single token

**Description**:

```solidity
struct AddLiquidityOneTokenParams {
    TwoCrypto twoCrypto;
    Token tokenIn;
    uint256 amountIn;
    uint256 minLiquidity;
    uint256 minYt;
    address receiver;
    uint256 deadline;
}
function addLiquidityOneToken(AddLiquidityOneTokenParams calldata params) external returns (uint256 liquidity)
```

- `caller` deposits some of `amountIn` of `tokenIn` to PrincipalToken and mints at least `minPrincipal` amount of PT and YT.
  The issued PT are deposited into the `twoCrypto` with remaining `tokenIn`. The `receiver` receives at least `minLiquidity` amount of LP token and `minYt` amount of YT.
  This deposit tries to minimize slippage by adding tokens proportional to the pool reserves.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `amountIn` of `tokenIn`
2. **Get Quote**: Preview how many amount of LP token you're going to receive.
3. **Calculate Slippage**: Calculate slippage configuration for `minLiquidity` and `minYt`.
4. **Execute**: Call the function

```js
const slippageBps = 100; // 1% slippage
const tokenIn = "0x..."; // The address of the token to deposit including native token
const amountIn = 1000000;

// Depositing is disabled after expiry
if (Date.now() / 1_000 >= pt.maturity())
  throw new Error("PrincipalToken expired");

const preview = await quoter
  .previewAddLiquidityOneToken(twoCrypto, tokenIn, amountIn)
  .catch((e) => 0); // 0 if the token is not supported
if (preview === 0) {
  return;
}

if (tokenOut.isNotNative()) await tokenOut.approve(zap.address, amountIn);

const minYt = (preview.yt * (10_000 - slippageBps)) / 10_000;
const minLiquidity = (preview.liquidity * (10_000 - slippageBps)) / 10_000;
const params = {
  twoCrypto,
  tokenIn,
  amountIn,
  minLiquidity,
  minYt,
  receiver,
  deadline: Math.floor(Date.now() / 1_000) + 60 * 30, // 30 mins in unix timestamp in seconds
};
const result = await zap.addLiquidityOneToken(params);
```

**Error**:

- Insufficient allowance: Ensure that the allowance for `tokenIn` is sufficient.
- Slippage error: Review the slippage configuration for `minLiquidity` and `minYt`.

**Event Emission**:  
Upon successful execution, the following event is emitted:

WIP

## Remove liquidity for PT and underlying token

**Description**:

```solidity
struct RemoveLiquidityParams {
    TwoCrypto twoCrypto;
    uint256 liquidity;
    uint256 minPrincipal;
    uint256 minShares;
    address receiver;
    uint256 deadline;
}
function removeLiquidity(RemoveLiquidityParams calldata params) external returns (uint256 uint256 shares, uint256 principal)
```

- `caller` withdraws `liquidity` of LP token from the `twoCrypto` and receives at least `minPrincipal` amount of PT and `minShares` amount of underlying token to `receiver`.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `liquidity` of LP token.
2. **Get Quote**: Preview how many amount of PT and underlying token you're going to receive.
3. **Calculate Slippage**: Calculate `minPrincipal` and `minShares` with slippage configuration.
4. **Execute**: Call the function

```js
const slippageBps = 100; // 1% slippage
const liquidity = 1e18;
const twoCrypto = "0x..."; // The address of the TwoCrypto pool (LP token)

const preview = await quoter
  .previewRemoveLiquidity(twoCrypto, liquidity)
  .catch((e) => 0); // 0 if the token is not supported
if (preview === 0) {
  return;
}

await twoCrypto.approve(zap.address, liquidity);

const minPrincipal = (preview.principal * (10_000 - slippageBps)) / 10_000;
const minShares = (preview.shares * (10_000 - slippageBps)) / 10_000;
const params = {
  twoCrypto,
  liquidity,
  minPrincipal,
  minShares,
  receiver,
  deadline: Math.floor(Date.now() / 1_000) + 60 * 30, // 30 mins in unix timestamp in seconds
};
const result = await zap.removeLiquidity(params);
```

**Error**:

- Insufficient allowance
- Slippage error
- Pool imbalance

**Event Emission**:  
Upon successful execution, the following event is emitted:

WIP

## Remove liquidity for single token

**Description**:

```solidity
struct RemoveLiquidityOneTokenParams {
    TwoCrypto twoCrypto;
    uint256 liquidity;
    Token tokenOut;
    uint256 amountOutMin;
    address receiver;
    uint256 deadline;
}

function removeLiquidityOneToken(RemoveLiquidityOneTokenParams calldata params) external returns (uint256 amountOut)
```

- `caller` removes `liquidity` of LP token from the `twoCrypto` and receives at least `amountOutMin` amount of `tokenOut` to `receiver`.
  If principal token is expired, the method will redeem the principal token without slippage.
  If principal token is not expired, the method will remove liquidity with underlying token which causes pool ratio change.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `liquidity` of LP token.
2. **Get Quote**: Preview how many amount of `tokenOut` you're going to receive.
3. **Calculate Slippage**: Calculate `amountOutMin` with slippage configuration.
4. **Execute**: Call the function

```js
const tokenOut = "0x..."; // The address of the token to deposit including native token
const liquidity = 1e18;
const slippageBps = 100; // 1% slippage

const preview = await quoter
  .previewRemoveLiquidityOneToken(twoCrypto, tokenOut, liquidity)
  .catch((e) => 0); // 0 if the token is not supported
if (preview === 0) {
  return;
}

await twoCrypto.approve(zap.address, liquidity);

const minAmountOut = (preview * (10_000 - slippageBps)) / 10_000;
const params = {
  twoCrypto,
  tokenOut,
  liquidity,
  receiver,
  deadline: Math.floor(Date.now() / 1_000) + 60 * 30, // 30 mins in unix timestamp in seconds
};
const result = await zap.removeLiquidityOneToken(params);
```

**Error**:

- Insufficient allowance
- Slippage error

**Event Emission**:  
Upon successful execution, the following event is emitted:

WIP

## Token List API

Zap supports multiple tokens as the input and output of the swap functions. The following functions return the list of tokens that can be used as the input and output through connector.

> [!INFO]
> The list of tokens doesn't necessarily cover all the tokens that can be used as the input and output because it's not possible to know ERC4626 standard compliance of the tokens on-chain.

```js
const tokensIn = await quoter.getTokenInList(twoCrypto);
const tokensOut = await quoter.getTokenOutList(twoCrypto);
```

- `tokensIn` is the list of tokens for `tokenIn` parameter of `swapTokenFor{Pt, Yt}` functions or `SwapTokenInput.tokenMintShares` parameter of `swapAnyTokenFor{Pt, Yt}` functions.
- `tokensOut` is the list of tokens for `tokenOut` parameter of `swap{Pt, Yt}ForToken` functions or `SwapTokenOutput.tokenRedeemShares` parameter of `swapAnyTokenFor{Pt, Yt}` functions.

## Swap PT for Token

**Description**:

#### Zap

```solidity
struct SwapPtParams {
    TwoCrypto twoCrypto;
    uint256 principal;
    Token tokenOut;
    uint256 amountOutMin;
    address receiver;
    uint256 deadline;
}
function swapPtForToken(SwapPtParams calldata params) external returns (uint256 amountOut)
```

- `caller` swaps `principal` amount of `principalToken` on a `twoCrypto` pool and sends at least `amountOutMin` of `tokenOut` to `receiver`

#### Quoter

```
function previewSwapPtForToken(TwoCrypto twoCrypto, Token tokenOut, uint256 principal)
    public
    view
    returns (uint256 amountOut)

```

> [!WARNING]
> The preview function of swap PT behaves differently with the mutative version because of a difference in twoCrypto implementation.
> Even if the preview succeeds, the mutative function may fail with an error in TwoCrypto.
> We recommend simulation with `eth_call` approach instead of the preview with `Quoter`.

See `Impersonator#querySwapPtForToken` for the simulation approach.

#### Impersonator

```solidity
/// @return priceInAsset - The execution price of PT in asset. (1 PT-eUSDC = 0.972 USDC => priceInAsset = 0.972e18)
/// @return impliedAPY - The effective implied APY of PT. (23% => impliedAPY = 0.23e18)
function querySwapPtForToken(address zap, Quoter quoter, TwoCrypto twoCrypto, Token tokenOut, uint256 principal)
  public
  returns (uint256 amountOut, uint256 priceInAsset, int256 impliedAPY)
```

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `principal` of `principalToken`
2. **Get Quote**: Preview how many amount you're going to receive.
3. **Calculate Slippage**: Calculate slippage configuration.
4. **Execute**: Call the function

```js
const slippageBps = 100; // 1% slippage
const tokenOut = "0x..."; // The address of the token to deposit including native token
const principal = 1000000;

if ((await client.blockTimestamp()) / 1_000 >= pt.maturity())
  throw new Error("PrincipalToken expired");

const params = {
  twoCrypto,
  principal,
  tokenOut,
  amountOutMin: 0, // For now 0. It should be set based on simulation result.
  receiver,
  deadline: Math.floor(Date.now() / 1_000) + 60 * 30,
};

const preview = await client.simulateContract({
  address: user,
  abi: impersonatorABI,
  functionName: "querySwapPtForToken",
  args: [zap, quoter, twoCrypto, tokenOut, principal],
  stateOverride: [
    {
      account: user,
      code: impersonatorCode,
    },
  ],
});

// Calculate slippage and execute
params.amountOutMin = (preview.amountOut * (10000 - slippageBps)) / 10000;

if (preview.priceInAsset > 1e18) throw new Error("PT price is too high");

await pt.approve(zap.address, principal);
const result = await zap.swapPtForToken(params);
```

**Error**:

- Insufficient allowance: Ensure that the allowance for `tokenIn` is sufficient.
- Slippage error
- Pool Imbalance

**Event Emission**:  
Upon successful execution, the following event is emitted:

WIP

## Swap Token for PT

**Description**:

#### Zap

```solidity
/// @notice Data structure for `swapTokenFor{Pt, Yt}` functions
struct SwapTokenParams {
    TwoCrypto twoCrypto;
    Token tokenIn;
    uint256 amountIn;
    uint256 minPrincipal;
    address receiver;
    uint256 deadline;
}

function swapTokenForPt(SwapTokenParams calldata params) external returns (uint256 amountOut)
```

#### Quoter

```solidity
function previewSwapTokenForPt(TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
    public
    view
    returns (uint256 principal)
```

> [!WARNING]
> Even if the preview succeeds, the mutative function may fail with an error in TwoCrypto.

#### Impersonator

```solidity
function querySwapTokenForPt(address zap, Quoter quoter, TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
    public
    returns (uint256 principal, uint256 priceInAsset, int256 impliedAPY)
```

Similar to [Swap PT for Token](#swap-pt-for-token), we recommend simulation with `eth_call` approach instead of `Quoter` approach.

## Swap YT for Token

#### Zap

```solidity
function swapYtForToken(SwapYtParams calldata params, ApproxValue getDxResult)
    external
    returns (uint256 amountOut)
```

- `caller` swaps **at most** `principal` amount of YT on a `twoCrypto` pool and sends at least `amountOutMin` of `tokenOut` to `receiver`.

- The swap method needs a off-chain calculated `getDxResult` parameter which can be obtained by the preview method.

> [!NOTE]
> This method can't swap exact amount of YT. Decreasing `getDxResult` will cause the user to spend less YTs than the amount specified in the `principal` parameter but increasing it will makes the transaction likely to fail when the market price changes enoughly.

#### Quoter

```
function previewSwapYtForToken(TwoCrypto twoCrypto, Token tokenOut, uint256 principal)
    public
    view
    returns (uint256 amountOut, ApproxValue principalActual, ApproxValue getDxResult)
```

> [!WARNING]  
> The preview function behaves differently with the mutative version because of a difference in twoCrypto implementation.
> Even if the preview succeeds, the mutative function may fail with an error in TwoCrypto.
> We have two options to simulate the function: We recommend the second approach.
>
> 1. Use `Quoter` to get the preview result and use `eth_call` with `Impersonator#query` method.
> 2. Use `eth_call` with `Impersonator#querySwapYtForToken` method to simulate the function. This method do the same thing as the first approach but in a single call.

#### Impersonator

```solidity
/// @notice Get the preview result of `swapYtForToken` function and off-chain parameters for the function.
/// @param principal - The amount of YT to spend.
/// @param errorMarginBps - The error margin in basis points for the off-chain parameters. It's different parameter from the swap slippage.
/// @return amountOut - The amount of tokenOut that the user will receive.
/// @return ytSpent - The amount of YT that the user actually spent.
/// @return dxResultWithMargin - The off-chain parameters for the function.
/// @return priceInAsset - The execution price of PT in asset. (1 PT-eUSDC = 0.972 USDC => priceInAsset = 0.972e18)
/// @return impliedAPY - The effective implied APY of PT. (23% => impliedAPY = 0.23e18)
function querySwapYtForToken(
    address zap,
    Quoter quoter,
    TwoCrypto twoCrypto,
    Token tokenOut,
    uint256 principal,
    uint256 errorMarginBps
) public returns (uint256 amountOut, uint256 ytSpent, ApproxValue dxResultWithMargin, uint256 priceInAsset, int256 impliedAPY)
```

Similar to [Swap PT for Token](#swap-pt-for-token), we recommend simulation with `eth_call` approach instead of `Quoter` approach.

> [!NOTE]
> It affects the amount of `amountOut` and `ytSpent` returned by the function.
> Increasing the `errorMarginBps` parameter will cause the user to spend less YTs than the amount specified in the `principal` parameter.

**Error**:

- `Quoter_InsufficientUnderlyingOutput` : It usually happens when PT price in asset is approximately greater than 1.
- `Zap_PullYieldTokenGreaterThanInput`: Actual swap txn may throw the error because market changes dynamically too much after simulation

## Swap Token for YT

#### Zap

```solidity
/// @notice Data structure for `swapTokenFor{Pt, Yt}` functions
struct SwapTokenParams {
    TwoCrypto twoCrypto;
    Token tokenIn;
    uint256 amountIn;
    uint256 minPrincipal;
    address receiver;
    uint256 deadline;
}

function swapTokenForYt(SwapTokenParams calldata params, ApproxValue sharesFlashBorrow) external returns (uint256 principal)
```

- `caller` swaps `amountIn` of `tokenIn` and sends at least `minPrincipal` of YT to `receiver`.
- The swap method needs a off-chain calculated `sharesFlashBorrow` parameter which can be obtained by calling `previewSwapTokenForYt` method.

#### Quoter

```
function previewSwapTokenForYt(TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn)
  public
  view
  returns (ApproxValue guessYtMax, ApproxValue guessYtMin, ApproxValue sharesBorrow)
```

> [!WARNING]  
> The preview function behaves differently with the mutative version because of a difference in twoCrypto implementation.
> Even if the preview succeeds, the mutative function may fail with an error in TwoCrypto.
> We have two options to simulate the function: We recommend the second approach.
>
> 1. Use `Quoter` to get the preview result and use `eth_call` with `Impersonator#query` method.
> 2. Use `eth_call` with `Impersonator#querySwapTokenForYt` method to simulate the function. This method do the same thing as the first approach but in a single call.

#### Impersonator

```solidity
/// @notice Get the preview result of `swapTokenForYt` function and off-chain parameters for the function.
/// @param errorMarginBps - The error margin in basis points for the off-chain parameters. It's different parameter from the swap slippage.
/// @return principal - The amount of YT that the user is going to receive.
/// @return sharesFlashBorrowWithMargin - The off-chain parameters for the function.
function querySwapTokenForYt(address zap, Quoter quoter, TwoCrypto twoCrypto, Token tokenIn, uint256 amountIn, uint256 errorMarginBps)
  public
  returns (uint256 principal, ApproxValue sharesFlashBorrowWithMargin, uint256 priceInAsset, int256 impliedAPY)
```

> [!NOTE]  
> `errorMarginBps` parameter is used to control the slippage of the off-chain parameters. It affects the amount of `principal` the user will receive.
> Increasing the `errorMarginBps` parameter will cause the user to get less YTs than the user can get with smaller `errorMarginBps`.

**Flow**:

1. **Token Approval**: The `caller` must approve `Zap` to spend `amountIn` of `tokenIn`
2. **Get Quote**: Preview the amount of YT and the amount of shares to borrow.
3. **Calculate Slippage**: Calculate slippage configuration.
4. **Execute**: Call the function

#### `Impersonator#querySwapTokenForYt` approach

```js
const errorMarginBps = 100; // 1% slippage
const slippageBps = 100; // 1% slippage
const params = {
  twoCrypto,
  tokenIn,
  amountIn,
  minPrincipal: 0, // For now 0. It should be set based on simulation result.
  receiver,
  deadline: Math.floor(Date.now() / 1_000) + 60 * 30,
};

if ((await client.blockTimestamp()) / 1_000 >= pt.maturity())
  throw new Error("PrincipalToken expired");

const preview = await client.simulateContract({
  address: user,
  abi: impersonatorABI,
  functionName: "querySwapTokenForYt",
  args: [zap, quoter, tokenIn, amountIn, errorMarginBps],
  stateOverride: [
    {
      account: user,
      code: impersonatorCode,
    },
  ],
});
const { previewPrincipal, sharesFlashBorrow, priceInAsset, impliedAPY } =
  preview;

if (priceInAsset > 1e18)
  throw new Error("PT price is too high (YT price is too low)");

// Calculate slippage and execute
params.minPrincipal = (previewPrincipal * (10000 - slippageBps)) / 10000;

if (tokenIn.isNotNative()) await tokenIn.approve(zap.address, params.amountIn);
const result = await zap.swapTokenForYt(params, sharesFlashBorrow);
```

**Error**:

- Insufficient allowance: Ensure that the allowance for `tokenIn` is sufficient.
- `Zap_DebtExceedsUnderlyingReceived`: The pool reserve state might change drastically before the transaction is executed. The user should retry the transaction with a fresh `sharesFlashBorrow` parameter with higher error margin.
- `Zap_InsufficientYieldTokenOutput`: Typical slippage error.
- Errors from TwoCrypto: Pool imbalance, the `sharesFlashBorrow` parameter is outdated, etc.

**Event Emission**:  
Upon successful execution, the following event is emitted:

WIP
