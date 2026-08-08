# Gap-05: Security Claims Verification

**Date:** 2026-08-08
**Subagent:** #5 (security claims — invariant tests, reentrancy test, security audit)

---

## Summary of Findings

**Security claims are mostly real but with significant gaps. The "security audit" is an internal subagent review, not an external audit. Invariant tests are real but some are trivially passing. Reentrancy test is real and legitimate. Security edge-case tests are meaningful.**

---

## 1. README Security Claims

The README claims:
- "11. 3 adversarial security audits — M1 (sig malleability), M2 (nonce), L1/L2/L4/L5 — all fixed"
- "12. 5 critical security edge-case tests"
- Link to `planning/security-audit/verdict.md` = **PASS-WITH-NOTES**

### Gap: "Audit" is internal, not external
The "security audit" at `planning/security-audit/verdict.md` is a single file — a read-only subagent review of 443 lines of Solidity. It was NOT performed by any external auditor (no audit firm, no security researcher). The README's phrasing "3 adversarial security audits" is misleading — it refers to this internal review identifying 2 Medium + 3 Low findings. No audit firm is named, no audit report with methodology, scope, and risk rating exists.

**Impact:** Judges may expect an external audit. The README should clarify this was an internal code review, not a professional security audit.

---

## 2. Invariant Tests (8 tests in `CreditGateVault.invariant.t.sol`)

### Test-by-Test Assessment:

| # | Test Name | Real Property? | Quality |
|---|-----------|---------------|---------|
| I1 | `invariant_fxrpConserved` | ✅ Yes — FXRP conservation across all actors | **Strong** — checks vault + handler + 2 borrowers = 30,000e6 |
| I2 | `invariant_usdt0Conserved` | ✅ Yes — USDT0 conservation | **Strong** — total = 100,000e18 across all actors |
| I3 | `invariant_noOverdraft` | ✅ Yes — vault USDT0 ≥ outstanding loans | **Strong** — iterates all FUNDED loans |
| I4 | `invariant_stateMonotonic` | ✅ Yes — no backward state transitions | **Strong** — checks state ≤ DEFAULTED for all loans |
| I5 | `invariant_noGhostCollateral` | ⚠️ Partially trivial — `assertGe(totalCollateral + 0, 0)` is always true | **Weak** — line 201 has `assertGe(totalCollateral + 0, 0)` which is a tautology. The real check is `assertLe(fxrp.balanceOf(vault), totalCollateral + 0)` which is meaningful |
| I6 | `invariant_interestNeverExceedsCollateral` | ✅ Yes — interest ≤ collateral (×1e12) | **Moderate** — bound is very loose (`collateral * 1e12`) |
| I7 | `invariant_ltvLimitRespected` | ⚠️ Weak — only checks `loanAmount > 0` when `collateral > 0` | **Weak** — this is essentially a triviality check; a funded loan having non-zero amounts is already guaranteed by `drawLoan` requiring `loanAmount > 0`. Does NOT verify actual LTV bounds |
| I8 | `invariant_terminalLoansCantReopen` | ⚠️ Redundant with I4 — checks that DEFAULTED/CLOSED ≠ FUNDED | **Redundant** — if state ≤ DEFAULTED (I4), then DEFAULTED/CLOSED can never equal FUNDED. This is mathematically implied by I4 |

### Key Gaps in Invariant Tests:

1. **I7 is trivially passing** — It doesn't test LTV enforcement. A real LTV invariant would verify that for every FUNDED loan: `loanAmount ≤ collateralAmount × price × LTV / 10000`. The test only checks both are non-zero.

2. **I8 is redundant** — Already proven by I4 (state monotonicity).

3. **I5 has a tautological assertion** — `assertGe(totalCollateral + 0, 0)` is always true in Solidity 0.8.x. Only the `assertLe` line is meaningful.

4. **I6 bound is very loose** — `collateral * 1e12` is far larger than any realistic interest. A tighter bound (e.g., `collateral * INTEREST_RATE_BPS * loanDuration / (10000 * SECONDS_PER_YEAR)`) would prove more.

5. **Missing: USDT0 can never exceed vault balance invariant** — While I3 checks outstanding loans, it doesn't check that total USDT0 disbursed never exceeds total USDT0 deposited (the "no money printing" invariant is implicit in I2 but not explicitly cross-checked against loan disbursements).

6. **Missing: Interest accrual monotonicity** — No invariant verifies that `getInterestOwed` only increases over time (within a loan's lifetime).

---

## 3. Reentrancy Test (`CreditGateVault.malicious-reentrancy.t.sol`)

### Assessment: **REAL and legitimate**

This is NOT a superficial test. It deploys a **real malicious FXRP token** (`MaliciousFxrp`) that:
- Implements a full IERC20 interface
- Has a configurable `attacking` flag
- During `transferFrom`, re-enters `vault.depositCollateral()` before the first call completes
- Uses `try/catch` to detect if the re-entry succeeded or was blocked by `ReentrancyGuard`

The test verifies:
- `nextLoanId == 2` (only ONE loan created, not two)
- The outer loan has correct state (`COLLATERAL_DEPOSITED`) and amount
- The re-entry attempt was blocked by OpenZeppelin's `nonReentrant` guard

**Quality: Solid.** This is a textbook reentrancy test with a real attack contract. The only minor gap is that it only tests reentrancy on `depositCollateral` — other entry points (`drawLoan`, `submitRepaymentProof`, etc.) could theoretically be reentered, though they're also protected by `nonReentrant`.

---

## 4. Security Edge-Case Tests (`CreditGateVault.security-edge.t.sol`)

### Test-by-Test Assessment:

| # | Test Name | Meaningful? | Quality |
|---|-----------|------------|---------|
| 1 | `test_fdcProof_revertsOnNegativeReceivedAmount` | ✅ **Yes** — tests int256 → uint256 overflow in FDC proof | **Strong** — verifies the vault handles negative receivedAmount safely |
| 2 | `test_fdcProof_revertsOnCrossLoanReplay` | ✅ **Yes** — tests proof from loan A cannot close loan B | **Strong** — tests both borrower2 (wrong borrower) and borrower1 (NotBorrower check) |
| 3 | `test_repayment_acceptsPastDeadlineWithMaxInterest` | ⚠️ **Misleading name** — this is a happy-path test, not a security edge case | **Weak** — tests that repayment at deadline works with max interest. Not really testing a "security edge case" |
| 4 | `test_liquidation_worksWhileVaultPaused` | ✅ **Yes** — tests emergency operations during pause | **Strong** — tests full auction lifecycle while paused |
| 5 | `test_ltvTightening_doesNotAffectOutstandingLoans` | ✅ **Yes** — tests LTV changes don't retroactively affect loans | **Strong** — verifies existing loan is unaffected, new loan respects tightened LTV |

### Key Gaps:

1. **Test 3 is not a security edge case** — It's a normal repayment at deadline. A real security edge case would test repayment AFTER the deadline (e.g., what happens to accrued interest when state is DEFAULTED).

2. **Missing: Front-running FDC proof** — No test for a front-runner submitting someone else's FDC proof (the `proofOwner` check exists but is untested).

3. **Missing: Zero-balance loan closure** — No test for what happens if a loan has zero collateral when repayment is attempted.

---

## 5. Security Audit Report

### What exists:
- `planning/security-audit/verdict.md` — 160-line internal review (PASS-WITH-NOTES)
- `planning/security-prism/` — 3 additional verdict files (frontend, go-handler, main)

### What's missing:
- **No external audit firm** — The README claims "3 adversarial security audits" but these are all internal subagent reviews
- **No methodology** — No audit methodology section (what tools were used, what was in/out of scope, what testing was performed)
- **No risk rating framework** — Uses severity labels (Medium/Low) but no CVSS or industry-standard risk scoring
- **No remediation verification** — The README claims "all fixed" but there's no before/after code diff or test proving the fix works (the tests exist but aren't tied to specific audit findings)
- **No audit timestamp** — The audit is dated 2026-08-05, but it's unclear if this is the final state or if changes were made after

---

## 6. Critical Gaps Summary

| Gap | Severity | Impact on "Is the architecture credible?" |
|-----|----------|-------------------------------------------|
| "Security audit" is internal review, not external | **High** | Judges may question credibility of security claims |
| Invariant I7 is trivially passing (doesn't test LTV) | **Medium** | Overstates test quality — one of 8 invariants is weak |
| Invariant I8 is redundant with I4 | **Low** | Minor — reduces perceived test rigor |
| Security edge-case test 3 is not an edge case | **Medium** | Mislabels a happy-path test as security testing |
| No external audit report or methodology | **High** | Missing evidence for "audit-verified" claim |
| Reentrancy test only covers depositCollateral | **Low** | Other entry points are protected by same guard |

---

## Recommendations

1. **Clarify "audit" language** — Change "3 adversarial security audits" to "3 internal security reviews" or "security code review" in README
2. **Fix trivially passing invariants** — Either remove I7 or rewrite it to actually verify LTV bounds
3. **Remove redundant I8** — Or rewrite it to test something unique
4. **Relabel test 3** — Rename from "security edge case" to "interest accrual boundary test" or similar
5. **Add methodology to audit** — Document what was reviewed, what tools were used, what was excluded
6. **Consider external audit** — For mainnet, an external audit from a recognized firm would significantly strengthen credibility
