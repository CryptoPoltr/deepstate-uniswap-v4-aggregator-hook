# Audited by [V12](https://v12.sh/)
The only autonomous auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.
# One-Step Handoff Can Strand Fee Authority
**#244807**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol`
#### Lines 219-225 — _The current recipient is the sole caller authorized to replace the role, but any nonzero, non-self address is stored immediately and no successor acceptance is required._

```
    function setRoutingFeeRecipient(address newRecipient) external {
        if (msg.sender != routingFeeRecipient) revert UnauthorizedRoutingFeeRecipient();
        if (newRecipient == address(0) || newRecipient == address(this)) revert InvalidRoutingFeeRecipient();

        address previousRecipient = routingFeeRecipient;
        routingFeeRecipient = newRecipient;
        emit RoutingFeeRecipientChanged(previousRecipient, newRecipient);
```
## Description

`setRoutingFeeRecipient` performs a one-step replacement after checking only that the caller is the current recipient and that `newRecipient` is nonzero and not the aggregator. It does not require the successor to accept the role, to be callable, or to implement any handoff interface. A current recipient can therefore set the role to an unusable contract or precompile address, such as an address whose code has no path to call `setRoutingFeeRecipient`; the state then permanently records that address. DeepState uses the recorded address only as the ERC20 transfer destination for the 10 bps fee, so the fee transfer can continue while no future caller can satisfy the authorization check to rotate the role. This is distinct from the documented mutability of the role: the defect is that an accidental or malicious one-step successor can irreversibly strand the authority.
## Root cause

The role handoff stores an arbitrary successor immediately without an explicit successor acceptance step or a callable-recipient invariant. The authorization check at `DeepStateAggregator.sol:220` consequently depends on a destination that may be unable to originate the required follow-up call.
## Impact

The routing-fee recipient can become permanently unchangeable, preventing recovery or rotation of fee authority and destination. For example, selecting a precompile or a contract without an outbound call path leaves future calls to `setRoutingFeeRecipient` unable to originate from the stored address, while subsequent fills continue sending integrator fees to it.

---

# No confirmed U3 vulnerability
**#244808**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol` (2 locations)
#### Lines 133-145 — _Quote admission, planner delegation, plan validation, and raw-side selection._

```
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolTokens memory pair = poolIdToTokens[poolId];
        if (pair.token0 == address(0)) revert PoolDoesNotExist();

        IDeepStatePlanner.Plan memory p = planner.plan(pair.token0, pair.token1, zeroToOne, amountSpecified);
        _validatePlan(p, zeroToOne, amountSpecified);
        return amountSpecified < 0 ? p.amountOut : p.amountTake;
    }
```
⋯
#### Lines 228-265 — _Signed amount, representability, exact-output surplus, and rounding-dust validation._

```
    function _validatePlan(IDeepStatePlanner.Plan memory p, bool zeroToOne, int256 amountSpecified) internal view {
        if (amountSpecified == type(int256).min) revert AmountTooLarge();
        if (p.baseQuantity == 0 || p.amountOut == 0) revert InvalidQuotePlan();
        if (p.deepStateInput > p.amountTake) revert InvalidQuotePlan();

        // For exact-input BaseAggregatorHook cancels the entire specified-side core delta.
        if (amountSpecified < 0 && p.amountTake != uint256(-amountSpecified)) revert InvalidQuotePlan();

        uint256 maxV4Amount = uint256(uint128(type(int128).max));
        if (p.amountTake > maxV4Amount || p.amountOut > maxV4Amount) revert AmountTooLarge();

        if (amountSpecified >= 0) {
            // BaseAggregatorHook adds its protocol fee to the exact-output input delta after _conductSwap.
            // For raw input x and fee f (pips), total input is ceil(x * D / (D - f)). Therefore
            // floor(int128.max * (D - f) / D) is the exact largest raw input that remains representable.
            // Use the maximum fee allowed by v4-core so a previously valid quote stays execution-safe even
            // if the protocol fee is raised between quote simulation and transaction execution.
            uint256 maxProtocolFee = uint256(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) * uint256(protocolFeeMultiplier);
            uint256 maxExactOutputTake = Math.mulDiv(
                maxV4Amount, ProtocolFeeLibrary.PIPS_DENOMINATOR - maxProtocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR
            );
            if (p.amountTake > maxExactOutputTake) revert AmountTooLarge();

            uint256 requestedOutput = uint256(amountSpecified);
            if (p.amountOut < requestedOutput) revert InvalidQuotePlan();
            uint256 surplus = p.amountOut - requestedOutput;
            uint256 maximumSurplus =
                Math.mulDiv(requestedOutput, uint256(MAX_ROUNDING_DUST_BPS), DeepStateConstants.BPS);
            if (surplus > maximumSurplus) revert OutputSurplusTooLarge(surplus, requestedOutput);
        }

        uint256 roundingDust = p.amountTake - p.deepStateInput;
        if (roundingDust != 0) {
            // Structural input dust is valid only for DeepState token1->token0 exact-input BID fills.
            if (zeroToOne || amountSpecified >= 0) revert InvalidQuotePlan();
            uint256 maximum = Math.mulDiv(p.amountTake, uint256(MAX_ROUNDING_DUST_BPS), DeepStateConstants.BPS);
            if (roundingDust > maximum) revert RoundingDustTooLarge(roundingDust, p.amountTake);
        }
```
## Description

The reviewed quote and execution flow is internally consistent with the inspected DeepState V1 implementation. `DeepStatePlanner.plan()` derives the active epoch, reads the current fee configuration, traverses the correct bid or ask root, and reproduces DeepState’s directional rounding: bid notionals round up, ask notionals round down, and partial fills use differences between rounded full notionals. `DeepStateAggregator._validatePlan()` rejects zero/minimal requests, enforces the exact-input amount invariant, bounds both v4 deltas, and constrains exact-output surplus and one-for-zero input dust before `_conductSwap()` submits the same epoch, tick, quantity, direction, no-rest, and fill-or-kill order to DeepState. The inspected DeepstateV1 implementation applies protocol and integrator fees independently as `floor(gross * bps / 10_000)`, matching planner `_netAfterFees()`, while BaseAggregatorHook applies the separate v4 fee in pips with the corresponding exact-input subtraction and exact-output gross-up. No confirmed U3 vulnerability survived end-to-end tracing across the requested modes, edge checks, live fee reads, representability bounds, and real DeepState fill semantics.
## Root cause

No confirmed root cause was found in the requested U3 flow. The apparent risk areas—protocol-fee unit conversion, exact-output fee inversion, independent fee-floor non-monotonicity, signed amount boundaries, and FOK representability—are explicitly bounded or handled by the implementation.
## Impact

No unauthorized asset movement, incorrect quote settlement, stale-plan execution, or confirmed availability failure was demonstrated in the requested flow. Inputs that cannot be represented or whose discrete DeepState result exceeds the documented dust/surplus tolerance revert before execution.

---

# No confirmed U3 vulnerability
**#244809**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol` (2 locations)
#### Lines 55-126 — _All four directional exact-input/exact-output planning branches._

```
    function plan(address token0, address token1, bool zeroToOne, int256 amountSpecified)
        external
        view
        override
        returns (Plan memory result)
    {
        if (token0 == address(0) || token0 >= token1) revert InvalidPair();
        if (amountSpecified == 0 || amountSpecified == type(int256).min) revert InvalidAmount();

        uint256 specified = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        if (specified > type(uint160).max) revert AmountTooLarge();

        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
        (, uint16 feeBps) = deepstate.feeConfig();

        result.epoch = epoch;
        bool exactInput = amountSpecified < 0;
        bytes32 book = _bookId(token0, token1, epoch);

        if (zeroToOne) {
            // token0 -> token1: incoming DeepState ASK consumes resting BIDs.
            if (exactInput) {
                (uint256 grossQuote, int32 bidExactInputLastTick) =
                    _quoteExactBase(book, bidRoot, uint160(specified), true);

                result.amountTake = specified;
                result.deepStateInput = specified;
                result.amountOut = _netAfterFees(grossQuote, feeBps);
                result.baseQuantity = uint160(specified);
                result.limitTick = bidExactInputLastTick;
                return result;
            }

            // Exact token1 output. DeepState takes protocol + routing fees from taker output, therefore we find the
            // minimum token0 quantity whose gross bid quote reaches the exact gross-up target.
            (uint160 baseIn, uint256 grossQuoteOut, int32 bidExactOutputLastTick) =
                _baseForNetQuoteOutput(book, bidRoot, specified, feeBps);

            result.amountTake = baseIn;
            result.deepStateInput = baseIn;
            result.amountOut = _netAfterFees(grossQuoteOut, feeBps);
            result.baseQuantity = baseIn;
            result.limitTick = bidExactOutputLastTick;
            return result;
        }

        // token1 -> token0: incoming DeepState BID consumes resting ASKs.
        if (exactInput) {
            // The input domain is quote/token1 but DeepState's order quantity is token0/base.
            // Choose the maximum base quantity whose exact FIFO quote cost is <= specified input.
            (uint160 baseOutGross, uint256 quoteSpent, int32 askExactInputLastTick) =
                _baseForQuoteBudget(book, askRoot, specified);

            result.amountTake = specified;
            result.deepStateInput = quoteSpent;
            result.amountOut = _netAfterFees(baseOutGross, feeBps);
            result.baseQuantity = baseOutGross;
            result.limitTick = askExactInputLastTick;
            return result;
        }

        // Exact token0 output. Gross-up for DeepState's protocol + routing output fees, then price that exact base amount.
        uint160 grossBaseOut = _toUint160(_minimalGrossForNet(specified, feeBps));
        (uint256 quoteIn, int32 askExactOutputLastTick) = _quoteExactBase(book, askRoot, grossBaseOut, false);

        result.amountTake = quoteIn;
        result.deepStateInput = quoteIn;
        result.amountOut = _netAfterFees(grossBaseOut, feeBps);
        result.baseQuantity = grossBaseOut;
        result.limitTick = askExactOutputLastTick;
    }
```
⋯
#### Lines 271-370 — _Exact-output net-fee inversion and fee-dip repair logic._

```
    function _baseForNetQuoteOutput(bytes32 book, bytes32 root, uint256 targetNetQuote, uint16 feeBps)
        internal
        view
        returns (uint160 baseQuantity, uint256 grossQuote, int32 lastTick)
    {
        if (root == bytes32(0) || targetNetQuote == 0) revert InsufficientLiquidity();
        Walker memory walker = _walker(book, root);
        NetQuoteState memory state;
        state.safeGrossTarget = _safeGrossForNet(targetNetQuote, feeBps);
        state.grossTarget = _minimalGrossForNet(targetNetQuote, feeBps);

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint256 fullQuote = _uniformBranchQuote(node, true);
                if (state.grossQuote + fullQuote < state.grossTarget) {
                    uint160 quantity = _quantity(node);
                    state.grossQuote += fullQuote;
                    state.baseTotal += quantity;
                    if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
                    state.lastTick = _price(node);
                    continue;
                }
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                if (_consumeNetQuoteLeaf(state, node, targetNetQuote, feeBps)) {
                    return (uint160(state.baseTotal), state.grossQuote, state.lastTick);
                }
                continue;
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }

        revert InsufficientLiquidity();
    }

    function _consumeNetQuoteLeaf(NetQuoteState memory state, bytes32 node, uint256 targetNetQuote, uint16 feeBps)
        internal
        pure
        returns (bool done)
    {
        uint160 quantity = _quantity(node);
        if (quantity == 0) revert InvalidTree();

        int32 tick = _price(node);
        uint256 fullQuote = _quoteValue(tick, quantity, true);
        uint256 fullGross = state.grossQuote + fullQuote;

        if (fullGross < state.grossTarget) {
            state.grossQuote = fullGross;
            state.baseTotal += quantity;
            if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
            state.lastTick = tick;
            return false;
        }

        uint160 partialFill = _minPartialBidFill(tick, quantity, state.grossTarget - state.grossQuote);
        uint256 candidateGross = state.grossQuote + _partialLeafQuote(tick, quantity, partialFill, true);
        uint256 candidateBase = state.baseTotal + partialFill;
        if (candidateBase == 0 || candidateBase > type(uint160).max) revert AmountTooLarge();

        // Independent fee floors can make net(gross) dip by one raw unit. The globally minimal
        // gross target can therefore be executable while the next raw gross value under-delivers.
        // If the first reachable quote lands on that dip, continue to the monotone-safe combined
        // threshold instead of returning an under-delivering exact-output plan.
        if (_netAfterFees(candidateGross, feeBps) >= targetNetQuote) {
            state.grossQuote = candidateGross;
            state.baseTotal = candidateBase;
            state.lastTick = tick;
            return true;
        }

        if (fullGross < state.safeGrossTarget) {
            state.grossQuote = fullGross;
            state.baseTotal += quantity;
            if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
            state.lastTick = tick;
            // The minimal exact target has already been crossed, but the first reachable
            // gross landed on an independent-floor fee dip. From this point onward only
            // the monotone-safe target is meaningful.
            state.grossTarget = state.safeGrossTarget;
            return false;
        }

        partialFill = _minPartialBidFill(tick, quantity, state.safeGrossTarget - state.grossQuote);
        state.grossQuote += _partialLeafQuote(tick, quantity, partialFill, true);
        state.baseTotal += partialFill;
        if (state.baseTotal == 0 || state.baseTotal > type(uint160).max) revert AmountTooLarge();
        if (_netAfterFees(state.grossQuote, feeBps) < targetNetQuote) revert InsufficientLiquidity();
        state.lastTick = tick;
        return true;
```
## Description

The reviewed quote and execution flow is internally consistent with the inspected DeepState V1 implementation. `DeepStatePlanner.plan()` derives the active epoch, reads the current fee configuration, traverses the correct bid or ask root, and reproduces DeepState’s directional rounding: bid notionals round up, ask notionals round down, and partial fills use differences between rounded full notionals. `DeepStateAggregator._validatePlan()` rejects zero/minimal requests, enforces the exact-input amount invariant, bounds both v4 deltas, and constrains exact-output surplus and one-for-zero input dust before `_conductSwap()` submits the same epoch, tick, quantity, direction, no-rest, and fill-or-kill order to DeepState. The inspected DeepstateV1 implementation applies protocol and integrator fees independently as `floor(gross * bps / 10_000)`, matching planner `_netAfterFees()`, while BaseAggregatorHook applies the separate v4 fee in pips with the corresponding exact-input subtraction and exact-output gross-up. No confirmed U3 vulnerability survived end-to-end tracing across the requested modes, edge checks, live fee reads, representability bounds, and real DeepState fill semantics.
## Root cause

No confirmed root cause was found in the requested U3 flow. The apparent risk areas—protocol-fee unit conversion, exact-output fee inversion, independent fee-floor non-monotonicity, signed amount boundaries, and FOK representability—are explicitly bounded or handled by the implementation.
## Impact

No unauthorized asset movement, incorrect quote settlement, stale-plan execution, or confirmed availability failure was demonstrated in the requested flow. Inputs that cannot be represented or whose discrete DeepState result exceeds the documented dust/surplus tolerance revert before execution.

---

# Untrusted planner can control execution prices
**#244810**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol` (5 locations)
#### Lines 71-80 — _The constructor stores the arbitrary planner reference and derives the execution target from it without validating planner identity or code immutability._

```
    constructor(IPoolManager manager, IDeepStatePlanner planner_, address routingFeeRecipient_)
        BaseAggregatorHook(manager, "DeepStateAggregator v1.0")
    {
        if (routingFeeRecipient_ == address(0) || routingFeeRecipient_ == address(this)) {
            revert InvalidRoutingFeeRecipient();
        }

        planner = planner_;
        deepstate = planner_.deepstate();
        routingFeeRecipient = routingFeeRecipient_;
```
⋯
#### Lines 133-145 — _The quote path returns amounts directly from planner.plan after only local structural validation._

```
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolTokens memory pair = poolIdToTokens[poolId];
        if (pair.token0 == address(0)) revert PoolDoesNotExist();

        IDeepStatePlanner.Plan memory p = planner.plan(pair.token0, pair.token1, zeroToOne, amountSpecified);
        _validatePlan(p, zeroToOne, amountSpecified);
        return amountSpecified < 0 ? p.amountOut : p.amountTake;
    }
```
⋯
#### Lines 156-160 — _The execution path re-plans from the same unverified planner and trusts its returned amountTake._

```
        // Re-plan against the exact in-transaction DeepState state. Execution never trusts an off-chain quote.
        IDeepStatePlanner.Plan memory p =
            planner.plan(pair.token0, pair.token1, params.zeroForOne, params.amountSpecified);
        _validatePlan(p, params.zeroForOne, params.amountSpecified);
        amountTake = p.amountTake;
```
⋯
#### Lines 200-214 — _Planner-selected epoch, packed order, tick, and quantity are submitted directly to DeepState._

```
    /// @dev Executes exactly the incoming order described by the validated plan.
    function _fillDeepState(PoolTokens memory pair, IDeepStatePlanner.Plan memory p, bool zeroToOne) private {
        IDeepStateV1.FillParams memory fillParams = IDeepStateV1.FillParams({
            token0: pair.token0,
            token1: pair.token1,
            epoch: p.epoch,
            order: _packOrder(p.limitTick, p.baseQuantity),
            isBid: !zeroToOne,
            noRest: true,
            fillOrKill: true
        });
        IDeepStateV1.IntegratorFee memory integratorFee =
            IDeepStateV1.IntegratorFee({recipient: routingFeeRecipient, bps: ROUTING_FEE_BPS});

        deepstate.fillWithIntegratorFee(fillParams, integratorFee);
```
⋯
#### Lines 228-265 — _Validation enforces bounds and dust rules but contains no independent price or canonical-book consistency check._

```
    function _validatePlan(IDeepStatePlanner.Plan memory p, bool zeroToOne, int256 amountSpecified) internal view {
        if (amountSpecified == type(int256).min) revert AmountTooLarge();
        if (p.baseQuantity == 0 || p.amountOut == 0) revert InvalidQuotePlan();
        if (p.deepStateInput > p.amountTake) revert InvalidQuotePlan();

        // For exact-input BaseAggregatorHook cancels the entire specified-side core delta.
        if (amountSpecified < 0 && p.amountTake != uint256(-amountSpecified)) revert InvalidQuotePlan();

        uint256 maxV4Amount = uint256(uint128(type(int128).max));
        if (p.amountTake > maxV4Amount || p.amountOut > maxV4Amount) revert AmountTooLarge();

        if (amountSpecified >= 0) {
            // BaseAggregatorHook adds its protocol fee to the exact-output input delta after _conductSwap.
            // For raw input x and fee f (pips), total input is ceil(x * D / (D - f)). Therefore
            // floor(int128.max * (D - f) / D) is the exact largest raw input that remains representable.
            // Use the maximum fee allowed by v4-core so a previously valid quote stays execution-safe even
            // if the protocol fee is raised between quote simulation and transaction execution.
            uint256 maxProtocolFee = uint256(ProtocolFeeLibrary.MAX_PROTOCOL_FEE) * uint256(protocolFeeMultiplier);
            uint256 maxExactOutputTake = Math.mulDiv(
                maxV4Amount, ProtocolFeeLibrary.PIPS_DENOMINATOR - maxProtocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR
            );
            if (p.amountTake > maxExactOutputTake) revert AmountTooLarge();

            uint256 requestedOutput = uint256(amountSpecified);
            if (p.amountOut < requestedOutput) revert InvalidQuotePlan();
            uint256 surplus = p.amountOut - requestedOutput;
            uint256 maximumSurplus =
                Math.mulDiv(requestedOutput, uint256(MAX_ROUNDING_DUST_BPS), DeepStateConstants.BPS);
            if (surplus > maximumSurplus) revert OutputSurplusTooLarge(surplus, requestedOutput);
        }

        uint256 roundingDust = p.amountTake - p.deepStateInput;
        if (roundingDust != 0) {
            // Structural input dust is valid only for DeepState token1->token0 exact-input BID fills.
            if (zeroToOne || amountSpecified >= 0) revert InvalidQuotePlan();
            uint256 maximum = Math.mulDiv(p.amountTake, uint256(MAX_ROUNDING_DUST_BPS), DeepStateConstants.BPS);
            if (roundingDust > maximum) revert RoundingDustTooLarge(roundingDust, p.amountTake);
        }
```
## Description

The constructor accepts any contract implementing `IDeepStatePlanner` and permanently trusts its `plan` results, without checking that it is the canonical planner or that its implementation is immutable. Both `_rawQuote` and `_conductSwap` use that planner, while `_validatePlan` checks only structural bounds, direction, representability, and bounded dust; it does not independently establish that the selected `limitTick`, `baseQuantity`, and amounts represent the best or otherwise authorized DeepState execution. A malicious planner, or a proxy planner upgraded after deployment, can therefore return a structurally valid plan for an adverse price and have `_fillDeepState` submit that plan to the real DeepState engine. The observed token-delta checks still pass when the engine fills the adverse order exactly as specified, so they do not detect the planner-controlled economic deviation.
## Root cause

`DeepStateAggregator` treats an arbitrary constructor-supplied planner as an authenticated price-discovery authority. The only plan validation is syntactic and settlement-oriented; no canonical planner binding or immutable-code guarantee is enforced.
## Impact

Users and routing systems relying on the hook’s quote can be systematically underpaid on exact-input swaps or overcharged on exact-output swaps while the transaction succeeds and all balance-delta checks pass. This requires deployment with a malicious planner or a planner whose implementation can later be upgraded, but the constructor provides no on-chain identity or immutability check to prevent that configuration.

---

# Execution target binding is not authenticated
**#244811**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol` (3 locations)
#### Lines 71-80 — _The constructor derives and stores `deepstate` from an unchecked planner return value._

```
    constructor(IPoolManager manager, IDeepStatePlanner planner_, address routingFeeRecipient_)
        BaseAggregatorHook(manager, "DeepStateAggregator v1.0")
    {
        if (routingFeeRecipient_ == address(0) || routingFeeRecipient_ == address(this)) {
            revert InvalidRoutingFeeRecipient();
        }

        planner = planner_;
        deepstate = planner_.deepstate();
        routingFeeRecipient = routingFeeRecipient_;
```
⋯
#### Lines 118-127 — _Pool admission calls the configured target and then grants it maximum allowances for both tokens._

```
        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        if (deepstate.nextNonce(token0, token1, epoch) == 0) revert DeepStateBookNotInitialized();

        PoolId poolId = key.toId();
        poolIdToTokens[poolId] = PoolTokens({token0: token0, token1: token1});
        _initializedPools.push(key);

        // DeepState pulls taker input from this adapter. forceApprove also supports USDT-style allowance semantics.
        _approveToDeepState(token0);
        _approveToDeepState(token1);
```
⋯
#### Lines 185-197 — _Execution authorizes the configured target to pull input and authenticates only aggregate balance deltas._

```
        _take(takeCurrency, address(this), p.amountTake);
        _fillDeepState(pair, p, zeroToOne);

        uint256 inputAfter = takeCurrency.balanceOfSelf();
        uint256 outputAfter = settleCurrency.balanceOfSelf();
        uint256 availableInput = inputBefore + p.amountTake;
        if (inputAfter > availableInput || outputAfter < outputBefore) revert UnexpectedSwapDelta();

        uint256 actualDeepStateInput = availableInput - inputAfter;
        actualDeepStateOutput = outputAfter - outputBefore;
        if (actualDeepStateInput != p.deepStateInput || actualDeepStateOutput != p.amountOut) {
            revert UnexpectedSwapDelta();
        }
```
## Description

The constructor copies `planner_.deepstate()` into an immutable execution address without checking that the returned address is nonzero, code-bearing, canonical, or non-upgradeable. The inherited constructors do not supply those checks: `BaseHook` validates only hook permission bits, and `ImmutableState` merely stores the supplied manager. A planner can consequently return an EOA, zero address, malicious contract, or upgradeable proxy as the DeepState target; the zero/EOA cases allow deployment but make later pool admission revert when `poolEpoch` is called, while a malicious or later-upgraded target receives the maximum token allowance granted during admission and controls the external fill semantics. Because the adapter validates only that observed balances match the planner’s reported amounts, a compromised target/planner pair can pull the planned taker input and deliver an intentionally inadequate output while satisfying every local check.
## Root cause

The integration authenticates neither the planner-supplied DeepState address nor its implementation topology. It assumes that an immutable address implies immutable, canonical behavior and grants that address maximum ERC20 authority without enforcing the assumption.
## Impact

A bad target binding can permanently strand the deployed hook before any pool can be admitted, or can turn admitted swaps into externally controlled executions that materially misprice user trades. The latter requires an operator to bind a malicious or upgradeable target, but the immutable address alone does not make the target’s code or behavior immutable.

---

# Unvalidated manager can disable the hook
**#244812**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStateAggregator.sol` (2 locations)
#### Lines 71-73 — _The supplied manager is passed to the inherited constructor without a local validity check._

```
    constructor(IPoolManager manager, IDeepStatePlanner planner_, address routingFeeRecipient_)
        BaseAggregatorHook(manager, "DeepStateAggregator v1.0")
    {
```
⋯
#### Lines 102-129 — _A caller recognized only by the stored manager address can register pools and grant DeepState maximum allowances._

```
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            revert NativeCurrencyNotSupported();
        }

        // DeepState's dynamic protocol fee and the fixed routing fee are already part of the raw source quote.
        // Keep the v4 shell LP-fee-free and canonical for this hook.
        if (key.fee != 0 || key.tickSpacing != 1) revert ExternalPoolMismatch();

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        if (deepstate.nextNonce(token0, token1, epoch) == 0) revert DeepStateBookNotInitialized();

        PoolId poolId = key.toId();
        poolIdToTokens[poolId] = PoolTokens({token0: token0, token1: token1});
        _initializedPools.push(key);

        // DeepState pulls taker input from this adapter. forceApprove also supports USDT-style allowance semantics.
        _approveToDeepState(token0);
        _approveToDeepState(token1);

        return super._beforeInitialize(sender, key, sqrtPriceX96);
```
## Description

The constructor passes `manager` into inherited storage without requiring a nonzero, code-bearing, or otherwise valid Uniswap v4 PoolManager address. `BaseHook` only checks that the hook address has the expected permission bits, and `onlyPoolManager` later authorizes calls solely by comparing `msg.sender` with the stored address. A zero manager therefore produces a successfully deployed but unusable hook because no transaction can satisfy `msg.sender == address(0)`; an EOA or arbitrary contract is likewise accepted as the sole callback authority, allowing that address to invoke `_beforeInitialize` directly and trigger pool registration and token approvals even though it is not a PoolManager. The manager reference is immutable, so this deployment failure or false trust boundary cannot be repaired in place.
## Root cause

The constructor assumes the supplied manager is the canonical Uniswap v4 PoolManager and relies on address equality as authentication. No constructor guard verifies nonzero/code-bearing manager semantics or binds the hook to a known PoolManager deployment.
## Impact

A deployment using a zero or nonfunctional manager cannot admit any pool or execute swaps, permanently disabling that hook instance. If an attacker controls an incorrectly configured non-PoolManager address, it can fabricate initialization callbacks and cause unauthorized registration/approval side effects, although this finding is conditional on the deployment using that attacker-controlled manager.

---

# Malformed safe aggregates bypass tree validation
**#244815**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol` (4 locations)
#### Lines 159-192 — _Strict exact-input planning also trusts the safe aggregate shortcut._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint160 quantity = _quantity(node);
                if (quantity <= remaining) {
                    quoteAmount += _uniformBranchQuote(node, restingIsBid);
                    remaining -= quantity;
                    lastTick = _price(node);
                    if (remaining == 0) return (quoteAmount, lastTick);
                    continue;
                }
                // The aggregate correction is exact only for the whole subtree. For a partial FIFO
                // fill, descend; descendants remain aggregate-safe.
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                uint160 quantity = _quantity(node);
                if (quantity == 0) revert InvalidTree();
                uint160 fill = remaining < quantity ? remaining : quantity;
                quoteAmount += _partialLeafQuote(_price(node), quantity, fill, restingIsBid);
                remaining -= fill;
                lastTick = _price(node);
                if (remaining == 0) return (quoteAmount, lastTick);
                continue;
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
```
⋯
#### Lines 416-432 — _ASK TVL consumes safe packed quantity without reading or validating children._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);

            // Every off-right-spine node has exact aggregate quantity even when it spans many ticks.
            if (safe) {
                amount0 += _quantity(node);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount0 += _quantity(node);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, false);
```
⋯
#### Lines 440-457 — _BID TVL consumes nonzero-correction safe aggregates without validating their structure._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                amount1 += _uniformBranchQuote(node, true);
                continue;
            }

            if (walker.scanned >= MAX_SCAN_NODES) break;
            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount1 += _quoteValue(_price(node), _quantity(node), true);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
```
⋯
#### Lines 490-505 — _Safety classification is positional and does not validate the child structure or packed aggregate._

```
    function _pushChildren(Walker memory walker, bytes32 left, bytes32 right, bool parentSafe) internal pure {
        if (walker.sp + 2 > MAX_STACK) revert InvalidTree();

        // Push left then right so right is popped/executed first. If the parent is on the potentially
        // dirty global right spine, only its right child remains unsafe; the left subtree is exact.
        _push(walker, left, true);
        _push(walker, right, parentSafe);
    }

    function _push(Walker memory walker, bytes32 node, bool safe) internal pure {
        uint256 index = walker.sp++;
        walker.stack[index] = node;
        uint256 bit = uint256(1) << index;
        if (safe) walker.safeMask |= bit;
        else walker.safeMask &= ~bit;
    }
```
## Description

The walker encodes safety solely from position in the radix tree: `_pushChildren` marks every left child safe and propagates the parent safety only to the right child. The TVL routines then skip the external child read for safe nodes, and the planner uses a nonzero correction code as sufficient proof that a safe branch is a uniform exact aggregate. DeepState's canonical invariant makes that shortcut valid only when the endpoint preserves clean off-spine branches, valid child structure, aggregate quantities, and correction semantics; this implementation does not validate any of those properties before using the packed word. A noncanonical safe branch with an inflated quantity or forged correction can therefore be valued in O(1) rather than being rejected or expanded, and a malformed ASK correction can underflow/revert while a malformed BID correction can inflate the quote.
## Root cause

Positional `safeMask` state is treated as proof that packed quantity and correction fields are valid, even though that proof depends on external tree and aggregate invariants that the planner never validates.
## Impact

A noncanonical configured endpoint can make pseudo-TVL report false liquidity and can cause planning to return amounts based on an aggregate that does not represent its children. Routing consumers can select the route based on the inflated metadata, while execution using the inconsistent plan becomes unavailable or reverts; the BID path can additionally overstate the routing heuristic.

---

# Duplicate child pointers double-count liquidity
**#244816**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol` (3 locations)
#### Lines 416-432 — _ASK TVL counts each popped node occurrence and has no identity check._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);

            // Every off-right-spine node has exact aggregate quantity even when it spans many ticks.
            if (safe) {
                amount0 += _quantity(node);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount0 += _quantity(node);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, false);
```
⋯
#### Lines 440-458 — _BID TVL likewise counts repeated node occurrences independently._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                amount1 += _uniformBranchQuote(node, true);
                continue;
            }

            if (walker.scanned >= MAX_SCAN_NODES) break;
            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount1 += _quoteValue(_price(node), _quantity(node), true);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }
```
⋯
#### Lines 490-497 — _Child pointers are pushed without duplicate or visited-node validation._

```
    function _pushChildren(Walker memory walker, bytes32 left, bytes32 right, bool parentSafe) internal pure {
        if (walker.sp + 2 > MAX_STACK) revert InvalidTree();

        // Push left then right so right is popped/executed first. If the parent is on the potentially
        // dirty global right spine, only its right child remains unsafe; the left subtree is exact.
        _push(walker, left, true);
        _push(walker, right, parentSafe);
    }
```
## Description

The DFS walker has no visited-node or path-membership tracking. It pushes the raw child pointers returned by `deepstate.tree` and processes every occurrence as independent liquidity, while the documented DeepState invariant requires all reachable node addresses to be distinct. For example, a noncanonical root whose left and right pointers are the same positive-quantity leaf is accepted: right-first traversal counts the leaf once, then the second occurrence is counted again (the left occurrence is marked safe). The same absence of identity validation affects strict planning, which can treat repeated pointers as separate executable quantity instead of rejecting the malformed graph.
## Root cause

The walker validates only zero-versus-nonzero child shape and stack depth; it does not enforce the external tree's node-identity invariant against duplicate child pointers or nodes reachable through multiple paths.
## Impact

Pseudo-TVL can double-count one external order or subtree and expose liquidity that does not exist as distinct resting inventory. Exact-input and exact-output plans can likewise overpromise output or consume repeated logical liquidity, making routes based on the result fail or become unavailable when the external engine cannot execute the duplicated quantity.

---

# Cyclic child pointers exhaust planner traversal
**#244817**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol` (4 locations)
#### Lines 416-432 — _ASK TVL repeatedly expands unsafe children and is bounded only by stack overflow._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);

            // Every off-right-spine node has exact aggregate quantity even when it spans many ticks.
            if (safe) {
                amount0 += _quantity(node);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount0 += _quantity(node);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, false);
```
⋯
#### Lines 440-457 — _BID TVL can spend its scan budget repeatedly reading a cycle._

```
        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                amount1 += _uniformBranchQuote(node, true);
                continue;
            }

            if (walker.scanned >= MAX_SCAN_NODES) break;
            (bytes32 left, bytes32 right) = _tree(walker, node, false);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                amount1 += _quoteValue(_price(node), _quantity(node), true);
                continue;
            }
            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
```
⋯
#### Lines 474-481 — _External child pointers are read without ancestor or visited-node checks._

```
    function _tree(Walker memory walker, bytes32 node, bool strict)
        internal
        view
        returns (bytes32 left, bytes32 right)
    {
        ++walker.scanned;
        if (strict && walker.scanned > MAX_SCAN_NODES) revert ScanLimit();
        return deepstate.tree(walker.book, node);
```
⋯
#### Lines 490-497 — _Child pointers are re-enqueued without cycle detection._

```
    function _pushChildren(Walker memory walker, bytes32 left, bytes32 right, bool parentSafe) internal pure {
        if (walker.sp + 2 > MAX_STACK) revert InvalidTree();

        // Push left then right so right is popped/executed first. If the parent is on the potentially
        // dirty global right spine, only its right child remains unsafe; the left subtree is exact.
        _push(walker, left, true);
        _push(walker, right, parentSafe);
    }
```
## Description

The walker also has no cycle detection, so a right-child pointer that points back to an ancestor is repeatedly re-enqueued as an unsafe node. In the unbounded ASK TVL traversal this does not terminate normally: each expansion consumes one stack slot and adds two, eventually tripping the `MAX_STACK` guard and reverting the entire pseudo-TVL query. Strict planning similarly reverts after the frontier fills, while the non-strict BID TVL path can stop at its scan ceiling only after repeatedly visiting the cycle and may have accumulated repeated safe-side values. DeepState's canonical invariant requires distinct reachable nodes, but the planner does not detect this violation and therefore does not provide a deliberate fail-closed cycle response.
## Root cause

The DFS frontier is bounded but not identity-aware: stack depth is used as the only termination defense, so cyclic child pointers are treated as new tree edges until the stack or scan limit is exhausted.
## Impact

A malformed or corrupted DeepState tree can make ASK pseudo-TVL and all strict planning routes revert, preventing routing for the affected pair. The BID query can spend its bounded read budget revisiting the cycle, reducing the useful liquidity represented by its lower bound and creating a practical availability failure without requiring a large tree.

---

# Validate the immutable DeepState endpoint at deployment
**#244821**
- Severity: Low
- Validity: Invalid
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol` (4 locations)
#### Line 24 — _The endpoint is an immutable dependency._

```
    IDeepStateV1 public immutable override deepstate;
```
⋯
#### Lines 51-53 — _The constructor assigns the supplied endpoint without validation._

```
    constructor(IDeepStateV1 deepstate_) {
        deepstate = deepstate_;
    }
```
⋯
#### Lines 67-69 — _Planning ABI-decodes data from the configured endpoint._

```
        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
        (, uint16 feeBps) = deepstate.feeConfig();
```
⋯
#### Lines 134-147 — _Pseudo-TVL also depends on the same unvalidated endpoint._ — _Pseudo-TVL likewise depends on the configured endpoint._

```
    function pseudoTotalValueLocked(address token0, address token1)
        external
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (token0 == address(0) || token0 >= token1) revert InvalidPair();

        uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
        (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
        bytes32 book = _bookId(token0, token1, epoch);

        amount0 = _askBaseTVL(book, askRoot);
        amount1 = _bidQuoteTVL(book, bidRoot);
```
## Description

`DeepStatePlanner` accepts `deepstate_` in its constructor and stores it as the immutable `deepstate` reference without confirming that the address is nonzero and contains contract code. Consequently, deployment can succeed with `address(0)` or an EOA as the configured endpoint. Both `plan` and `pseudoTotalValueLocked` subsequently call this reference and ABI-decode results from interface methods such as `poolEpoch`, `roots`, and `feeConfig`. A code-less target returns no ABI-encoded implementation data, causing these query paths to revert during decoding. Because `deepstate` is immutable, the misconfigured planner cannot be corrected in place; constructor-time validation of the endpoint is required before assigning it.
## Root cause

The constructor commits `deepstate_` to immutable state without verifying that it is a nonzero address with deployed contract code.
## Impact

A deployment configuration error can leave planner-backed quotes, route construction, and pseudo-TVL metadata unavailable for every applicable pair. Integrations using this planner must redeploy it with a valid endpoint and reconfigure dependent components before those functions can resume.

---

# Bound aggregate quote to the settlement domain
**#244822**
- Severity: Medium
- Validity: Unreviewed
## Source locations
### `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol` (3 locations)
#### Lines 75-99 — _Both zero-to-one branches return quote-derived output without a settlement-domain check._ — _Zero-to-one exact-input and exact-output planning returns aggregate quote-derived output without a signed settlement-domain check._

```
        if (zeroToOne) {
            // token0 -> token1: incoming DeepState ASK consumes resting BIDs.
            if (exactInput) {
                (uint256 grossQuote, int32 bidExactInputLastTick) =
                    _quoteExactBase(book, bidRoot, uint160(specified), true);

                result.amountTake = specified;
                result.deepStateInput = specified;
                result.amountOut = _netAfterFees(grossQuote, feeBps);
                result.baseQuantity = uint160(specified);
                result.limitTick = bidExactInputLastTick;
                return result;
            }

            // Exact token1 output. DeepState takes protocol + routing fees from taker output, therefore we find the
            // minimum token0 quantity whose gross bid quote reaches the exact gross-up target.
            (uint160 baseIn, uint256 grossQuoteOut, int32 bidExactOutputLastTick) =
                _baseForNetQuoteOutput(book, bidRoot, specified, feeBps);

            result.amountTake = baseIn;
            result.deepStateInput = baseIn;
            result.amountOut = _netAfterFees(grossQuoteOut, feeBps);
            result.baseQuantity = baseIn;
            result.limitTick = bidExactOutputLastTick;
            return result;
```
⋯
#### Lines 150-196 — _`_quoteExactBase` cumulatively adds each leaf’s quote as `uint256`._

```
    function _quoteExactBase(bytes32 book, bytes32 root, uint160 baseNeeded, bool restingIsBid)
        internal
        view
        returns (uint256 quoteAmount, int32 lastTick)
    {
        if (root == bytes32(0) || baseNeeded == 0) revert InsufficientLiquidity();
        Walker memory walker = _walker(book, root);
        uint160 remaining = baseNeeded;

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint160 quantity = _quantity(node);
                if (quantity <= remaining) {
                    quoteAmount += _uniformBranchQuote(node, restingIsBid);
                    remaining -= quantity;
                    lastTick = _price(node);
                    if (remaining == 0) return (quoteAmount, lastTick);
                    continue;
                }
                // The aggregate correction is exact only for the whole subtree. For a partial FIFO
                // fill, descend; descendants remain aggregate-safe.
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                uint160 quantity = _quantity(node);
                if (quantity == 0) revert InvalidTree();
                uint160 fill = remaining < quantity ? remaining : quantity;
                quoteAmount += _partialLeafQuote(_price(node), quantity, fill, restingIsBid);
                remaining -= fill;
                lastTick = _price(node);
                if (remaining == 0) return (quoteAmount, lastTick);
                continue;
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }

        revert InsufficientLiquidity();
    }
```
⋯
#### Lines 271-314 — _The zero-to-one exact-output traversal likewise accumulates gross quote as `uint256`._

```
    function _baseForNetQuoteOutput(bytes32 book, bytes32 root, uint256 targetNetQuote, uint16 feeBps)
        internal
        view
        returns (uint160 baseQuantity, uint256 grossQuote, int32 lastTick)
    {
        if (root == bytes32(0) || targetNetQuote == 0) revert InsufficientLiquidity();
        Walker memory walker = _walker(book, root);
        NetQuoteState memory state;
        state.safeGrossTarget = _safeGrossForNet(targetNetQuote, feeBps);
        state.grossTarget = _minimalGrossForNet(targetNetQuote, feeBps);

        while (walker.sp != 0) {
            (bytes32 node, bool safe) = _pop(walker);
            uint32 correction = _correctionCode(node);

            if (safe && correction != 0) {
                uint256 fullQuote = _uniformBranchQuote(node, true);
                if (state.grossQuote + fullQuote < state.grossTarget) {
                    uint160 quantity = _quantity(node);
                    state.grossQuote += fullQuote;
                    state.baseTotal += quantity;
                    if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
                    state.lastTick = _price(node);
                    continue;
                }
                _expand(walker, node, true);
                continue;
            }

            (bytes32 left, bytes32 right) = _tree(walker, node, true);
            if (left == bytes32(0)) {
                if (right != bytes32(0)) revert InvalidTree();
                if (_consumeNetQuoteLeaf(state, node, targetNetQuote, feeBps)) {
                    return (uint160(state.baseTotal), state.grossQuote, state.lastTick);
                }
                continue;
            }

            if (right == bytes32(0)) revert InvalidTree();
            _pushChildren(walker, left, right, safe);
        }

        revert InsufficientLiquidity();
    }
```
## Description

The zero-to-one planner paths can return a quote-derived plan whose cumulative gross quote exceeds the signed settlement range accepted by canonical DeepState. In the exact-input path, `_quoteExactBase` sums multi-leaf quote amounts as `uint256` and the result is passed through `_netAfterFees` without checking the underlying settlement-domain limit. The exact-output path has the same issue because `_baseForNetQuoteOutput` accumulates `state.grossQuote` as `uint256` before returning a plan. Canonical DeepState later converts the aggregate quote into a signed credit and reverts when it exceeds `int256.max`. Consequently, the public planner can report a successful FOK route for individually valid quantities and liquidity that cannot execute as planned.
## Root cause

Cumulative quote accounting in the zero-to-one planning paths uses `uint256` without enforcing canonical DeepState's `int256` signed settlement bound before returning a plan.
## Impact

A direct planner consumer, or an adapter that does not impose an equivalent bound, can receive a route that consistently reverts when submitted to canonical DeepState. This makes sufficiently large otherwise-valid liquidity unavailable through the planner, while the referenced Aggregator fails closed earlier at its narrower signed-delta validation boundary.
## Proof of concept
### Test case

```
// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath32} from "deepstate-contracts/src/libraries/TickMath32.sol";

import {DeepStatePlanner} from "../src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol";
import {IDeepStatePlanner} from "../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStatePlanner.sol";
import {IDeepStateV1} from "../src/aggregator-hooks/implementations/DeepState/interfaces/IDeepStateV1.sol";
import {TestERC20} from "./aggregator-hooks/DeepState/mocks/TestERC20.sol";

interface ICanonicalDeepState is IDeepStateV1 {
    function fill(IDeepStateV1.FillParams calldata params) external payable returns (bytes32 restingOrder);
}

contract Poc is Test {
    uint16 internal constant ROUTING_FEE_BPS = 10;
    uint256 internal constant BPS = 10_000;
    int32 internal constant HIGH_TICK = type(int32).max;
    int32 internal constant NEXT_HIGH_TICK = type(int32).max - 1;

    error DeltaOverflow();

    ICanonicalDeepState internal engine;
    DeepStatePlanner internal planner;
    TestERC20 internal token0;
    TestERC20 internal token1;

    address internal maker = makeAddr("maker");
    address internal taker = makeAddr("taker");
    address internal routingFeeRecipient = makeAddr("routingFeeRecipient");

    function setUp() public {
        engine = ICanonicalDeepState(vm.deployCode("deepstate-out/DeepstateV1.sol/DeepstateV1.json"));
        planner = new DeepStatePlanner(IDeepStateV1(address(engine)));

        TestERC20 a = new TestERC20("Token A", "TKA");
        TestERC20 b = new TestERC20("Token B", "TKB");
        if (address(a) < address(b)) {
            token0 = a;
            token1 = b;
        } else {
            token0 = b;
            token1 = a;
        }

        token0.mint(taker, type(uint160).max);
        token1.mint(maker, type(uint256).max);

        vm.startPrank(maker);
        token0.approve(address(engine), type(uint256).max);
        token1.approve(address(engine), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(taker);
        token0.approve(address(engine), type(uint256).max);
        token1.approve(address(engine), type(uint256).max);
        vm.stopPrank();
    }

    function test_poc_zeroToOnePlannerReturnsPlanThatCanonicalDeepStateCannotSettle() public {
        // Each maker bid is independently placeable because its collateral/quote fits the signed
        // settlement domain enforced by canonical DeepState's _debitDelta during resting insertion.
        uint160 firstQuantity = _maxQuantityWhoseBidQuoteFitsInt256(HIGH_TICK);
        uint160 secondQuantity = _maxQuantityWhoseBidQuoteFitsInt256(NEXT_HIGH_TICK);
        if (uint256(firstQuantity) + uint256(secondQuantity) > type(uint160).max) {
            secondQuantity = type(uint160).max - firstQuantity;
            while (_bidQuote(NEXT_HIGH_TICK, secondQuantity) > uint256(type(int256).max)) {
                --secondQuantity;
            }
        }

        uint256 firstQuote = _bidQuote(HIGH_TICK, firstQuantity);
        uint256 secondQuote = _bidQuote(NEXT_HIGH_TICK, secondQuantity);
        assertLe(firstQuote, uint256(type(int256).max), "first resting bid is individually executable");
        assertLe(secondQuote, uint256(type(int256).max), "second resting bid is individually executable");
        assertGt(firstQuote + secondQuote, uint256(type(int256).max), "aggregate quote exceeds settlement domain");

        bytes32 firstResting = _restBid(HIGH_TICK, firstQuantity);
        bytes32 secondResting = _restBid(NEXT_HIGH_TICK, secondQuantity);
        assertTrue(firstResting != bytes32(0));
        assertTrue(secondResting != bytes32(0));

        uint256 amountIn = uint256(firstQuantity) + uint256(secondQuantity);
        IDeepStatePlanner.Plan memory p = planner.plan(address(token0), address(token1), true, -int256(amountIn));

        assertEq(p.amountTake, amountIn);
        assertEq(p.deepStateInput, amountIn);
        assertEq(p.baseQuantity, uint160(amountIn));
        assertGt(p.amountOut, uint256(type(int256).max), "planner returned an over-signed-domain output");

        // Submitting the returned FOK ask through canonical DeepState reaches _creditDelta(quoteAmount),
        // which reverts before fees because the matched aggregate quote no longer fits int256.
        vm.expectRevert(DeltaOverflow.selector);
        vm.prank(taker);
        engine.fillWithIntegratorFee(
            _fill(p.epoch, _order(p.limitTick, p.baseQuantity), false, true, true),
            IDeepStateV1.IntegratorFee({recipient: routingFeeRecipient, bps: ROUTING_FEE_BPS})
        );
    }

    function _restBid(int32 tick, uint160 quantity) internal returns (bytes32 restingOrder) {
        vm.prank(maker);
        restingOrder = engine.fill(_fill(0, _order(tick, quantity), true, false, false));
    }

    function _fill(uint256 epoch, bytes32 order, bool isBid, bool noRest, bool fillOrKill)
        internal
        view
        returns (IDeepStateV1.FillParams memory params)
    {
        params = IDeepStateV1.FillParams({
            token0: address(token0),
            token1: address(token1),
            epoch: epoch,
            order: order,
            isBid: isBid,
            noRest: noRest,
            fillOrKill: fillOrKill
        });
    }

    function _order(int32 tick, uint160 quantity) internal pure returns (bytes32) {
        return bytes32((uint256(uint32(tick)) << 224) | (uint256(quantity) << 64));
    }

    function _maxQuantityWhoseBidQuoteFitsInt256(int32 tick) internal pure returns (uint160 quantity) {
        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        uint256 candidate = Math.mulDiv(uint256(type(int256).max), denominator, factor);
        if (candidate > type(uint160).max) candidate = type(uint160).max;
        quantity = uint160(candidate);
        while (_bidQuote(tick, quantity) > uint256(type(int256).max)) {
            --quantity;
        }
    }

    function _bidQuote(int32 tick, uint160 quantity) internal pure returns (uint256 quoteAmount) {
        if (quantity == 0) return 0;
        if (tick == 0) return quantity;
        (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
        uint256 denominator = uint256(1) << shift;
        quoteAmount = Math.mulDiv(uint256(quantity), factor, denominator);
        if (mulmod(uint256(quantity), factor, denominator) != 0) ++quoteAmount;
    }
}
```
### Setup script

```
#!/bin/bash
set -e

# Standalone PoC reproduction. Run from the repository root of a checkout at
# the audited commit, with the language toolchain installed.

# Place the downloaded PoC files at these paths before running:
#   test/Poc.t.sol

# install dependencies
mkdir -p 'lib' && rm -rf 'lib/deepstate-contracts' && git clone --depth 1 'https://github.com/Deepstate-Protocol/deepstate-contracts.git' 'lib/deepstate-contracts'
mkdir -p 'lib' && rm -rf 'lib/forge-std' && git clone --depth 1 'https://github.com/foundry-rs/forge-std.git' 'lib/forge-std'
mkdir -p 'lib' && rm -rf 'lib/openzeppelin-contracts' && git clone --depth 1 'https://github.com/OpenZeppelin/openzeppelin-contracts.git' 'lib/openzeppelin-contracts'
mkdir -p 'lib' && rm -rf 'lib/protocol-fees' && git clone --depth 1 'https://github.com/Uniswap/protocol-fees.git' 'lib/protocol-fees'
mkdir -p 'lib' && rm -rf 'lib/v4-core' && git clone --depth 1 'https://github.com/Uniswap/v4-core.git' 'lib/v4-core'
mkdir -p 'lib' && rm -rf 'lib/v4-hooks-public' && git clone --depth 1 'https://github.com/Uniswap/v4-hooks-public.git' 'lib/v4-hooks-public'
mkdir -p 'lib' && rm -rf 'lib/v4-periphery' && git clone --depth 1 'https://github.com/Uniswap/v4-periphery.git' 'lib/v4-periphery'

# build and run
forge build
FOUNDRY_PROFILE=deepstate_artifact FOUNDRY_VIA_IR=true forge build lib/deepstate-contracts/src/DeepstateV1.sol && forge test --match-path test/Poc.t.sol -vv
```
### Output

```
[output truncated: 955 lines & 45.650390625 KB skipped]
Compiler run successful!
Compiling 80 files with Solc 0.8.28
Solc 0.8.28 finished in 1.58s
Compiler run successful!

Ran 1 test for test/Poc.t.sol:Poc
[PASS] test_poc_zeroToOnePlannerReturnsPlanThatCanonicalDeepStateCannotSettle() (gas: 259672)
Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 2.13ms (424.64µs CPU time)

Ran 1 test suite in 9.06ms (2.13ms CPU time): 1 tests passed, 0 failed, 0 skipped (1 total tests)
```
### Considerations

PoC passed with `run_poc` using strategy `unit:test-poc-t-sol` and command `FOUNDRY_PROFILE=deepstate_artifact FOUNDRY_VIA_IR=true forge build lib/deepstate-contracts/src/DeepstateV1.sol && forge test --match-path test/Poc.t.sol -vv`: 1/1 test passed. The test demonstrates the zero-to-one exact-input branch with the real `DeepStatePlanner.plan()` and real canonical `DeepstateV1.fillWithIntegratorFee()`: two individually settleable resting bids are inserted through public `fill()`, the planner returns an over-`int256.max` output plan, and canonical settlement reverts with `DeltaOverflow`. It does not separately exercise the zero-to-one exact-output branch.
### Validation reasoning

PoC validation command completed successfully.
## Remediation
### Explanation

Reject both zero-to-one plans when their cumulative gross quote exceeds canonical DeepState's signed int256 settlement domain, before returning an unexecutable FOK plan.
### Patch

```diff
diff --git a/src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol b/src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol
--- a/src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol
+++ b/src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol
@@ -1,607 +1,609 @@
 // SPDX-License-Identifier: MIT
 pragma solidity 0.8.28;
 
 import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
 import {TickMath32} from "deepstate-contracts/src/libraries/TickMath32.sol";
 
 import {IDeepStateV1} from "./interfaces/IDeepStateV1.sol";
 import {IDeepStatePlanner} from "./interfaces/IDeepStatePlanner.sol";
 import {DeepStateConstants} from "./libraries/DeepStateConstants.sol";
 
 /// @title DeepStatePlanner
 /// @notice Immutable read-only execution planner for DeepState V1 order-book liquidity.
 /// @dev Reproduces the read-only matching and rounding semantics needed to build an executable FOK plan.
 ///      Pool and book IDs are derived locally from DeepState's canonical keccak identifiers. Exact-input
 ///      and exact-output inversion use closed-form rounding math. Uniform off-right-spine branches consume
 ///      DeepState's packed aggregate quantity and correction code in O(1); the potentially dirty global
 ///      right spine is traversed through live child pointers with a fixed execution scan cap.
 contract DeepStatePlanner is IDeepStatePlanner {
     /// @dev Maximum DFS frontier for DeepState's 64-bit radix key.
     uint256 private constant MAX_STACK = 65;
     /// @notice Fixed traversal cap. Keeping it in bytecode removes deploy-time gas-grief misconfiguration.
     uint32 public constant MAX_SCAN_NODES = 4_096;
 
     IDeepStateV1 public immutable override deepstate;
 
     /// @dev A node is aggregateSafe iff it is known to be outside the global dirty right spine.
     ///      safeMask stores one bit per stack slot to avoid a second fixed bool array.
     struct Walker {
         bytes32[MAX_STACK] stack;
         uint256 safeMask;
         uint256 sp;
         uint256 scanned;
         bytes32 book;
     }
 
     struct NetQuoteState {
         uint256 safeGrossTarget;
         uint256 grossTarget;
         uint256 baseTotal;
         uint256 grossQuote;
         int32 lastTick;
     }
 
     error InvalidPair();
     error InvalidAmount();
     error AmountTooLarge();
     error InsufficientLiquidity();
     error ScanLimit();
     error InvalidTree();
 
     constructor(IDeepStateV1 deepstate_) {
         deepstate = deepstate_;
     }
 
     function plan(address token0, address token1, bool zeroToOne, int256 amountSpecified)
         external
         view
         override
         returns (Plan memory result)
     {
         if (token0 == address(0) || token0 >= token1) revert InvalidPair();
         if (amountSpecified == 0 || amountSpecified == type(int256).min) revert InvalidAmount();
 
         uint256 specified = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
         if (specified > type(uint160).max) revert AmountTooLarge();
 
         uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
         (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
         (, uint16 feeBps) = deepstate.feeConfig();
 
         result.epoch = epoch;
         bool exactInput = amountSpecified < 0;
         bytes32 book = _bookId(token0, token1, epoch);
 
         if (zeroToOne) {
             // token0 -> token1: incoming DeepState ASK consumes resting BIDs.
             if (exactInput) {
                 (uint256 grossQuote, int32 bidExactInputLastTick) =
                     _quoteExactBase(book, bidRoot, uint160(specified), true);
+                if (grossQuote > uint256(type(int256).max)) revert AmountTooLarge();
 
                 result.amountTake = specified;
                 result.deepStateInput = specified;
                 result.amountOut = _netAfterFees(grossQuote, feeBps);
                 result.baseQuantity = uint160(specified);
                 result.limitTick = bidExactInputLastTick;
                 return result;
             }
 
             // Exact token1 output. DeepState takes protocol + routing fees from taker output, therefore we find the
             // minimum token0 quantity whose gross bid quote reaches the exact gross-up target.
             (uint160 baseIn, uint256 grossQuoteOut, int32 bidExactOutputLastTick) =
                 _baseForNetQuoteOutput(book, bidRoot, specified, feeBps);
+            if (grossQuoteOut > uint256(type(int256).max)) revert AmountTooLarge();
 
             result.amountTake = baseIn;
             result.deepStateInput = baseIn;
             result.amountOut = _netAfterFees(grossQuoteOut, feeBps);
             result.baseQuantity = baseIn;
             result.limitTick = bidExactOutputLastTick;
             return result;
         }
 
         // token1 -> token0: incoming DeepState BID consumes resting ASKs.
         if (exactInput) {
             // The input domain is quote/token1 but DeepState's order quantity is token0/base.
             // Choose the maximum base quantity whose exact FIFO quote cost is <= specified input.
             (uint160 baseOutGross, uint256 quoteSpent, int32 askExactInputLastTick) =
                 _baseForQuoteBudget(book, askRoot, specified);
 
             result.amountTake = specified;
             result.deepStateInput = quoteSpent;
             result.amountOut = _netAfterFees(baseOutGross, feeBps);
             result.baseQuantity = baseOutGross;
             result.limitTick = askExactInputLastTick;
             return result;
         }
 
         // Exact token0 output. Gross-up for DeepState's protocol + routing output fees, then price that exact base amount.
         uint160 grossBaseOut = _toUint160(_minimalGrossForNet(specified, feeBps));
         (uint256 quoteIn, int32 askExactOutputLastTick) = _quoteExactBase(book, askRoot, grossBaseOut, false);
 
         result.amountTake = quoteIn;
         result.deepStateInput = quoteIn;
         result.amountOut = _netAfterFees(grossBaseOut, feeBps);
         result.baseQuantity = grossBaseOut;
         result.limitTick = askExactOutputLastTick;
     }
 
     /// @notice External-liquidity proxy for Uniswap routing.
     /// @dev
     ///  amount0 (resting asks) is exact in O(radix depth): every off-right-spine subtree has an exact
     ///  packed aggregate base quantity. amount1 (resting bids) also collapses same-tick uniform
     ///  branches using DeepState's correction code; if MAX_SCAN_NODES is reached across many distinct
     ///  ticks, the returned amount1 is a conservative lower bound rather than reverting.
     function pseudoTotalValueLocked(address token0, address token1)
         external
         view
         override
         returns (uint256 amount0, uint256 amount1)
     {
         if (token0 == address(0) || token0 >= token1) revert InvalidPair();
 
         uint256 epoch = deepstate.poolEpoch(_poolId(token0, token1));
         (bytes32 askRoot, bytes32 bidRoot) = deepstate.roots(token0, token1, epoch);
         bytes32 book = _bookId(token0, token1, epoch);
 
         amount0 = _askBaseTVL(book, askRoot);
         amount1 = _bidQuoteTVL(book, bidRoot);
     }
 
     function _quoteExactBase(bytes32 book, bytes32 root, uint160 baseNeeded, bool restingIsBid)
         internal
         view
         returns (uint256 quoteAmount, int32 lastTick)
     {
         if (root == bytes32(0) || baseNeeded == 0) revert InsufficientLiquidity();
         Walker memory walker = _walker(book, root);
         uint160 remaining = baseNeeded;
 
         while (walker.sp != 0) {
             (bytes32 node, bool safe) = _pop(walker);
             uint32 correction = _correctionCode(node);
 
             if (safe && correction != 0) {
                 uint160 quantity = _quantity(node);
                 if (quantity <= remaining) {
                     quoteAmount += _uniformBranchQuote(node, restingIsBid);
                     remaining -= quantity;
                     lastTick = _price(node);
                     if (remaining == 0) return (quoteAmount, lastTick);
                     continue;
                 }
                 // The aggregate correction is exact only for the whole subtree. For a partial FIFO
                 // fill, descend; descendants remain aggregate-safe.
                 _expand(walker, node, true);
                 continue;
             }
 
             (bytes32 left, bytes32 right) = _tree(walker, node, true);
             if (left == bytes32(0)) {
                 if (right != bytes32(0)) revert InvalidTree();
                 uint160 quantity = _quantity(node);
                 if (quantity == 0) revert InvalidTree();
                 uint160 fill = remaining < quantity ? remaining : quantity;
                 quoteAmount += _partialLeafQuote(_price(node), quantity, fill, restingIsBid);
                 remaining -= fill;
                 lastTick = _price(node);
                 if (remaining == 0) return (quoteAmount, lastTick);
                 continue;
             }
 
             if (right == bytes32(0)) revert InvalidTree();
             _pushChildren(walker, left, right, safe);
         }
 
         revert InsufficientLiquidity();
     }
 
     function _baseForQuoteBudget(bytes32 book, bytes32 root, uint256 budget)
         internal
         view
         returns (uint160 baseQuantity, uint256 quoteSpent, int32 lastTick)
     {
         if (root == bytes32(0) || budget == 0) revert InsufficientLiquidity();
         Walker memory walker = _walker(book, root);
         uint256 baseTotal;
         uint256 remainingBudget = budget;
 
         while (walker.sp != 0) {
             (bytes32 node, bool safe) = _pop(walker);
             uint32 correction = _correctionCode(node);
 
             if (safe && correction != 0) {
                 uint256 fullCost = _uniformBranchQuote(node, false);
                 if (fullCost <= remainingBudget) {
                     uint160 quantity = _quantity(node);
                     baseTotal += quantity;
                     if (baseTotal > type(uint160).max) revert AmountTooLarge();
                     quoteSpent += fullCost;
                     remainingBudget -= fullCost;
                     lastTick = _price(node);
                     // Keep walking even at zero remaining budget: later FIFO asks can still have
                     // zero raw quote cost because ASK notionals round down in DeepState.
                     continue;
                 }
                 _expand(walker, node, true);
                 continue;
             }
 
             (bytes32 left, bytes32 right) = _tree(walker, node, true);
             if (left == bytes32(0)) {
                 if (right != bytes32(0)) revert InvalidTree();
                 uint160 quantity = _quantity(node);
                 if (quantity == 0) revert InvalidTree();
                 int32 tick = _price(node);
                 uint256 fullCost = _quoteValue(tick, quantity, false);
 
                 if (fullCost <= remainingBudget) {
                     baseTotal += quantity;
                     if (baseTotal > type(uint160).max) revert AmountTooLarge();
                     quoteSpent += fullCost;
                     remainingBudget -= fullCost;
                     lastTick = tick;
                     // Zero-cost leaves after an exactly exhausted budget are still executable.
                     continue;
                 }
 
                 uint160 partialFill = _maxPartialAskFill(tick, quantity, remainingBudget);
                 if (partialFill == 0) {
                     if (baseTotal == 0) revert InsufficientLiquidity();
                     return (uint160(baseTotal), quoteSpent, lastTick);
                 }
 
                 uint256 partialCost = _partialLeafQuote(tick, quantity, partialFill, false);
                 baseTotal += partialFill;
                 if (baseTotal > type(uint160).max) revert AmountTooLarge();
                 quoteSpent += partialCost;
                 lastTick = tick;
                 return (uint160(baseTotal), quoteSpent, lastTick);
             }
 
             if (right == bytes32(0)) revert InvalidTree();
             _pushChildren(walker, left, right, safe);
         }
 
         // The quote-input domain is not the DeepState quantity domain. If the entire ASK book is
         // exhausted first, return the maximal executable base quantity and let the hook's dust
         // tolerance decide whether the unspent quote remainder is acceptable.
         return (uint160(baseTotal), quoteSpent, lastTick);
     }
 
     function _baseForNetQuoteOutput(bytes32 book, bytes32 root, uint256 targetNetQuote, uint16 feeBps)
         internal
         view
         returns (uint160 baseQuantity, uint256 grossQuote, int32 lastTick)
     {
         if (root == bytes32(0) || targetNetQuote == 0) revert InsufficientLiquidity();
         Walker memory walker = _walker(book, root);
         NetQuoteState memory state;
         state.safeGrossTarget = _safeGrossForNet(targetNetQuote, feeBps);
         state.grossTarget = _minimalGrossForNet(targetNetQuote, feeBps);
 
         while (walker.sp != 0) {
             (bytes32 node, bool safe) = _pop(walker);
             uint32 correction = _correctionCode(node);
 
             if (safe && correction != 0) {
                 uint256 fullQuote = _uniformBranchQuote(node, true);
                 if (state.grossQuote + fullQuote < state.grossTarget) {
                     uint160 quantity = _quantity(node);
                     state.grossQuote += fullQuote;
                     state.baseTotal += quantity;
                     if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
                     state.lastTick = _price(node);
                     continue;
                 }
                 _expand(walker, node, true);
                 continue;
             }
 
             (bytes32 left, bytes32 right) = _tree(walker, node, true);
             if (left == bytes32(0)) {
                 if (right != bytes32(0)) revert InvalidTree();
                 if (_consumeNetQuoteLeaf(state, node, targetNetQuote, feeBps)) {
                     return (uint160(state.baseTotal), state.grossQuote, state.lastTick);
                 }
                 continue;
             }
 
             if (right == bytes32(0)) revert InvalidTree();
             _pushChildren(walker, left, right, safe);
         }
 
         revert InsufficientLiquidity();
     }
 
     function _consumeNetQuoteLeaf(NetQuoteState memory state, bytes32 node, uint256 targetNetQuote, uint16 feeBps)
         internal
         pure
         returns (bool done)
     {
         uint160 quantity = _quantity(node);
         if (quantity == 0) revert InvalidTree();
 
         int32 tick = _price(node);
         uint256 fullQuote = _quoteValue(tick, quantity, true);
         uint256 fullGross = state.grossQuote + fullQuote;
 
         if (fullGross < state.grossTarget) {
             state.grossQuote = fullGross;
             state.baseTotal += quantity;
             if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
             state.lastTick = tick;
             return false;
         }
 
         uint160 partialFill = _minPartialBidFill(tick, quantity, state.grossTarget - state.grossQuote);
         uint256 candidateGross = state.grossQuote + _partialLeafQuote(tick, quantity, partialFill, true);
         uint256 candidateBase = state.baseTotal + partialFill;
         if (candidateBase == 0 || candidateBase > type(uint160).max) revert AmountTooLarge();
 
         // Independent fee floors can make net(gross) dip by one raw unit. The globally minimal
         // gross target can therefore be executable while the next raw gross value under-delivers.
         // If the first reachable quote lands on that dip, continue to the monotone-safe combined
         // threshold instead of returning an under-delivering exact-output plan.
         if (_netAfterFees(candidateGross, feeBps) >= targetNetQuote) {
             state.grossQuote = candidateGross;
             state.baseTotal = candidateBase;
             state.lastTick = tick;
             return true;
         }
 
         if (fullGross < state.safeGrossTarget) {
             state.grossQuote = fullGross;
             state.baseTotal += quantity;
             if (state.baseTotal > type(uint160).max) revert AmountTooLarge();
             state.lastTick = tick;
             // The minimal exact target has already been crossed, but the first reachable
             // gross landed on an independent-floor fee dip. From this point onward only
             // the monotone-safe target is meaningful.
             state.grossTarget = state.safeGrossTarget;
             return false;
         }
 
         partialFill = _minPartialBidFill(tick, quantity, state.safeGrossTarget - state.grossQuote);
         state.grossQuote += _partialLeafQuote(tick, quantity, partialFill, true);
         state.baseTotal += partialFill;
         if (state.baseTotal == 0 || state.baseTotal > type(uint160).max) revert AmountTooLarge();
         if (_netAfterFees(state.grossQuote, feeBps) < targetNetQuote) revert InsufficientLiquidity();
         state.lastTick = tick;
         return true;
     }
 
     /// @dev Maximum base fill from one resting ASK leaf with exact DeepState partial-fill rounding.
     function _maxPartialAskFill(int32 tick, uint160 quantity, uint256 budget) internal pure returns (uint160 fill) {
         if (quantity == 0) return 0;
         if (tick == 0) return uint160(budget < quantity ? budget : quantity);
 
         (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
         uint256 denominator = uint256(1) << shift;
         uint256 fullQuote = Math.mulDiv(uint256(quantity), factor, denominator); // ASK rounds down
         if (fullQuote <= budget) return quantity;
 
         // partial(f) = floor(Q*p/d) - floor((Q-f)*p/d) <= budget
         // => floor((Q-f)*p/d) >= fullQuote-budget
         // => remainder >= ceil((fullQuote-budget)*d/p)
         uint256 minRemainderQuote = fullQuote - budget;
         uint256 remainder = _mulDivUp(minRemainderQuote, denominator, factor);
         fill = uint160(uint256(quantity) - remainder);
     }
 
     /// @dev Minimum base fill from one resting BID leaf whose gross token1 quote reaches grossNeed.
     function _minPartialBidFill(int32 tick, uint160 quantity, uint256 grossNeed) internal pure returns (uint160 fill) {
         if (quantity == 0 || grossNeed == 0) return 0;
         if (tick == 0) {
             if (grossNeed > quantity) revert InsufficientLiquidity();
             return uint160(grossNeed);
         }
 
         (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
         uint256 denominator = uint256(1) << shift;
         uint256 fullQuote = _mulDivUp(uint256(quantity), factor, denominator); // BID rounds up
         if (grossNeed > fullQuote) revert InsufficientLiquidity();
 
         // partial(f) = ceil(Q*p/d) - ceil((Q-f)*p/d) >= grossNeed
         // Let C = fullQuote-grossNeed. ceil(r*p/d) <= C iff r*p/d <= C.
         // Max remainder is floor(C*d/p), therefore min fill is Q-remainder.
         uint256 maxRemainderQuote = fullQuote - grossNeed;
         uint256 remainder = Math.mulDiv(maxRemainderQuote, denominator, factor);
         fill = uint160(uint256(quantity) - remainder);
     }
 
     function _askBaseTVL(bytes32 book, bytes32 root) internal view returns (uint256 amount0) {
         if (root == bytes32(0)) return 0;
         Walker memory walker = _walker(book, root);
 
         while (walker.sp != 0) {
             (bytes32 node, bool safe) = _pop(walker);
 
             // Every off-right-spine node has exact aggregate quantity even when it spans many ticks.
             if (safe) {
                 amount0 += _quantity(node);
                 continue;
             }
 
             (bytes32 left, bytes32 right) = _tree(walker, node, false);
             if (left == bytes32(0)) {
                 if (right != bytes32(0)) revert InvalidTree();
                 amount0 += _quantity(node);
                 continue;
             }
             if (right == bytes32(0)) revert InvalidTree();
             _pushChildren(walker, left, right, false);
         }
     }
 
     function _bidQuoteTVL(bytes32 book, bytes32 root) internal view returns (uint256 amount1) {
         if (root == bytes32(0)) return 0;
         Walker memory walker = _walker(book, root);
 
         while (walker.sp != 0) {
             (bytes32 node, bool safe) = _pop(walker);
             uint32 correction = _correctionCode(node);
 
             if (safe && correction != 0) {
                 amount1 += _uniformBranchQuote(node, true);
                 continue;
             }
 
             if (walker.scanned >= MAX_SCAN_NODES) break;
             (bytes32 left, bytes32 right) = _tree(walker, node, false);
             if (left == bytes32(0)) {
                 if (right != bytes32(0)) revert InvalidTree();
                 amount1 += _quoteValue(_price(node), _quantity(node), true);
                 continue;
             }
             if (right == bytes32(0)) revert InvalidTree();
             _pushChildren(walker, left, right, safe);
         }
     }
 
     function _walker(bytes32 book, bytes32 root) internal pure returns (Walker memory walker) {
         walker.book = book;
         walker.stack[0] = root;
         walker.sp = 1;
         // Root is deliberately unsafe: only the global right spine may contain stale aggregate words.
     }
 
     function _pop(Walker memory walker) internal pure returns (bytes32 node, bool safe) {
         uint256 index = --walker.sp;
         node = walker.stack[index];
         safe = ((walker.safeMask >> index) & 1) != 0;
     }
 
     function _tree(Walker memory walker, bytes32 node, bool strict)
         internal
         view
         returns (bytes32 left, bytes32 right)
     {
         ++walker.scanned;
         if (strict && walker.scanned > MAX_SCAN_NODES) revert ScanLimit();
         return deepstate.tree(walker.book, node);
     }
 
     function _expand(Walker memory walker, bytes32 node, bool safe) internal view {
         (bytes32 left, bytes32 right) = _tree(walker, node, true);
         if (left == bytes32(0) || right == bytes32(0)) revert InvalidTree();
         _pushChildren(walker, left, right, safe);
     }
 
     function _pushChildren(Walker memory walker, bytes32 left, bytes32 right, bool parentSafe) internal pure {
         if (walker.sp + 2 > MAX_STACK) revert InvalidTree();
 
         // Push left then right so right is popped/executed first. If the parent is on the potentially
         // dirty global right spine, only its right child remains unsafe; the left subtree is exact.
         _push(walker, left, true);
         _push(walker, right, parentSafe);
     }
 
     function _push(Walker memory walker, bytes32 node, bool safe) internal pure {
         uint256 index = walker.sp++;
         walker.stack[index] = node;
         uint256 bit = uint256(1) << index;
         if (safe) walker.safeMask |= bit;
         else walker.safeMask &= ~bit;
     }
 
     function _uniformBranchQuote(bytes32 node, bool isBid) internal pure returns (uint256 quoteAmount) {
         uint32 correctionCode = _correctionCode(node);
         quoteAmount = _quoteValue(_price(node), _quantity(node), isBid);
         uint256 correction = uint256(correctionCode) - 1;
         quoteAmount = isBid ? quoteAmount + correction : quoteAmount - correction;
     }
 
     function _partialLeafQuote(int32 tick, uint160 originalQuantity, uint160 fillQuantity, bool roundUp)
         internal
         pure
         returns (uint256)
     {
         if (fillQuantity == originalQuantity) return _quoteValue(tick, originalQuantity, roundUp);
         return
             _quoteValue(tick, originalQuantity, roundUp) - _quoteValue(tick, originalQuantity - fillQuantity, roundUp);
     }
 
     function _quoteValue(int32 tick, uint160 quantity, bool roundUp) internal pure returns (uint256 quoteAmount) {
         if (quantity == 0) return 0;
         if (tick == 0) return quantity;
 
         (uint256 factor, uint16 shift) = TickMath32.getPriceFactorAtTick(tick);
         uint256 denominator = uint256(1) << shift;
         quoteAmount = Math.mulDiv(uint256(quantity), factor, denominator);
         if (roundUp && mulmod(uint256(quantity), factor, denominator) != 0) ++quoteAmount;
     }
 
     /// @dev Monotone-safe gross threshold for exact-output quote traversal. Any gross >= this value
     ///      necessarily nets at least targetNet because independent floors deduct no more than the
     ///      floor of the summed fee rate. This is used as the fallback when a reachable raw gross lands
     ///      on the one-unit non-monotonic dip of the independent-fee net function.
     function _safeGrossForNet(uint256 targetNet, uint16 protocolFeeBps) internal pure returns (uint256 gross) {
         if (targetNet == 0) revert InvalidAmount();
 
         uint256 combinedFeeBps = uint256(protocolFeeBps) + uint256(DeepStateConstants.ROUTING_FEE_BPS);
         gross = Math.mulDiv(targetNet - 1, DeepStateConstants.BPS, DeepStateConstants.BPS - combinedFeeBps) + 1;
     }
 
     /// @dev Globally minimal gross when the gross output itself is directly selectable (token0 exact-output).
     ///      Let G be the monotone-safe summed-rate threshold. Because separate floor fees can improve net by
     ///      at most one unit relative to the summed floor, and the <=110 bps summed fee cannot advance on
     ///      consecutive raw gross values, no value below G-2 can satisfy the target. Check G-2 then G-1.
     function _minimalGrossForNet(uint256 targetNet, uint16 protocolFeeBps) internal pure returns (uint256 gross) {
         gross = _safeGrossForNet(targetNet, protocolFeeBps);
         if (gross > 2 && _netAfterFees(gross - 2, protocolFeeBps) >= targetNet) return gross - 2;
         if (gross > 1 && _netAfterFees(gross - 1, protocolFeeBps) >= targetNet) return gross - 1;
     }
 
     function _feeAmount(uint256 gross, uint16 feeBps) internal pure returns (uint256) {
         return feeBps == 0 || gross == 0 ? 0 : Math.mulDiv(gross, uint256(feeBps), DeepStateConstants.BPS);
     }
 
     function _netAfterFees(uint256 gross, uint16 protocolFeeBps) internal pure returns (uint256) {
         uint256 protocolFee = _feeAmount(gross, protocolFeeBps);
         uint256 routingFee = _feeAmount(gross, DeepStateConstants.ROUTING_FEE_BPS);
         return gross - protocolFee - routingFee;
     }
 
     function _mulDivUp(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
         result = Math.mulDiv(x, y, denominator);
         if (mulmod(x, y, denominator) != 0) ++result;
     }
 
     function _toUint160(uint256 value) internal pure returns (uint160 result) {
         if (value > type(uint160).max) revert AmountTooLarge();
         result = uint160(value);
     }
 
     function _price(bytes32 node) internal pure returns (int32) {
         return int32(uint32(uint256(node) >> 224));
     }
 
     function _quantity(bytes32 node) internal pure returns (uint160) {
         return uint160(uint256(node) >> 64);
     }
 
     function _correctionCode(bytes32 node) internal pure returns (uint32) {
         return uint32(uint256(node) >> 32);
     }
 
     function _poolId(address token0, address token1) internal pure returns (bytes32 id) {
         /// @solidity memory-safe-assembly
         assembly {
             let ptr := mload(0x40)
             mstore(ptr, token0)
             mstore(add(ptr, 0x20), token1)
             id := keccak256(ptr, 0x40)
         }
     }
 
     function _bookId(address token0, address token1, uint256 epoch) internal pure returns (bytes32 id) {
         /// @solidity memory-safe-assembly
         assembly {
             let ptr := mload(0x40)
             mstore(ptr, token0)
             mstore(add(ptr, 0x20), token1)
             mstore(add(ptr, 0x40), epoch)
             id := keccak256(ptr, 0x60)
         }
     }
 }
```
### Affected files
- `src/aggregator-hooks/implementations/DeepState/DeepStatePlanner.sol`
### Validation output

```
[output truncated: 971 lines & 46.353515625 KB skipped]

Ran 1 test suite in 9.48ms (2.02ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/Poc.t.sol:Poc
[FAIL: AmountTooLarge()] test_poc_zeroToOnePlannerReturnsPlanThatCanonicalDeepStateCannotSettle() (gas: 258825)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```
