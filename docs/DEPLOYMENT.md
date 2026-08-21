# Deployment

This document covers the production deployment sequence for the DeepState V1 Uniswap v4 Aggregator Hook on Robinhood Chain (chain ID `4663`). Deployment tooling lives under `script/` and is intentionally separate from production `src/`.

## Current Robinhood deployment

The Planner and Aggregator Hook have been deployed on Robinhood Chain and independently checked with `VerifyDeepStateDeployment.s.sol`. The verifier returned `PASS` for the following bindings:

| Component | Verified value |
| --- | --- |
| Chain ID | `4663` |
| Uniswap v4 `PoolManager` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| DeepState V1 | `0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96` |
| `DeepStatePlanner` | `0xBCAA32dBb2CfB1D13179B7CbAFe29De390A81648` |
| `DeepStateAggregator` | `0xd11758Ec960e365Df35E3790b172B25c708A6888` |
| Routing-fee recipient at verification time | `0x59606fB6b9377Fb08B32B490f34Ae699DeAFeA66` |
| First-byte ID | `0xD1` (proposed upstream ID) |
| Hook flags | `0x2888` (`10376` decimal) |

The routing-fee recipient is intentionally mutable, so the address above records the value verified immediately after deployment rather than an immutable binding. The Planner, DeepState target and PoolManager bindings are immutable.

Deployment transactions:

- Planner: [`0x4b6494ac3ef1a905de81d4d25a7fff16e3392d5e7d14d35ef1c2b4cc06170fde`](https://robinhoodchain.blockscout.com/tx/0x4b6494ac3ef1a905de81d4d25a7fff16e3392d5e7d14d35ef1c2b4cc06170fde)
- Aggregator Hook: [`0xbb2d4698ecf2051472a06b12c1f70929003396591f37e7f0aab9bb45cd6616ce`](https://robinhoodchain.blockscout.com/tx/0xbb2d4698ecf2051472a06b12c1f70929003396591f37e7f0aab9bb45cd6616ce)

See [`../deployments/4663.md`](../deployments/4663.md) for the concise deployment record.

## Status of the Aggregator Hook ID

The deployed DeepState V1 hook uses first-byte ID `0xD1`. It follows the public `v4-hooks-public` convention: the first hex character identifies the protocol and the second identifies the contract type/version. As checked on **2026-08-21**, `D1` is not listed in the public upstream table. It remains a **proposed upstream ID** until DeepState support using that ID is integrated upstream. If the upstream integration uses a different ID, the Aggregator must be mined and deployed again at a new address; the existing `0xD1...` deployment cannot change its first byte in place.

The hook must also encode the four permissions inherited from `BaseAggregatorHook` in the low 14 bits:

```text
beforeInitialize          0x2000
beforeAddLiquidity        0x0800
beforeSwap                0x0080
beforeSwapReturnDelta     0x0008
                         -------
required flags            0x2888
```

The miner therefore searches for an address satisfying both `firstByte == 0xD1` and `(address & Hooks.ALL_HOOK_MASK) == 0x2888`.

## Robinhood constants

Deployment tooling pins the canonical Uniswap v4 PoolManager for Robinhood Chain:

```text
chainId       4663
PoolManager   0x8366a39CC670B4001A1121B8F6A443A643e40951
CREATE2 proxy 0x4e59b44847b379578588920cA78FbF26c0B4956C
```

The DeepState V1 endpoint and routing-fee recipient remain explicit deployment inputs and must be independently verified before broadcast.

## Freeze the build first

CREATE2 commits to the full aggregator init code. The mined address changes if any relevant source, dependency, compiler setting, metadata setting, or constructor argument changes.

Before mining the production salt:

```bash
git status --short
git submodule status
forge --version
FOUNDRY_PROFILE=aggregator_hooks forge clean
FOUNDRY_PROFILE=aggregator_hooks forge build --sizes
FOUNDRY_PROFILE=aggregator_hooks forge test -vv
forge fmt --check
```

Record the repository commit, every submodule revision, Forge version and compiler version. Mine and deploy from the **same frozen checkout**.

The broadcast examples below omit signer-specific flags. Supply an authorized Foundry signer (for example `--account`, a hardware-wallet option, or `--private-key`) when broadcasting.

## 1. Deploy the Planner

Required:

```bash
export RPC_URL=<robinhood-rpc>
export DEEPSTATE=<verified-deepstate-v1-address>
```

Dry run:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge script \
  script/DeployDeepStatePlanner.s.sol:DeployDeepStatePlanner \
  --rpc-url "$RPC_URL" -vv
```

Broadcast:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge script \
  script/DeployDeepStatePlanner.s.sol:DeployDeepStatePlanner \
  --rpc-url "$RPC_URL" --broadcast -vv
```

Record the resulting `Planner` address and independently verify `planner.deepstate()` equals the intended DeepState V1 endpoint.

## 2. Mine the Aggregator address

Set the immutable constructor inputs exactly as they will be used for deployment:

```bash
export PLANNER=<deployed-planner>
export ROUTING_FEE_RECIPIENT=<fee-recipient>
```

The production miner is Robinhood-specific: it pins the canonical PoolManager and canonical CREATE2 proxy above rather than accepting deployment-time overrides.

Run:

```bash
./script/mine_deepstate_hook.sh
```

Record both values printed by the successful window:

```text
Hook address: 0x...
Salt (bytes32): 0x...
```

Do not rebuild, update dependencies, change compiler settings, or change constructor inputs after mining.

## 3. Deterministically deploy the Aggregator

Export the exact mining result:

```bash
export EXPECTED_HOOK=<mined-hook-address>
export HOOK_SALT=<mined-bytes32-salt>

# Explicitly confirm that this deployment is intended to use the proposed D1 ID.
export CONFIRM_D1=true
```

Dry run first:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge script \
  script/DeployDeepStateAggregator.s.sol:DeployDeepStateAggregator \
  --rpc-url "$RPC_URL" -vv
```

Then broadcast:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge script \
  script/DeployDeepStateAggregator.s.sol:DeployDeepStateAggregator \
  --rpc-url "$RPC_URL" --broadcast -vv
```

The script fails closed unless:

- the chain ID is exactly Robinhood `4663`;
- `CONFIRM_D1=true` was explicitly supplied for a deployment using the proposed `D1` ID;
- PoolManager, Planner, DeepState and CREATE2 proxy contain code;
- the predicted CREATE2 address exactly equals `EXPECTED_HOOK`;
- its first byte is the proposed `0xD1` ID;
- its low 14 bits equal the required hook flags;
- the target address has no code before deployment;
- bytecode exists at the expected address after deployment;
- deployed `poolManager`, `planner`, `deepstate` and `routingFeeRecipient` bindings exactly match the intended values.

## 4. Independent post-deployment verification

```bash
export HOOK=<deployed-hook>

FOUNDRY_PROFILE=aggregator_hooks forge script \
  script/VerifyDeepStateDeployment.s.sol:VerifyDeepStateDeployment \
  --rpc-url "$RPC_URL" -vv
```

Keep the verification output with the deployment transaction hashes and the frozen commit/submodule manifest.

## 5. Initialize v4 shell pools

Only after deployment verification should v4 pools be initialized. Each supported DeepState pair must use:

```text
fee         = 0
tickSpacing = 1
currency0   = lower token address
currency1   = higher token address
```

`DeepStateAggregator._beforeInitialize` checks that the corresponding current DeepState book is already initialized. The hook rejects native currency and v4 LP liquidity.

Pool initialization is intentionally kept separate from contract deployment so each pair can be verified independently before admission.
