# Gap-13: Invariant Test Quality Assessment

## Summary Verdict: MOSTLY TRIVIALLY PASSING — Would disappoint a technical judge

The suite claims 8 invariants. Of these, **6 are trivially or vacuously true** given the handler's capabilities. The handler can only deposit and withdraw FXRP collateral — it never exercises the loan lifecycle (eligibility → draw → repayment → liquidation). This means the invariants that matter most (USDT0 overdraft, interest bounds, terminal state preservation) are checked against a state space that never reaches the conditions they're supposed to protect.

---

## Handler Analysis

### What the handler exposes (3 functions):

| Handler Function | What it does | State transitions exercised |
|---|---|---|
| `depositCollateral(uint256)` | Deposits random FXRP (1–1000e6) | → COLLATERAL_DEPOSITED |
| `withdrawCollateral(uint256)` | Withdraws collateral from a loan | COLLATERAL_DEPOSITED → IDLE |
| `registerXRPL()` | Registers XRPL address (idempotent) | None (precondition only) |

### What the handler is MISSING (5+ critical functions):

| Missing Handler Function | State it would exercise | Why it matters |
|---|---|---|
| `requestEligibility(loanId)` | COLLATERAL_DEPOSITED → ELIGIBILITY_PENDING | Required to advance loans |
| `submitEligibility(loanId, attestation)` | ELIGIBILITY_PENDING → ELIGIBLE/REJECTED | Requires TEE signature — complex |
| `drawLoan(loanId, amount)` | ELIGIBLE → FUNDED | **The function most likely to have accounting bugs** |
| `submitRepaymentProof(loanId, proof)` | FUNDED → REPAYMENT_PENDING → CLOSED | FDC proof verification |
| `liquidate(loanId)` | FUNDED → AUCTION → DEFAULTED | Post-deadline liquidation |

**Without these, the handler can never create a FUNDED loan.** The full state machine (0→1→2→3→4→5→6/8) is never exercised.

The vault is also a `targetContract`, so the fuzzer can call vault functions directly — but without TEE-signed attestations or FDC proofs, complex functions will revert. The fuzzer will mostly succeed only on `depositCollateral` and `withdrawCollateral`.

---

## Per-Invariant Quality Assessment

### I1: `invariant_fxrpConserved` — MEANINGFUL but limited

```solidity
function invariant_fxrpConserved() public view {
    uint256 total = fxrp.balanceOf(address(vault))
        + fxrp.balanceOf(handler)
        + fxrp.balanceOf(borrower1)
        + fxrp.balanceOf(borrower2);
    assertEq(total, 30_000e6);
}
```

**Quality: ✅ Would catch a real bug.** If the vault minted or burned FXRP during deposit/withdraw, this invariant would fire. The handler exercises deposit/withdraw cycles, so this invariant is actually tested against meaningful state changes.

**Caveat:** Only tests the deposit/withdraw path — not repayment, liquidation, or auction flows where FXRP also moves.

---

### I2: `invariant_usdt0Conserved` — TRIVIALLY PASSING

```solidity
function invariant_usdt0Conserved() public view {
    uint256 total = vaultUsdt + usdt0.balanceOf(handler) + ...;
    assertEq(total, 100_000e18);
}
```

**Quality: ❌ Trivially true.** The handler never calls `drawLoan`, so no USDT0 ever leaves the vault. The total is always 100_000e18 regardless of what the fuzzer does. This invariant would only be meaningful if the handler could draw and repay loans.

---

### I3: `invariant_noOverdraft` — TRIVIALLY PASSING

```solidity
function invariant_noOverdraft() public view {
    uint256 outstanding;
    for (uint256 i = 1; i < nextId; i++) {
        if (state == FUNDED) outstanding += loan.loanAmount;
    }
    assertGe(vault.usdt0.balanceOf, outstanding);
}
```

**Quality: ❌ Vacuously true.** No loans ever reach FUNDED state through the handler, so `outstanding` is always 0. The assertion `vaultUsdt >= 0` is trivially true for any uint256. This is the single most important DeFi invariant (no money printed) and it's completely untested.

---

### I4: `invariant_stateMonotonic` — TRIVIALLY PASSING

```solidity
function invariant_stateMonotonic() public view {
    for (uint256 i = 1; i < nextId; i++) {
        uint8 s = uint8(loan.state);
        assertTrue(s <= uint8(LoanState.DEFAULTED)); // s <= 8
    }
}
```

**Quality: ❌ Trivially true.** The only states used are IDLE (0) and COLLATERAL_DEPOSITED (1), both ≤ 8. The invariant never tests the transitions that matter: FUNDED→CLOSED, FUNDED→DEFAULTED, ELIGIBLE→REJECTED. A bug where a loan state goes backward (e.g., CLOSED→FUNDED) would not be caught because no loan ever reaches CLOSED.

---

### I5: `invariant_noGhostCollateral` — TRIVIALLY PASSING

```solidity
function invariant_noGhostCollateral() public view {
    for (uint256 i = 1; i < nextId; i++) {
        totalCollateral += loan.collateralAmount;
    }
    assertLe(fxrp.balanceOf(vault), totalCollateral);
}
```

**Quality: ❌ Trivially true.** The vault's FXRP balance equals the sum of deposited collateral minus withdrawn collateral. Since deposits match withdrawals (the handler only does these two operations), the vault balance always equals the sum of collateral amounts. This would only be meaningful if the handler could trigger repayment or liquidation (where collateral is released).

---

### I6: `invariant_interestNeverExceedsCollateral` — VACUOUSLY TRUE

```solidity
function invariant_interestNeverExceedsCollateral() public view {
    for (uint256 i = 1; i < nextId; i++) {
        if (state != FUNDED) continue;  // ← skips all loans
        uint256 interest = vault.getInterestOwed(i);
        assertLe(interest, loan.collateralAmount * 1e12);
    }
}
```

**Quality: ❌ Vacuously true.** No loans are FUNDED, so the `continue` skips every iteration. The invariant body is never executed. This is a zero-cost assertion that proves nothing.

---

### I7: `invariant_ltvLimitRespected` — VACUOUSLY TRUE

```solidity
function invariant_ltvLimitRespected() public view {
    for (uint256 i = 1; i < nextId; i++) {
        if (state != FUNDED) continue;  // ← skips all loans
        if (collateralAmount == 0) continue;
        assertGt(loanAmount, 0);
    }
}
```

**Quality: ❌ Vacuously true.** Same as I6 — no FUNDED loans exist, so the loop body is never reached.

---

### I8: `invariant_terminalLoansCantReopen` — VACUOUSLY TRUE

```solidity
function invariant_terminalLoansCantReopen() public view {
    for (uint256 i = 1; i < nextId; i++) {
        if (state == DEFAULTED || state == CLOSED) {
            assertTrue(state != FUNDED);  // always true since we're already in terminal
        }
    }
}
```

**Quality: ❌ Vacuously true.** No loans reach DEFAULTED or CLOSED states, so the `if` block is never entered. Even if it were, the assertion is self-evidently true (if `s == DEFAULTED`, then `s != FUNDED`).

---

## What a Technical Judge Would Think

**Impressions:**
- The NatSpec documentation (`/// @dev I1: ...`) is excellent — well-commented, clear property descriptions
- The actor labeling (`vm.label`) is good practice for trace readability
- The conservation invariants (I1, I2) show understanding of DeFi safety patterns
- The monotonicity invariant (I4) and ghost collateral check (I5) show awareness of common vulnerabilities

**Disappointments:**
- 6 of 8 invariants are trivially or vacuously true — a judge will notice this immediately
- The handler is severely underpowered — it cannot exercise the loan lifecycle
- No invariant actually tests the USDT0 lending flow (the core value proposition)
- No invariant tests interest accrual, liquidation, or repayment paths
- The suite would not catch any bug in `drawLoan`, `submitRepaymentProof`, `liquidate`, or `checkAndTriggerLiquidation`
- I4 and I8 are partially redundant (both check state bounds, but I8 is a subset of I4)

---

## Missing Invariants (What a Judge Would Expect)

### Critical gaps:

1. **Handler needs loan-lifecycle actions.** The handler should expose:
   - `requestEligibility(loanId)`
   - `submitEligibility(loanId, ...)` with TEE signing
   - `drawLoan(loanId, amount)`
   - `submitRepaymentProof(loanId, ...)` with FDC proof
   - `liquidate(loanId)`

2. **Collateral ratio invariant** — Every FUNDED loan must maintain `collateralValue / loanAmount >= collateralRatioBps / 10000`. This is the core safety property of a credit vault.

3. **Protocol reserve monotonicity** — `protocolReserve` should only increase (or stay same), never decrease.

4. **No USDT0 creation** — I2 exists but is trivially true. Needs a handler that can draw and repay.

5. **FDC proof uniqueness** — `proofConsumed` mapping should be checked to prevent replay.

6. **Borrower reputation monotonicity** — Reputation counters (`loansCompleted`, `totalRepaid`, etc.) should only increase.

---

## Recommended Fixes (Priority Order)

### P0 — Fix the handler (makes existing invariants meaningful):

Add handler actions that exercise the full loan lifecycle. The handler needs to:
1. Sign TEE attestations using `vm.sign(TEE_PK, ...)` 
2. Submit eligibility proofs
3. Draw loans with random amounts
4. Submit repayment proofs (or let loans default)
5. Trigger liquidation on defaulted loans

### P1 — Add missing invariants:

- `invariant_collateralRatioEnforced` — For every FUNDED loan, collateral value at current price >= loanAmount * collateralRatioBps / 10000
- `invariant_protocolReserveMonotonic` — `protocolReserve >= previous state`
- `invariant_proofReplayPrevention` — consumed proofs cannot be reused

### P2 — Remove redundant invariants:

- I8 is a strict subset of I4 — remove or differentiate

---

## Files Read

- `test/CreditGateVault.invariant.t.sol` (298 lines)
- `src/CreditGateVault.sol` (1488 lines, first 500)
- `src/CreditGateTypes.sol` (LoanState enum)

## Files Created

- `planning/gap-finding/gap-13-invariant-quality.md` (this file)
