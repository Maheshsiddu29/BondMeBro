# BondMeBro deployment commands

This is the copy-paste runbook for the Solidity backend. It covers hook deployment,
pool setup, per-pool configuration, both single-hop swap types, settlement, and pot
distribution.

> **Security:** `.env` is ignored by Git. Never commit it or paste `PRIVATE_KEY` or
> `RPC_URL` into an issue, pull request, or chat. The raw-key commands are suitable
> for a Sepolia rehearsal only. Use a hardware wallet or multisig for mainnet.

## Existing Sepolia deployment

The previously tested Sepolia hook was built before the fixed 37-byte hook payload,
per-currency thresholds, and exact-input `beforeSwap` delta were added. It is a
legacy deployment and must not be used with these scripts. Deploy the current hook
once, then use the new `BOND_HOOK` printed by the deployment script.

## 1. Prepare the checkout

From the repository root:

```bash
cd /path/to/FairFlow
git pull --ff-only origin arena/01a04275-fairflow
git submodule update --init --recursive

# First run only:
cp .env.example .env
```

Edit `.env` and set at least:

```dotenv
RPC_URL=<Sepolia RPC URL>
PRIVATE_KEY=<testnet deployer key>
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
OWNER=<pool-configuration owner address>
```

Choose `BOND_BPS`, `MIN_BONDED_AMOUNT0`, and `MIN_BONDED_AMOUNT1` before deploying.
`BOND_BPS` is capped at 100 basis points. Both thresholds and the rate must be
non-zero to enable bonding, or all three must be zero to deploy with disabled defaults.

## 2. Full current hook deployment command

Export the dotenv values before invoking Foundry. This makes the values available to
`vm.env*` inside the script.

```bash
cd /path/to/FairFlow
set -a
source .env
set +a

forge build

forge script script/DeployBondMeBro.s.sol:DeployBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

The script prints `predicted`, `salt`, and `deployed`. Copy the `deployed` value to
`BOND_HOOK` in `.env`. Because the hook address encodes all enabled permissions, any
change to the Solidity code, constructor values, or permission flags requires a new
CREATE2 salt and a new hook address.

For a dry run, omit `--broadcast`:

```bash
forge script script/DeployBondMeBro.s.sol:DeployBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

## 3. Initialize the pool and add liquidity

Set `BOND_HOOK`, sorted `CURRENCY0`/`CURRENCY1`, `POOL_FEE`, `TICK_SPACING`, and the
intended `SQRT_PRICE_X96` in `.env`, then run:

```bash
forge script script/InitializeBondMeBroPool.s.sol:InitializeBondMeBroPool \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

forge script script/MintBondMeBroPosition.s.sol:MintBondMeBroPosition \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

The initialization and mint scripts are safe to rerun for an already initialized
pool; the mint script checks PoolManager state and skips its optional initializer when
`SQRT_PRICE_X96` is already initialized. Use the canonical network-specific
PositionManager and Permit2 addresses. Set bounded `AMOUNT0_MAX` and `AMOUNT1_MAX`;
the all-maximum values in `.env.example` are for local demos only. The mint script
also rejects a legacy hook that does not carry the current return-delta permissions.

If the deployment used disabled defaults, set these values for the configuration
script:

```dotenv
POOL_MIN_BONDED_AMOUNT0=<minimum currency0 input in raw units>
POOL_MIN_BONDED_AMOUNT1=<minimum currency1 input in raw units>
POOL_BOND_BPS=25
```

Then run the owner-only update:

```bash
forge script script/ConfigureBondMeBroPool.s.sol:ConfigureBondMeBroPool \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

## 4. Execute an exact-input swap

Set `UNIVERSAL_ROUTER`, `PERMIT2`, `TRADER`, `ZERO_FOR_ONE`, `SWAP_AMOUNT_IN`,
`SWAP_AMOUNT_OUT_MINIMUM`, and `MAX_BOND_AMOUNT`:

```bash
forge script script/SwapBondMeBro.s.sol:SwapBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

The script sends a fixed 37-byte payload containing the refund recipient and maximum
bond. Use a non-zero `SWAP_AMOUNT_OUT_MINIMUM` outside a smoke test.

## 5. Execute an exact-output swap

Set `SWAP_AMOUNT_OUT` and `SWAP_AMOUNT_IN_MAXIMUM`. The maximum must include the
pool's required input plus the possible bond:

```bash
forge script script/SwapBondMeBroExactOutput.s.sol:SwapBondMeBroExactOutput \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

For a native input currency, the script supplies `SWAP_AMOUNT_IN_MAXIMUM` as the
transaction value. The Universal Router still enforces the maximum-input check.

## 6. Wait and settle matured bonds

A bond becomes eligible after `OBSERVATION_BLOCKS`. Anyone can call:

```bash
forge script script/SettleBondMeBro.s.sol:SettleBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

`MAX_COUNT` defaults to 32. Later swaps also settle a capped matured FIFO prefix, so
a keeper is not a protocol dependency.

## 7. Distribute the insurance pot

Set `POT_CURRENCY` to one of the pool currencies and call:

```bash
forge script script/DonateBondPot.s.sol:DonateBondPot \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

An empty pot is a safe no-op. A non-empty donation requires in-range liquidity and
may need repeated calls for a very large pot.

## 8. Verify the deployed hook

Run the read-only verification script (do not add `--broadcast`):

```bash
forge script script/VerifyBondMeBro.s.sol:VerifyBondMeBro \
  --rpc-url "$RPC_URL"
```

You can also inspect the bytecode and immutable values directly:

```bash
cast code "$BOND_HOOK" --rpc-url "$RPC_URL" | cut -c1-20
cast call "$BOND_HOOK" "poolManager()(address)" --rpc-url "$RPC_URL"
cast call "$BOND_HOOK" "owner()(address)" --rpc-url "$RPC_URL"
```

Confirm the returned manager and owner, the hook address permission bits, the pool ID,
the active pool configuration, position liquidity, and all transaction hashes before
launching a network.

## Troubleshooting

- `DeployBondMeBro: BOND_BPS must be <= 100`: change the old 500 bps value to a
  value from 0 through 100. `25` means 0.25%.
- `custom error 0x7983c051` from `initializePool`: the pool already exists. The
  current initialize and mint scripts detect this and skip the duplicate initializer;
  pull the latest branch before retrying.
- `legacy hook permissions`: `BOND_HOOK` is from the earlier deployment. Deploy the
  current hook first; a pool ID includes the hook address, so a new hook needs a new
  pool initialization.
- `OutOfFunds` while minting a native `currency0`: `NATIVE_VALUE` is the ETH sent to
  the mint. It must be affordable after gas, and `LIQUIDITY`/the amount limits must
  match the wallet balance. WETH balance is not ETH balance.

This remains a production-oriented MVP backend, not a security audit. Mainnet still
requires independent audit, economic-parameter review, network-address verification,
bounded slippage, and hardware-wallet or multisig deployment.
