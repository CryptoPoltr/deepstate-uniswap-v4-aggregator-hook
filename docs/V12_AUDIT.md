# V12 Security Review and Remediation

This document records the V12 audit scope, the finding published in the public report, and the remediation applied by this repository.

**Official public V12 report:** <https://v12.sh/runs/6851/public>

## Audited scope

The public V12 report describes the review as a **Full audit** of:

- repository: `CryptoPoltr/deepstate-uniswap-v4-aggregator-hook`;
- branch: `main`;
- commit: `b8f219a`;
- source scope: `src` (899 LoC in the report).

The report's executive summary identifies **one finding, of Medium severity**. The audited commit predates the remediation documented below; the current repository state is therefore post-audit code containing the fix.

## Published finding

### F-244822 — Bound aggregate quote to the settlement domain

**Severity:** Medium

V12 found that the zero-to-one Planner paths could accumulate a gross BID quote as `uint256` without first enforcing canonical DeepState's signed `int256` settlement domain. Multiple resting BIDs can each be individually settleable while their cumulative quote exceeds `int256.max`. In that state the pre-remediation Planner could return a fill-or-kill plan that canonical DeepState could not settle.

The public report notes an important scope distinction: `DeepStateAggregator` already fails closed at its narrower v4-facing signed-delta bound, so the demonstrated impact is primarily a Planner correctness/availability issue for the public Planner API or another adapter that does not impose an equivalent bound.

### V12 proof of concept

The published PoC exercises the **zero-to-one exact-input** path using the real `DeepStatePlanner.plan()` and canonical `DeepstateV1.fillWithIntegratorFee()`:

1. two resting BIDs are inserted, each individually within the signed settlement domain;
2. their cumulative quote exceeds `int256.max`;
3. the pre-remediation Planner returns an over-domain output plan;
4. canonical DeepState rejects settlement with `DeltaOverflow`.

The public report explicitly states that this PoC does **not** separately exercise the zero-to-one exact-output branch.

### V12 remediation recommendation

V12 recommends rejecting **both zero-to-one planning branches** when their cumulative gross quote exceeds canonical DeepState's signed `int256` settlement domain, before returning an unexecutable FOK plan.

## Project remediation

The repository implements that recommendation in `DeepStatePlanner.sol`:

```solidity
if (grossQuote > uint256(type(int256).max)) revert AmountTooLarge();
```

for zero-to-one exact-input, and:

```solidity
if (grossQuoteOut > uint256(type(int256).max)) revert AmountTooLarge();
```

for zero-to-one exact-output.

This makes the DeepState signed-settlement bound part of Planner executability rather than relying on a downstream adapter to reject an oversized plan.

## Regression coverage

`DeepStatePlanner.fuzz.t.sol` contains:

```text
test_regression_zeroForOneExactInput_rejectsAggregateQuoteOutsideSignedSettlementDomain
```

The regression uses the real DeepState engine, constructs two resting BIDs that are individually settleable but exceed `int256.max` in aggregate, and requires `planner.plan(...)` to revert with `DeepStatePlanner.AmountTooLarge`.

The full project test suite was rerun successfully after the remediation.

## Public report vs. supplied raw export

The **public V12 report lists one finding: F-244822 (Medium)**. During development, a larger raw V12 export was also supplied. That raw artifact contains ten additional Low-severity candidate entries marked `Invalid` plus the F-244822 candidate record. The raw export is preserved verbatim at [`../audits/V12_RAW_EXPORT.md`](../audits/V12_RAW_EXPORT.md) for traceability, but it should not be confused with the published audit result.

The rejected candidate entries in that raw export are:

| ID | Candidate title | Raw-export status | Code change |
| --- | --- | --- | --- |
| #244807 | One-Step Handoff Can Strand Fee Authority | Low / Invalid | None |
| #244808 | No confirmed U3 vulnerability | Low / Invalid | None |
| #244809 | No confirmed U3 vulnerability | Low / Invalid | None |
| #244810 | Untrusted planner can control execution prices | Low / Invalid | None |
| #244811 | Execution target binding is not authenticated | Low / Invalid | None |
| #244812 | Unvalidated manager can disable the hook | Low / Invalid | None |
| #244815 | Malformed safe aggregates bypass tree validation | Low / Invalid | None |
| #244816 | Duplicate child pointers double-count liquidity | Low / Invalid | None |
| #244817 | Cyclic child pointers exhaust planner traversal | Low / Invalid | None |
| #244821 | Validate the immutable DeepState endpoint at deployment | Low / Invalid | None |

These rejected candidates remain useful as design-review notes around deployment trust, canonical DeepState tree invariants, and routing-fee recipient operations, and the corresponding assumptions are documented in [`SECURITY.md`](./SECURITY.md). They are **not** described as findings from the public V12 report.

## Status

- Public V12 audit scope: commit `b8f219a` (`main`).
- Published findings: **1 Medium — F-244822**.
- F-244822 remediation: implemented.
- Regression coverage: added against canonical DeepState.
- Post-remediation full project test suite: passed.
- Current repository state: post-audit/post-remediation; not identical to the audited commit.
