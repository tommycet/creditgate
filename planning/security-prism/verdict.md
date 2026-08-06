# CreditGateVault.sol — Full-Prism Security Audit

**Date:** 2026-08-06
**Scope:** CreditGateVault.sol, CreditGateTypes.sol, test coverage
**Solidity:** ^0.8.25 (checked arithmetic, no assembly blocks)
**Methodology:** Per-function analysis across 10 security prisms

---

## Executive Summary

CreditGateVault is a well-structured FXRP-backed credit vault with strong fundamentals: SafeERC20 throughout, ReentrancyGuard on every state-changing function, Checks-Effects-Interactions ordering, FTSO staleness checks, TEE signature verification with malleability protection, and FDC proof anti-replay. The existing security audit (L1–L5, M1–M2 fixes) addressed most critical vectors.

**This audit found 0 Critical, 1 High, 3 Medium, 6 Low, and 4 Informational findings.**

| Severity | Count | IDs |
|----------|-------|-----|
| Critical | 0 | — |
| High | 1 | F1 |
| Medium | 3 | F2, F3, F7 |
| Low | 4 | F4, F5, F8, F9 |
| Informational | 4 | F10, F11, F12, F13 |

---

## Findings

### F1 — Attestation Limit Not Enforced in `drawLoan` (HIGH)

**Location:** `submitEligibility` (lines 289–293) + `drawLoan` (lines 304–381)
**Description:** The TEE-signed `EligibilityAttestation` includes a `limit` field representing the maximum authorized loan amount. This limit is included in the signed payload (for auditability) and emitted in the `EligibilitySubmitted` event, but:
1. `submitEligibility` does **not** store the limit on the Loan struct (no `limit` field exists in the struct).
2. `drawLoan` does **not** enforce `loanAmount <= attestation.limit`.

A borrower who receives an attestation authorizing up to $1000 could draw $100,000 as long as they have sufficient collateral and the collateral ratio check passes. The TEE credit limit is effectively decorative.

**Exploitable in hackathon scope:** Yes — a test borrower could obtain a small-limit attestation and draw unlimited USDT0.
**Recommended fix:**
```solidity
// Add to Loan struct:
uint256 attestationLimit; // max loan authorized by TEE

// In submitEligibility, store it:
loan.attestationLimit = attestation.limit;

// In drawLoan, enforce it:
if (loanAmount > loan.attestationLimit) revert ExceedsAttestationLimit();
```

---

### F2 — No Ownership Transfer Mechanism (MEDIUM)

**Location:** `owner` state variable (line 43) — set once in constructor
**Description:** There is no `transferOwnership()` function. The owner is permanently bound to `msg.sender` at deployment. If the owner's private key is compromised:
- An attacker gains permanent `onlyOwner` privileges (pause, revoke, recover collateral).
- There is no way to rotate ownership to a multisig or fresh address.
- A compromised owner cannot be replaced by governance.

**Exploitable in hackathon scope:** No (requires key compromise, but the design gap is real).
**Recommended fix:** Add OpenZeppelin's `Ownable` or implement `transferOwnership` with a two-step pattern (propose → accept).

---

### F3 — Owner Can DoS Borrower Withdrawals via Pause (MEDIUM)

**Location:** `pause()` (line 121), `withdrawCollateral()` (line 189)
**Description:** The owner can call `pause()` at any time, which blocks all borrower actions including `withdrawCollateral`. This allows the owner to:
1. Pause vault when a borrower has `COLLATERAL_DEPOSITED` collateral.
2. Borrower cannot withdraw while paused.
3. Owner unpauses after some period — borrower may have missed their window.

While the collateral is not stolen (it remains in the vault), the owner can grief borrowers by strategically pausing. In a more adversarial scenario, a malicious owner could:
1. Pause vault.
2. Unpause just long enough for loan deadlines to expire.
3. Borrowers who deposited collateral but didn't draw are unaffected (no deadline), but this is a denial-of-service vector.

**Exploitable in hackathon scope:** Partially — the pause mechanism is by design but has no time limit or borrower protection.
**Recommended fix:** Add a maximum pause duration (e.g., 7 days) or allow borrowers to withdraw collateral even when paused.

---

### F4 — FTSO Future Timestamp Bypasses Staleness Check (LOW)

**Location:** `drawLoan` (lines 339–343)
**Description:** The L2 fix changed the staleness check from a subtraction (which could panic) to:
```solidity
if (block.timestamp >= feedTimestamp) {
    if (uint64(block.timestamp) - feedTimestamp > ftsoStalenessLimit) {
        revert FTSOPriceStale(feedTimestamp, ftsoStalenessLimit);
    }
}
```
If `feedTimestamp > block.timestamp` (future timestamp), the outer `if` is false and the entire staleness check is skipped. This means an FTSO feed with a future timestamp (malfunction or manipulation) would be accepted with no staleness validation.

**Exploitable in hackathon scope:** No — requires FTSO oracle to return future timestamps, which is outside contract scope.
**Recommended fix:** Add an upper bound check: `require(feedTimestamp <= block.timestamp + MAX_FUTURE_DRIFT)`.

---

### F5 — `liquidate()` Is Permissionless (LOW)

**Location:** `liquidate()` (line 453)
**Description:** Anyone can call `liquidate()` after the deadline passes. While this is intentional (permissionless liquidation is a DeFi pattern), it means:
- A bot or MEV searcher could front-run the borrower's own repayment proof.
- The borrower might be trying to submit a repayment proof in the same block but the liquidation lands first.

Mitigated by: `nonReentrant` prevents both from succeeding in the same tx. If the borrower's `submitRepaymentProof` lands first, the loan becomes CLOSED and liquidation reverts.

**Exploitable in hackathon scope:** No — race condition is resolved by transaction ordering.
**Recommended fix:** None required — this is standard DeFi behavior. Consider a grace period after deadline (e.g., 1 hour) where only the borrower can repay.

---

### F6 — `borrowerLoanIds` Array Never Pruned (LOW)

**Location:** `borrowerLoanIds` mapping (line 55)
**Description:** When a loan is created, its ID is pushed to `borrowerLoanIds[msg.sender]` (line 178). There is no cleanup when a loan is CLOSED, DEFAULTED, or reset to IDLE. Over time, `getBorrowerLoanIds()` returns an ever-growing array including historical (closed/defaulted) loans.

- Gas cost of `getBorrowerLoanIds()` grows linearly with borrower activity.
- In extreme cases, this could cause out-of-gas for view calls or make the array impractical for frontend enumeration.

**Exploitable in hackathon scope:** No — it's a gas/storage concern, not an exploit.
**Recommended fix:** Either accept the growth (view function only) or add a `closedLoanIds` counter and a separate array for active loans.

---

### F7 — Documentation/Comment Mismatch: USDT0 Decimals (MEDIUM)

**Location:** `CreditGateVault.sol` line 31 vs `CreditGateTypes.sol` lines 10–12
**Description:** The immutable declaration comment says `// 6-decimal USDT0` but the code correctly treats USDT0 as 18 decimals:
- `USDT0_DECIMALS = 18` (CreditGateTypes line 10)
- `USDT0_DECIMALS_FACTOR = 1e18` (CreditGateTypes line 12)
- `drawLoan` treats loanAmount as 18dp (line 351: `loanUsd18 = loanAmount`)
- Tests confirm: `LOAN_100_USDT = 100e18`

The code is correct, but the misleading comment could cause a future integrator to misinterpret the decimal handling. Similarly, CreditGateTypes line 44 says `// USDT0 borrowed (6 decimals)` but USDT0 is 18 decimals.

**Exploitable in hackathon scope:** No — the code is correct, only the comment is wrong.
**Recommended fix:** Update comments to say "18-decimal USDT0".

---

### F8 — Owner Cannot Revoke Already-Eligible Loans (LOW)

**Location:** `revokeEligibility()` (lines 134–144), `drawLoan()` (lines 304–381)
**Description:** `revokeEligibility` bumps the revocation version and nonce, which prevents **new** attestations from being submitted. However, if a loan has already transitioned to `ELIGIBLE` (attestation already verified and accepted), revoking eligibility does not invalidate that loan.

The owner can only prevent the draw by:
1. Pausing the vault (blocks `drawLoan`).
2. Waiting for `eligibilityExpiry` to pass (drawLoan re-checks expiry).

There is no way to force-revoke an already-ELIGIBLE loan to a non-FUNDED state.

**Exploitable in hackathon scope:** Partially — requires a timing race between revokeEligibility and drawLoan.
**Recommended fix:** Add a global revocation flag that `drawLoan` checks, or add `whenNotPaused` to drawLoan and rely on pause as the emergency brake (already present).

---

### F9 — `requiredRepaymentDrops` Integer Truncation (LOW)

**Location:** `drawLoan` (line 361)
**Description:** `requiredRepaymentDrops = (loanAmount * 1e6) / xrpUsd18dp` uses integer division which truncates down. This means the required repayment is slightly less than the exact USD-equivalent. The truncation is at most 1 drop (negligible in practice), and it's favorable to the borrower.

**Exploitable in hackathon scope:** No — difference is sub-cent.
**Recommended fix:** None required. Consider ceiling division if protocol wants exact repayment: `+ 1` with a separate `>` check instead of `>=`.

---

### F10 — `REJECTED` State Defined but Never Used (INFORMATIONAL)

**Location:** `CreditGateTypes.sol` line 36, entire vault
**Description:** `LoanState.REJECTED` (value 7) is defined in the enum and `EligibilityRejected` event is declared, but neither is ever used in the contract logic. `submitEligibility` either succeeds (→ ELIGIBLE) or reverts on invalid attestation. There is no code path that transitions a loan to REJECTED.

**Exploitable in hackathon scope:** No.
**Recommended fix:** Either implement a REJECTED path (e.g., for expired/past-deadline eligibility requests) or remove the unused state and event.

---

### F11 — No Pre-Check on Vault USDT0 Balance (INFORMATIONAL)

**Location:** `drawLoan` (line 376)
**Description:** `drawLoan` performs expensive FTSO reads and collateral ratio checks before attempting `usdt0.safeTransfer(borrower, loanAmount)`. If the vault has insufficient USDT0, the transfer reverts after the FTSO gas cost is spent.

**Exploitable in hackathon scope:** No.
**Recommended fix:** `require(usdt0.balanceOf(address(this)) >= loanAmount, "InsufficientUSDT0")` before FTSO read.

---

### F12 — Owner Receives Recovered Collateral (INFORMATIONAL)

**Location:** `recoverDefaultedCollateral` (line 482)
**Description:** Seized collateral from defaulted loans is sent to `owner` rather than a protocol treasury or fee distributor. In a hackathon context this is acceptable, but in production the owner could extract all defaulted collateral.

**Exploitable in hackathon scope:** No — by design.
**Recommended fix:** Route to a `protocolTreasury` address or distribute to USDT0 lenders.

---

### F13 — `recoverDefaultedCollateral` Not Gated by `whenNotPaused` (INFORMATIONAL)

**Location:** `recoverDefaultedCollateral` (line 473)
**Description:** This function has `onlyOwner` but not `whenNotPaused`. The owner can recover collateral even while the vault is paused. This is intentional (admin functions shouldn't be blocked by pause) but means the owner can extract funds while borrowers are locked out.

**Exploitable in hackathon scope:** No.
**Recommended fix:** None — this is correct admin behavior.

---

## Prism-by-Prism Summary

### 1. Access Control ✅ Strong
- All owner functions gated by `onlyOwner`
- All borrower functions gated by `loan.borrower == msg.sender`
- `liquidate()` is permissionless but state-gated (requires FUNDED + deadline passed)
- **Gap:** No ownership transfer (F2), no mechanism to revoke already-eligible loans (F8)

### 2. Reentrancy ✅ Strong
- `nonReentrant` on all 8 state-changing external functions
- Checks-Effects-Interactions ordering maintained in every external call:
  - `withdrawCollateral`: state → transfer ✓
  - `drawLoan`: state → transfer ✓
  - `submitRepaymentProof`: proofConsumed → state → transfer ✓
  - `recoverDefaultedCollateral`: state → transfer ✓

### 3. Integer Overflow/Underflow ✅ Safe
- Solidity 0.8.25 checked arithmetic
- No assembly blocks
- Proper bounds checks on uint8/uint32 increments (lines 137–143)
- Arithmetic products stay within uint256 range (worst case ~1e41 << 1.15e77)

### 4. Front-Running ⚠️ Low Risk
- `drawLoan`: FTSO price can change between submission and execution, but FTSO is decentralized and staleness-checked
- `submitRepaymentProof`: borrower-only, proof-specific — not front-runnable
- `liquidate`: permissionless but non-reentrant — if borrower repays first, liquidation fails

### 5. Flash Loan ✅ Not Vulnerable
- FTSO price is off-chain oracle (not manipulable via flash loans)
- No on-chain price manipulation vectors
- View functions return on-chain state, not flash-loan-sensitive data

### 6. Oracle ✅ Strong (with caveat)
- FTSO staleness check present ✓
- Zero-price check present ✓
- **Caveat:** Future timestamps bypass staleness check (F4)
- Price is read at draw time only — no re-read at repayment

### 7. State Machine ✅ Strong
- Linear state progression: IDLE → COLLATERAL_DEPOSITED → ELIGIBILITY_PENDING → ELIGIBLE → FUNDED → CLOSED/DEFAULTED
- Every function enforces exact state requirement
- No backward transitions possible
- **Gap:** REJECTED state never reached (F10), no revocation of ELIGIBLE loans (F8)

### 8. Token Handling ✅ Strong
- SafeERC20 for all transfers
- FXRP: 6 decimals, USDT0: 18 decimals (code correct, comments wrong — F7)
- No approval patterns in the contract (borrowers approve externally)
- XRPL address binding: snapshot at draw time (L5 fix properly applied)

### 9. Edge Cases ✅ Mostly Covered
- Zero amounts: guarded in depositCollateral and drawLoan ✓
- Max values: uint256 overflow safe ✓
- Expired timestamps: checked at submitEligibility and drawLoan ✓
- Re-requesting eligibility: prevented by state machine ✓
- Partial withdrawal: not supported (full withdrawal only) ✓
- **Gap:** Attestation limit not enforced (F1), truncation in drops calculation (F9)

### 10. Governance ⚠️ Medium Risk
- Owner can pause/unpause: DoS vector (F3)
- Owner can revoke eligibility (but not already-eligible loans — F8)
- Owner can recover defaulted collateral
- No ownership transfer (F2)
- No time-locked operations
- No multisig requirement

---

## Pre-Audit Fixes Confirmed Present

| Fix | Description | Status |
|-----|-------------|--------|
| L1 | Re-check eligibility expiry at draw time | ✅ Present (line 321) |
| L2 | Avoid underflow panic on FTSO future timestamp | ✅ Present (line 339) |
| L4 | Track seized collateral per defaulted loan | ✅ Present (line 463) |
| L5 | Snapshot XRPL address hash onto loan at draw time | ✅ Present (line 331) |
| M1 | Signature malleability protection (s ≤ secp256k1 half) | ✅ Present (line 271) |
| M2 | Rotate nonce in revokeEligibility | ✅ Present (line 142) |

---

## Conclusion

CreditGateVault is a well-audited contract with strong security fundamentals. The most significant finding (F1 — attestation limit bypass) is a real vulnerability but is mitigated by the collateral ratio check, which provides an independent safety net. The governance findings (F2, F3) are design decisions appropriate for a hackathon but would need addressing in production.

**Risk assessment for hackathon:** LOW — the contract is safe for demo use with the identified caveats.
