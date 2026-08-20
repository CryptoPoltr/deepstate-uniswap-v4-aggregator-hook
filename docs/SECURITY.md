# DeepState Aggregator Hook Security Model

This document records the intended trust boundaries and accepted limitations of the DeepState Aggregator Hook. It is not a third-party audit report.

## Trust boundaries

The integration assumes correct behavior from the pinned deployments/libraries it composes with:

- Uniswap v4 `PoolManager` and the inherited `BaseAggregatorHook` accounting model;
- the configured DeepState V1 deployment;
- the immutable `DeepStatePlanner`;
- standard ERC20 transfer/allowance behavior for admitted assets.

The hook does not attempt to make arbitrary hostile token implementations safe.

## Core execution properties

### Live re-planning

A quote is advisory only. The execution path calls the Planner again using current DeepState state immediately before the fill.

Changes to order-book state, book epoch, or fee configuration between quote and execution therefore do not cause a cached plan to be trusted.

### Fill-or-kill execution

DeepState fills are submitted with:

```text
noRest     = true
fillOrKill = true
```

The integration does not intentionally leave taker orders resting on the external book.

### Physical balance verification

The hook verifies the actual input consumed and output received from DeepState against the freshly constructed plan.

A mismatch reverts the entire v4 swap.

### PoolManager settlement

The Aggregator uses `PoolManager.take()` and settlement operations through the inherited aggregator-hook flow. Uniswap v4's transient accounting must return to a balanced state before the surrounding unlock completes.

### Immutable external execution target

The DeepState address and Planner are immutable after deployment.

The mutable `routingFeeRecipient` controls only the destination of the fixed DeepState integrator fee; it does not control pool admission or swap execution.

## Token model

The integration is intended for standard ERC20 assets compatible with DeepState settlement.

It does not provide a general safety guarantee for:

- fee-on-transfer tokens;
- rebasing tokens whose balances can change asynchronously during settlement;
- malicious callback/reentrant token implementations;
- native ETH.

USDT-style allowance behavior is handled with `SafeERC20.forceApprove` and is covered by the repository's mainnet USDT fork test.

## Allowances

When a pair is admitted, the Aggregator gives the immutable DeepState deployment a maximum allowance for each relevant ERC20.

This avoids per-swap approval mutations.

DeepState's fill path pulls taker input from its caller, so the allowance is used when the Aggregator itself invokes the DeepState fill.

Changing this model to arbitrary or upgradeable DeepState targets would require a new security review.

## Residual balances

Integer representability can produce small, bounded residual balances in the hook.

Current-swap accounting is based on balance differences rather than absolute balances, preventing existing dust from being attributed to a later swap.

The supported residual cases and limits are documented in [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Permissionless pool initialization

Pool admission is permissionless when the `PoolKey` satisfies the hook constraints and the token pair already has an initialized DeepState book.

The initializer can choose the v4 initial `sqrtPriceX96`. That value does not drive DeepState price discovery or execution.

Applications that display v4 pool metadata independently of the external-liquidity quote should not assume the shell price is an execution oracle.

## Planner availability

The Planner performs on-chain reads of DeepState's radix tree.

Execution traversal has a bounded scan ceiling, but highly fragmented books can still become too expensive to route within practical transaction gas limits.

This is an accepted availability limitation. It does not introduce a fallback that bypasses the plan or balance checks.

## External fee/configuration changes

DeepState fee state is read when planning and the swap plans again inside the transaction.

If external behavior changes in a way that makes actual token deltas disagree with the plan, the Aggregator's post-fill balance checks revert the transaction.

## Security testing

The repository includes:

- Aggregator and Planner unit tests;
- fuzz/differential tests against the real DeepState engine;
- exact-input and exact-output tests in both directions;
- non-zero Uniswap protocol-fee E2E tests;
- Robinhood Chain fork tests against live DeepState state;
- Ethereum mainnet USDT compatibility testing;
- static analysis with Slither.

These checks are development evidence, not a substitute for independent review.

## Accepted limitations

The current design intentionally accepts:

- standard-ERC20-only settlement assumptions;
- dependency on DeepState V1's matching/tree/settlement invariants;
- permissionless v4 shell initialization;
- bounded rounding dust;
- gas/liveness limits on adversarially fragmented books;
- a mutable routing-fee recipient controlled by the current recipient.

Any change that widens these trust boundaries should be treated as a security-sensitive design change.
