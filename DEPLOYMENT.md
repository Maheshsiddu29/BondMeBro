# BondMeBro deployment commands

This is the copy-paste deployment runbook for the Solidity backend. It keeps the
full `forge script` command in one place and uses the environment variables from
`.env.example`.

> **Security:** `.env` is ignored by Git. Never commit it or paste `PRIVATE_KEY`
> or `RPC_URL` into an issue, pull request, or chat. The raw-key command below is
> suitable for the Sepolia rehearsal only. Use a hardware wallet or multisig for
> a mainnet deployment.

## Existing Sepolia rehearsal

The backend smoke test is already deployed on Sepolia. If you are continuing that
run, **do not run the hook deployment command again**. Use these public values in
`.env` and continue with pool operations:

```dotenv
BOND_HOOK=0x71D5F70343Db7f61B946B733e64A98c842e150C4
POOL_ID=0xcce8ba85b14222c22b00054927131033bd1bbd96689632f988c184c1996b7f34
```

Run section 2 only when deploying a new hook on a new network, or after deliberately
changing the immutable policy configuration.

## 1. Prepare the checkout

Run these commands from the repository root:

```bash
cd /path/to/FairFlow
git pull --ff-only origin arena/01a04275-fairflow
git submodule update --init --recursive

# First run only:
cp .env.example .env
```

Edit `.env` and set at least these values before deploying the hook:

```dotenv
RPC_URL=<Sepolia RPC URL>
PRIVATE_KEY=<testnet deployer key>
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
```

The policy values in `.env.example` are constructor arguments. Changing any of
them produces a different CREATE2 hook address, so choose them before deployment.
For another network, replace `POOL_MANAGER` with that network's official Uniswap
v4 address.

## 2. Full hook deployment command

The `set -a`/`set +a` pair is important: it exports the values loaded from `.env`
so Foundry's `vm.env*` calls can read them.

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

The script mines a CREATE2 salt, prints `predicted`, `salt`, and then prints the
final address as `deployed`. Save that address and put it in `.env` as
`BOND_HOOK`. Do not use the old hook address after changing any constructor
configuration.

To do a simulation without sending a transaction, run the same command without
`--broadcast` first:

```bash
forge script script/DeployBondMeBro.s.sol:DeployBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY"
```

## 3. Complete Sepolia pool rehearsal

After setting `BOND_HOOK` and the network-specific values in `.env`, reload the
environment in the same shell:

```bash
set -a
source .env
set +a

forge script script/InitializeBondMeBroPool.s.sol:InitializeBondMeBroPool \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

forge script script/MintBondMeBroPosition.s.sol:MintBondMeBroPosition \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast

forge script script/SwapBondMeBro.s.sol:SwapBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

For the ETH/WETH Sepolia smoke-test pool, the public values used by the completed
rehearsal were:

```dotenv
POOL_MANAGER=0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
POSITION_MANAGER=0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4
PERMIT2=0x000000000022D473030F116dDEE9F6B43aC78BA3
CURRENCY0=0x0000000000000000000000000000000000000000
CURRENCY1=0xfff9976782d46CC05630D1f6eBAb18b2324d6B14
POOL_FEE=3000
TICK_SPACING=60
SQRT_PRICE_X96=79228162514264337593543950336
```

Use the official Sepolia Universal Router address for `UNIVERSAL_ROUTER`; do not
copy a router address from another network. Set a non-zero
`SWAP_AMOUNT_OUT_MINIMUM` outside a smoke test. The `MintBondMeBroPosition` script
also needs bounded `AMOUNT0_MAX` and `AMOUNT1_MAX` values for production.

## 4. Wait and settle

A bond is eligible only after `OBSERVATION_BLOCKS`. The permissionless settlement
command is:

```bash
forge script script/SettleBondMeBro.s.sol:SettleBondMeBro \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

`MAX_COUNT` defaults to 32 and the contract enforces the same upper bound. Active
pools can settle matured bonds automatically on a later swap; this command keeps a
quiet pool live.

## 5. Donate the insurance pot

Set `POT_CURRENCY` to the currency shown in the `BondSettled` event or to the
currency with a non-zero `insurancePot`, then run:

```bash
forge script script/DonateBondPot.s.sol:DonateBondPot \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --broadcast
```

An empty pot is a safe no-op. A non-empty donation requires in-range liquidity.
Large pots are drained in manager-sized chunks across repeated calls.

## 6. Verify the deployment

```bash
cast code "$BOND_HOOK" --rpc-url "$RPC_URL" | cut -c1-20
cast call "$BOND_HOOK" \
  "poolManager()(address)" \
  --rpc-url "$RPC_URL"
```

The returned `poolManager()` must equal the configured `POOL_MANAGER`. Record the
chain ID, hook address, PoolManager, pool ID, currencies, router, policy values,
and every transaction hash in the deployment manifest before treating a network
as launched.

The current Sepolia rehearsal is a smoke test, not a mainnet launch. Mainnet still
requires a parameter review, bounded slippage settings, an independent security
audit, and hardware-wallet or multisig deployment.
