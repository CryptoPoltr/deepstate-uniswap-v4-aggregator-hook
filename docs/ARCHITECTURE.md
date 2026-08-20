# DeepState Aggregator Hook Architecture

This document describes the execution and planning details behind the DeepState Aggregator Hook. The main [`README.md`](../README.md) is intentionally shorter and integration-focused.

## Components

### `DeepStateAggregator`

The Aggregator is the Uniswap v4-facing singleton. It:

- admits compatible v4 pools;
- bridges `quote()` calls to the Planner;
- rebuilds plans at execution time;
- moves tokens between `PoolManager` and DeepState;
- executes `fillWithIntegratorFee()`;
- verifies the actual ERC20 balance changes;
- settles the result to `PoolManager`.

The DeepState contract and Planner references are immutable after deployment.

### `DeepStatePlanner`

The Planner is read-only. It converts the live DeepState order-book state into a `Plan` containing the information required to execute a fill-or-kill taker order.

It reproduces the relevant DeepState behavior for:

- book and epoch resolution;
- ASK/BID traversal;
- exact-input and exact-output;
- DeepState protocol fee accounting;
- integrator-fee accounting;
- integer rounding;
- partial-leaf calculation;
- executable limit tick and base quantity.

## Pool and book mapping

A supported v4 pool is a zero-LP-fee routing surface over an existing DeepState token pair.

The hook requires:

```text
ERC20 / ERC20
PoolKey.fee      = 0
PoolKey.tickSpacing = 1
```

The pair must already resolve to an initialized DeepState book.

The v4 pool's initial `sqrtPriceX96` does not participate in DeepState price discovery or taker execution.

## Quote and execution lifecycle

The public quote path is:

```text
quote()
  -> planner.plan(...)
  -> validate plan
  -> return raw unspecified amount
```

The execution path deliberately plans again:

```text
beforeSwap
  -> _conductSwap
      -> planner.plan(...)       // fresh state
      -> validate plan
      -> PoolManager.take(...)
      -> DeepState fill
      -> verify physical balances
      -> PoolManager settlement
  -> BaseAggregatorHook delta accounting
```

The transaction therefore does not execute a plan cached from an earlier quote.

## Exact input

For `amountSpecified < 0`, the v4 input amount is fixed.

The Planner determines:

- executable DeepState base quantity;
- limit tick;
- actual DeepState input;
- expected DeepState output.

The Aggregator takes the full specified input from `PoolManager`. DeepState normally consumes that amount, except for the explicitly bounded token1-to-token0 representability case described below.

## Exact output

For `amountSpecified > 0`, the requested v4 output is fixed.

The Planner chooses an executable DeepState quantity that produces at least the requested output. Because DeepState works in discrete base units, the raw output can be slightly larger than requested.

The Aggregator settles exactly the requested v4 output. Any allowed surplus remains as inert hook dust and is not credited to a later swap.

The plan validation also preserves enough signed-int128 headroom for the maximum supported Uniswap aggregator protocol fee.

## Settlement verification

The Aggregator snapshots its token balances around the DeepState fill.

Conceptually:

```text
availableInput = inputBefore + amountTakenFromPoolManager

actualDeepStateInput  = availableInput - inputAfter
actualDeepStateOutput = outputAfter - outputBefore
```

Execution reverts unless:

```text
actualDeepStateInput  == plan.deepStateInput
actualDeepStateOutput == plan.amountOut
```

It also rejects impossible balance movement such as:

```text
inputAfter  > availableInput
outputAfter < outputBefore
```

This makes planner/execution disagreement fail closed.

Because the check is based on before/after deltas rather than absolute balances, pre-existing hook dust is excluded from current-swap accounting.

## DeepState fill semantics

Execution uses:

```text
noRest     = true
fillOrKill = true
```

The taker order is therefore not intended to rest on DeepState. If the planned quantity cannot be fully executed under the supplied limit, the DeepState fill reverts.

The integration uses `fillWithIntegratorFee()` with a fixed 10 bps integrator fee.

## Rounding and residual balances

DeepState quantities are expressed in token0/base units and use exact integer arithmetic.

Two bounded residual cases are intentionally supported.

### Token1 -> token0 exact input

A quote-token budget can fall between representable base quantities. If consuming one additional base unit would exceed the fixed input budget, a small amount of input may remain in the hook.

The Aggregator permits this only for token1-to-token0 exact-input execution and limits it to 1 bp of the specified input.

### Exact output

A discrete base quantity can produce slightly more output than requested.

The Aggregator requires the raw DeepState output to meet the requested amount and limits surplus to 1 bp. Only the requested amount is settled to `PoolManager`.

## Fee layers

The execution model contains three separate fee layers.

### DeepState protocol fee

`DeepStatePlanner` reads DeepState's current `feeConfig()` and incorporates the protocol fee into its expected net output/input calculations.

### DeepState integrator fee

Every Aggregator execution passes:

```text
bps = 10
recipient = routingFeeRecipient
```

to `fillWithIntegratorFee()`.

### Uniswap aggregator protocol fee

`BaseAggregatorHook` can apply a separate Uniswap protocol fee after the raw external-liquidity quote.

For exact input, that fee is taken from the raw output side.

For exact output, the raw required input is grossed up so the user-facing exact output remains fixed.

The repository includes non-zero-fee E2E tests for both directions and both amount modes.

## Planner traversal

DeepState stores order-book state in a radix-tree representation.

The Planner:

- derives the canonical pool/book IDs;
- follows live branch nodes where child information is required;
- collapses safe aggregate subtrees without expanding every contained order;
- preserves the required directional rounding behavior;
- computes partial-leaf fills with closed-form inverse arithmetic.

Execution traversal uses:

```solidity
MAX_SCAN_NODES = 4096;
```

This is a hard safety ceiling, not a guarantee that a transaction can afford 4096 external tree reads within every block gas limit.

A highly fragmented book can therefore make a route unavailable before all economically executable liquidity is reached.

## `pseudoTotalValueLocked()`

`pseudoTotalValueLocked()` exists as a routing heuristic rather than a custody balance.

The ASK/base side can use safe aggregate subtree quantities. The BID/quote side may return a conservative lower bound when its scan ceiling is reached.

Consumers should treat this value as routing metadata rather than a guarantee of immediately executable volume.

## Singleton isolation

One hook serves multiple token pairs.

Per-swap balance accounting is isolated through token-specific before/after snapshots. Existing residual balances for a token are part of the baseline and are not counted as output or spendable input for a later route.

Each admitted token receives a maximum allowance to the immutable DeepState deployment; DeepState pulls taker input from the calling Aggregator during fill execution.
