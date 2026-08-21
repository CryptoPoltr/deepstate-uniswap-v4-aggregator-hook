# DeepState Aggregator Hook

**DeepState** is a fully onchain order-book DEX created by **Joseph DeLong, former CTO of SushiSwap**. Its matching engine keeps resting orders and executes trades directly in smart contracts. The deployment targeted by this repository is DeepState V1 on Robinhood Chain.

**DeepState Aggregator Hook** exposes DeepState order-book liquidity through the Uniswap v4 Aggregator Hook interface. A Uniswap v4 pool provides the routing and accounting surface, while price discovery and external-liquidity execution are performed against the corresponding DeepState book.

The integration does not duplicate maker liquidity or require LP capital in Uniswap v4. Maker liquidity remains in DeepState, and one singleton hook deployment can serve multiple supported token pairs.

### DeepState links

- Website: <https://deepstate.sh/>
- X / Twitter: <https://x.com/deepstatesh>
- Whitepaper: <https://github.com/Deepstate-Protocol/whitepaper>
- Contracts: <https://github.com/Deepstate-Protocol/deepstate-contracts>

## How it works

```text
Uniswap router / swapper
        |
        v
   PoolManager.swap
        |
        v
 DeepStateAggregator
        |
        +------ quote ------> DeepStatePlanner
        |                         |
        |                         v
        |                   DeepState book
        |
        +---- execution ----> DeepState V1
                                  |
                                  v
                         fillWithIntegratorFee
                                  |
                                  v
                         verified token deltas
                                  |
                                  v
                         PoolManager settlement
```

For each supported pair:

1. A Uniswap v4 pool is initialized with the singleton `DeepStateAggregator`.
2. The pair must already have an initialized DeepState book.
3. `quote()` asks `DeepStatePlanner` to build a read-only plan from the live order book.
4. During the actual swap, the Aggregator builds the plan again from current DeepState state.
5. The Aggregator takes the required input from `PoolManager`, executes a DeepState fill-or-kill order, and verifies the actual ERC20 balance changes.
6. The resulting output is settled back to `PoolManager`.
7. `BaseAggregatorHook` converts the result into the v4 swap delta and applies any configured Uniswap aggregator protocol fee.

An earlier quote is never trusted as execution state.

## Contracts

- **`DeepStateAggregator.sol`** — singleton Uniswap v4 Aggregator Hook. Handles pool admission, quote bridging, DeepState execution, settlement verification, and the routing-fee recipient.
- **`DeepStatePlanner.sol`** — immutable read-only planner that converts live DeepState order-book state into executable exact-input or exact-output plans.
- **`IDeepStateV1.sol`** — minimal DeepState V1 ABI used by the integration.
- **`IDeepStatePlanner.sol`** — planner interface and `Plan` definition.
- **`DeepStateConstants.sol`** — shared fee and basis-point constants.

More detail is available in [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

## Supported pools

A v4 pool is accepted only when:

- both currencies are ERC20 tokens;
- native ETH is not used;
- `PoolKey.fee == 0`;
- `PoolKey.tickSpacing == 1`;
- the ordered token pair maps to an initialized DeepState book;
- the pool uses this singleton hook.

Pool initialization is intentionally permissionless; the hook does not maintain a separate registrar or allowlist.

`PoolKey.fee == 0` means the v4 pool has **zero LP fee**. It does not imply zero total user fees, because DeepState fees and the Uniswap aggregator protocol fee are separate layers.

The initial `sqrtPriceX96` is v4 pool metadata and does not participate in DeepState quoting or execution. A market-representative value is recommended for consistent pool metadata.

`BaseAggregatorHook` rejects v4 liquidity additions, so executable maker liquidity remains in DeepState.

## Singleton model

One `DeepStateAggregator` deployment can serve multiple DeepState pairs; there is no per-pair factory.

This matches the Uniswap aggregator-hook convention for integrations with a deterministic 1:1 mapping from a v4 `PoolKey` to the external liquidity source: use a singleton and no factory.

Registered pools are available through the inherited `AggregatorPoolRegistered` event and the hook's pool mapping. The standalone build also retains the existing enumeration getters for compatibility.

## Swap modes

Both directions support:

- **exact input** — the v4 input amount is fixed and the hook returns the resulting output;
- **exact output** — the requested v4 output is fixed and the Planner determines the required DeepState input.

The Planner is called again inside `_conductSwap()`, immediately before execution. Order-book, epoch, or fee changes between an off-chain quote and the transaction therefore cause the transaction to use a fresh plan rather than stale quote state.

DeepState execution uses fill-or-kill semantics and does not intentionally leave a resting taker order.

Small integer-rounding residuals can remain in the hook in narrowly bounded cases. They are excluded from later swap accounting by before/after balance-delta measurement. See [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md).

## Fee model

There are three independent fee layers:

| Layer | Where it is applied | Notes |
| --- | --- | --- |
| DeepState protocol fee | DeepState quote/execution | Read from DeepState `feeConfig()` and included by the Planner |
| DeepState integrator fee | DeepState `fillWithIntegratorFee()` | Fixed at **10 bps (0.10%)** and paid to `routingFeeRecipient` |
| Uniswap aggregator protocol fee | `BaseAggregatorHook` | Applied on top of the raw external-liquidity quote when configured |

`routingFeeRecipient` may update the recipient address through `setRoutingFeeRecipient`. This authority does not control pool registration or swap execution.

The test suite includes non-zero Uniswap protocol-fee E2E execution for exact-input and exact-output swaps in both directions.

## Repository layout

```text
src/
└── aggregator-hooks/
    └── implementations/
        └── DeepState/
            ├── DeepStateAggregator.sol
            ├── DeepStatePlanner.sol
            ├── interfaces/
            │   ├── IDeepStatePlanner.sol
            │   └── IDeepStateV1.sol
            └── libraries/
                └── DeepStateConstants.sol

test/
└── aggregator-hooks/
    └── DeepState/
        ├── DeepStateAggregator.t.sol
        ├── DeepStateAggregator.fuzz.t.sol
        ├── DeepStatePlanner.t.sol
        ├── DeepStatePlanner.fuzz.t.sol
        ├── DeepStateRobinhood.fork.t.sol
        ├── DeepStateUSDT.fork.t.sol
        ├── helpers/
        └── mocks/

docs/
├── ARCHITECTURE.md
├── SECURITY.md
└── V12_AUDIT.md

audits/
├── README.md
└── V12_RAW_EXPORT.md
```

## Build and test

The project uses pinned Foundry dependencies under `lib/`. Production releases should retain the exact tested dependency revisions rather than build from moving `main` branches.

Expected dependency paths are defined in `remappings.txt` and include Uniswap v4 core/periphery, `v4-hooks-public`, Uniswap protocol-fees, OpenZeppelin Contracts, `forge-std`, and DeepState contracts. When publishing the repository, preserve the exact dependency pins from the tested checkout.

The local differential/fuzz tests deploy the real DeepState engine from a separate artifact:

```bash
FOUNDRY_PROFILE=deepstate_artifact forge build \
  lib/deepstate-contracts/src/DeepstateV1.sol
```

Build the Aggregator Hook with the Uniswap-style profile:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge build --sizes
```

Run the aggregator suite:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge test \
  --match-path "test/aggregator-hooks/*" -vv
```

Run the complete repository suite:

```bash
FOUNDRY_PROFILE=aggregator_hooks forge test -vv
```

Check formatting:

```bash
forge fmt --check
```

### Fork tests

Robinhood Chain / DeepState:

```text
FORK_RPC_URL_4663=
FORK_BLOCK_NUMBER_4663=0
```

Ethereum mainnet / USDT compatibility:

```text
FORK_RPC_URL_1=
FORK_BLOCK_NUMBER_1=0
```

A block number of `0` uses the latest available block. Pin explicit block numbers for reproducible CI or release verification.

### Coverage and static analysis

Before an upstream contribution, run the coverage and testing requirements documented by Uniswap for aggregator hooks.

Slither is configured to analyze production sources while filtering dependencies, tests, and scripts:

```bash
FOUNDRY_PROFILE=aggregator_hooks slither . \
  --config-file slither.config.json \
  --json slither.json
```

## Security review

V12 performed a **Full audit** of repository commit `b8f219a` (`main`). The public report covers the repository `src` scope (899 LoC) and identifies **one Medium-risk finding**, **F-244822 — `Bound aggregate quote to the settlement domain`**.

**Official V12 report:** <https://v12.sh/runs/6851/public>

F-244822 showed that the zero-to-one Planner could accumulate multiple individually settleable resting BIDs into a gross quote above canonical DeepState's signed `int256` settlement domain. The V12 PoC reproduced this on the zero-to-one exact-input path using the real `DeepStatePlanner` and canonical `DeepstateV1`; the resulting plan reverted during DeepState settlement with `DeltaOverflow`. V12 recommended enforcing the signed settlement bound on both zero-to-one planning branches before returning a plan.

The repository now contains that remediation: `DeepStatePlanner` rejects `grossQuote` / `grossQuoteOut > int256.max` for zero-to-one plans, and a regression test reproduces the exact-input over-domain condition against the real DeepState engine and expects `AmountTooLarge`. The full project test suite was rerun successfully after the change.

The audited commit is therefore the **pre-remediation** baseline; the current code is the post-audit version containing the fix. No other findings are listed in the public V12 report. A raw review export supplied during development also contained additional candidate entries marked `Invalid`; those are retained only for traceability and are not presented as findings from the public report.

See [`docs/V12_AUDIT.md`](./docs/V12_AUDIT.md) for the exact audit/remediation record, [`audits/README.md`](./audits/README.md) for report artifacts, and [`docs/SECURITY.md`](./docs/SECURITY.md) for the resulting security invariant and trust boundaries.

## Deployment

1. Select the canonical DeepState V1 deployment for the target chain.
2. Deploy `DeepStatePlanner(deepstate)`.
3. Mine a valid Uniswap v4 hook address for `DeepStateAggregator` with the required hook permission bits.
4. Deploy `DeepStateAggregator(poolManager, planner, routingFeeRecipient)` at the mined address.
5. Initialize v4 pools for supported DeepState pairs with `fee = 0` and `tickSpacing = 1`.

The hook permissions inherited from `BaseAggregatorHook` are:

- `beforeInitialize`;
- `beforeSwap`;
- `beforeSwapReturnDelta`;
- `beforeAddLiquidity` (used to reject v4 LP liquidity).

### Aggregator Hook ID

The public `v4-hooks-public` aggregator convention uses recognizable address prefixes so routing software can identify the external liquidity source. Adding a new protocol also requires updating the upstream mining flow.

DeepState does not currently have an assigned ID in the upstream table. An upstream/production address intended to follow that convention should use an identifier accepted by the Uniswap maintainers rather than an invented prefix.

## Security assumptions

The integration is designed around standard ERC20 settlement semantics and the behavior of the pinned DeepState V1 deployment.

Important properties include live in-transaction re-planning, fill-or-kill execution, verification of actual token balance deltas, immutable DeepState/Planner references, disabled v4 LP liquidity, and rejection of native ETH.

The main accepted availability limitation is on-chain order-book traversal: a sufficiently fragmented book can become too expensive to route through before useful liquidity is reached.

See [`docs/SECURITY.md`](./docs/SECURITY.md) for the detailed trust boundaries, token assumptions, accounting invariants, and accepted limitations.

## Upstream integration

The repository layout intentionally mirrors `v4-hooks-public`. A direct upstream contribution still requires repository-level integration, including:

- adding/pinning the DeepState dependency or an accepted minimal interface/math surface;
- switching standalone remapped imports to the upstream-relative form where required;
- adding DeepState to the upstream Aggregator Hooks documentation;
- updating the upstream hook-mining flow with the maintainer-assigned identifier;
- passing the upstream formatter, coverage, fork, fuzz, USDT, static-analysis, and CI requirements.

The implementation is already a singleton and intentionally has no factory.

## References

- DeepState website: <https://deepstate.sh/>
- DeepState X / Twitter: <https://x.com/deepstatesh>
- DeepState whitepaper: <https://github.com/Deepstate-Protocol/whitepaper>
- DeepState contracts: <https://github.com/Deepstate-Protocol/deepstate-contracts>
- Background on DeepState and Joseph DeLong: <https://thedefiant.io/news/defi/ex-sushi-cto-joseph-delong-to-launch-order-book-dex-on-robinhood-chain>
- V12 public audit report: <https://v12.sh/runs/6851/public>
- Uniswap `v4-hooks-public` Aggregator Hooks: <https://github.com/Uniswap/v4-hooks-public/blob/main/src/aggregator-hooks/README.md>
- Uniswap Aggregator Hook testing requirements: <https://github.com/Uniswap/v4-hooks-public/blob/main/test/aggregator-hooks/README.md>
- Uniswap v4 core: <https://github.com/Uniswap/v4-core>
- Uniswap v4 periphery: <https://github.com/Uniswap/v4-periphery>

## License

MIT. See [`LICENSE`](./LICENSE).
