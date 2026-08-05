# Security Audit — CreditGateVault — 2026-08-05

**Auditor:** Solidity security review (subagent)
**Target:** `src/CreditGateVault.sol` (443 lines) + `src/CreditGateTypes.sol` (141 lines)
**Compiler:** `^0.8.25` (Solidity ≥0.8.x: built-in overflow/underflow checks ON by default)
**Scope:** read-only review; no code modified, no forge/tests executed.

---

## Verdict: PASS-WITH-NOTES

The vault is a well-structured, hackathon-grade contract that demonstrates good security hygiene: `ReentrancyGuard` on every external entry point, `SafeERC20` for all token transfers, EIP-191 signing, FDC memo-binding, and a clear state machine with per-loan scoping. There are **no Critical issues**. Several issues below are worth noting for a production hardening pass, but none invalidate the demonstration. The contract is safe to present to judges as written.

---

## Issues found

### MEDIUM

#### M1. Signature malleability — no `s` / `v` bounds check in `submitEligibility`
**File:** `src/CreditGateVault.sol:238-240`
**Description:** `ecrecover` is called directly with `attestation.v, attestation.r, attestation.s` with no validation that `s` is in the lower half of the curve order (`s <= secp256k1n / 2`) and no check that `v ∈ {27, 28}`. EIP-2 makes signatures with `s > n/2` invalid on the chain, so `ecrecover` will return `address(0)` for the "flipped" form and the signer check `recovered != teeAuthority` will fail — so this is **not exploitable** for forgery. However, a malicious observer who captures a valid (r, s, v) can re-derive a second valid (r, -s mod n, v') form. Because attestation replay is already bounded by `(borrower, nonce, revocationVersion)` and the nonce is per-loan-scoped at `requestEligibility` (line 192), the malleated duplicate would still only succeed for the same loan in state `ELIGIBILITY_PENDING`, which is idempotent (transitioning `ELIGIBLE → ELIGIBLE`). The practical impact is limited but the pattern is flagged by every major linter (Slither `signature-malleability`, Mythril `eth_sendTransaction` malleability).
**Impact:** No value loss; linter noise; defense-in-depth gap.
**Recommendation:** Add `require(attestation.s <= 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0, "BadS")` and `require(attestation.v == 27 || attestation.v == 28, "BadV")` before the `ecrecover` call, or use OpenZeppelin's `ECDSA.recover` (already transitively available via `@openzeppelin/contracts/utils/cryptography/ECDSA.sol`) which performs these checks internally. Also reject `recovered == address(0)` explicitly.

---

#### M2. `borrowerNonce` is never incremented — attestation scope relies on loan-id only
**File:** `src/CreditGateVault.sol:47, 152, 192`
**Description:** The borrower nonce (`borrowerNonce[msg.sender]`) is read in `depositCollateral` (line 152) and snapshotted in `requestEligibility` (line 192), but **no code ever increments it**. The revocation path bumps `borrowerRevocationVersion` (line 120), not the nonce. The result: every loan a borrower ever creates snapshots the same `eligibilityNonce` (whatever the initial value is — `0` for a fresh account, or the value it was bumped to by the now-absent increment). This weakens the intended replay guarantee. Concretely: if a TEE signs an attestation for loan A (nonce 0, version 0), and the borrower then revokes and re-requests for loan B, the borrower's `borrowerRevocationVersion` blocks the **old** attestation (good), but the **nonce** offers no additional scope — the only thing tying the attestation to a specific loan is the `loan.borrower == attestation.borrower` and `attestation.borrower != loan.borrower` checks via the `NotBorrower` modifier, which is borrower-wide, not loan-specific.
**Impact:** Two consequences:
  1. **Cross-loan attestation reuse within the same revocation epoch.** A single valid TEE attestation (borrower, limit, expiry, nonce=0, version=0) could in principle be submitted against **any** of the borrower's loans currently in `ELIGIBILITY_PENDING` with the same nonce snapshot. Since `eligibilityNonce` is snapshotted per loan at request time and is identical across all un-revoked requests, the same signed attestation can transition multiple loans from `ELIGIBILITY_PENDING → ELIGIBLE`. Attacker who captured one attestation gets permissive eligibility on multiple collateral slots.
  2. The intended "rotate the nonce so old attestations die" semantic is not implemented.
**Exploitability:** Requires a captured attestation that the borrower allowed to leak *and* multiple loans in `ELIGIBILITY_PENDING` for the same borrower simultaneously. Each loan still needs its own collateral deposit, and over-borrowing is bounded by the collateral-ratio check at `drawLoan`. So the attacker cannot extract value beyond what the captured `limit` permits per loan — but they can activate loans the borrower himself did not intend to draw. Medium, not higher.
**Recommendation:** Increment `borrowerNonce[msg.sender]++` inside `revokeEligibility` (alongside the version bump) so that every revocation rotates the nonce and fully invalidates outstanding attestations. Alternatively, increment the nonce on each `requestEligibility` call so each loan gets a distinct nonce; the TEE then signs per-loan.

---

### LOW

#### L1. `eligibilityExpiry` stored but `drawLoan` does not re-check it
**File:** `src/CreditGateVault.sol:252, 264-326`
**Description:** `submitEligibility` enforces `block.timestamp < attestation.expiry` (line 213) at attestation submission time, and stores `loan.eligibilityExpiry = attestation.expiry`. But `drawLoan` never re-checks whether the eligibility has expired between attestation and draw. A borrower could obtain eligibility, wait arbitrarily long (eligibility expires), then draw once the price has moved favorably. The state machine still allows `ELIGIBLE → FUNDED` indefinitely.
**Impact:** Stale eligibility window; borrower can cherry-pick the price feed after their eligibility is nominally expired.
**Recommendation:** In `drawLoan`, add `if (uint64(block.timestamp) >= loan.eligibilityExpiry) revert EligibilityExpired(loan.eligibilityExpiry, uint64(block.timestamp));` before the price read.

---

#### L2. FTSO staleness check underflows if `feedTimestamp > block.timestamp`
**File:** `src/CreditGateVault.sol:286`
**Description:** `uint64(block.timestamp) - feedTimestamp` is unchecked subtraction. Solidity 0.8.x will revert on underflow, which is the *safe* behavior here (it would just revert the draw), so this is not exploitable. But the revert reason would be an opaque `Panic(0x11)` rather than a custom `FTSOPriceStale` error, making diagnosis harder. Additionally, if an attacker could manipulate the FTSO to return a `feedTimestamp` slightly in the future, every draw would revert until `block.timestamp` caught up — a cheap griefing vector if the FTSO feed is permissionless.
**Impact:** Diagnosis friction; low-severity griefing possibility.
**Recommendation:** Compare with `>` instead: `if (block.timestamp > feedTimestamp && uint64(block.timestamp) - feedTimestamp > ftsoStalenessLimit)`. Or wrap the subtraction and revert with a custom error on underflow.

---

#### L3. `borrowerLoanIds` is append-only — no cap, no removal
**File:** `src/CreditGateVault.sol:53, 154`
**Description:** Every `depositCollateral` pushes a loan id into `borrowerLoanIds[msg.sender]` and nothing ever removes or compacts it. A borrower can call `depositCollateral(1)` in a tight loop to bloat the array (each call costs one SSTORE write plus array growth). Because `nextLoanId` is unbounded and gas is paid by the caller, the only DoS surface is that `getBorrowerLoanIds` for a spammed borrower grows linearly, which could price out off-chain indexing or push the view call over the block gas limit.
**Impact:** Storage bloat / view-call DoS for a specific borrower; limited because only the borrower themselves can push (line 149 `loan.borrower = msg.sender`). No cross-user impact. Not a protocol-wide DoS.
**Recommendation:** For a hackathon this is acceptable. For production, gate `depositCollateral` with a per-borrower active-loan cap and/or remove the id from the array when the loan transitions to `IDLE/CLOSED/DEFAULTED`.

---

#### L4. `liquidate` is permissionless and `DEFAULTED` collateral is stuck in the vault
**File:** `src/CreditGateVault.sol:393-407`
**Description:** Anyone can call `liquidate(loanId)` for any loan whose deadline has passed (`block.timestamp >= loan.deadline`). The collateral is zeroed on the loan and stays in the vault — the code comment (line 403-404) explicitly says "owner may recover via a separate function (intentionally not exposed here)". But **no such recovery function exists in this contract**, and `owner` is a plain `address` (not an Ownable abstract; no transfer-ownership path either). The seized FXRP is permanently locked until a future contract upgrade or a rescue function is added.
**Impact:**
  - Permissionless liquidation is actually *correct* for keeping the protocol honest (anyone can force a defaulted loan to `DEFAULTED`), so this is a feature not a bug. But the collateral is then unrecoverable, which is a funds-stuck risk.
  - No `onlyOwner` recovery path means a judge running this live would see collateral permanently locked on any defaulted loan — which is the worst case for a demo because it looks like lost funds.
**Recommendation:** Add an `onlyOwner function recoverDefaultedCollateral(uint256 loanId)` (or a batch variant) that pays seized FXRP to `owner`, gated by `loan.state == DEFAULTED`. This is a one-liner and likely a Hackathon polish item, not a security flaw.

---

#### L5. `registerXRPLAddress` allows re-binding — weakens repayment binding
**File:** `src/CreditGateVault.sol:128-131`
**Description:** Any borrower can call `registerXRPLAddress` at any time and overwrite their previously registered XRPL address hash. Because `drawLoan` reads the binding at draw time (line 278) and `submitRepaymentProof` re-reads it at repayment time (line 364), a borrower could register address A, draw a loan, then re-register to address B before repaying. The repayment proof's `receivingAddressHash` must match the **current** binding, so a borrower who controls both addresses can move the repayment target.
**Impact:** This is not an attack *on the protocol* (the borrower is the only party at risk and the commitment still binds loanId+amount+deadline), but it weakens the off-chain attribution story: a borrower could draw a loan, then route repayment to a different XRPL account and still reclaim collateral. For the "private FXRP-backed credit" narrative this is a soft inconsistency, not a value loss.
**Recommendation:** Snap the XRPL hash **onto the loan** at `drawLoan` time (`loan.borrowerSourceAddressHash = borrowerXRPLAddressHash[msg.sender]`) and check against `loan.borrowerSourceAddressHash` in `submitRepaymentProof` instead of re-reading the mutable global. The struct already has the `borrowerSourceAddressHash` field (line 51) — it is declared, never written, never read. Wire it up.

---

### INFO

#### I1. `Loan.borrowerSourceAddressHash` field is dead code
**File:** `src/CreditGateTypes.sol:51`
**Description:** The struct field `bytes32 borrowerSourceAddressHash` is declared but never assigned (no `loan.borrowerSourceAddressHash = ...` anywhere) and never read. It exists presumably to support L5's intended design. Either wire it up (see L5) or remove it to avoid confusion.
**Impact:** None (dead storage costs extra gas per loan write — ~20k gas per loan, but the field is never written so it's just a struct slot that stays zero).
**Recommendation:** Wire up per L5, or delete the field.

---

#### I2. `loan.eligibilityExpiry` and `LoanState.REJECTED` / `REPAYMENT_PENDING` are vestigial
**File:** `src/CreditGateVault.sol:252`; `src/CreditGateTypes.sol:30, 36`
**Description:**
  - `REPAYMENT_PENDING` (enum 5) is never entered anywhere — `drawLoan` transitions `ELIGIBLE → FUNDED` directly.
  - `REJECTED` (enum 7) is never entered — `submitEligibility` reverts on failure rather than storing the rejection state. The `EligibilityRejected` event (Types line 85) is declared but never emitted.
  - `loan.eligibilityExpiry` is written (line 252) but never read (see L1).
**Impact:** None functionally; just dead code that adds reading cost for reviewers and gas cost for storage writes.
**Recommendation:** Either implement the rejected-state path (state transitions to `REJECTED` and emits `EligibilityRejected` so the borrower knows *why* on-chain) or simplify the enum and remove unused artifacts.

---

#### I3. `owner` is a plain `address`, no two-step transfer, no renounce
**File:** `src/CreditGateVault.sol:41, 101`
**Description:** `owner = msg.sender` in constructor; no `transferOwnership` / `renounceOwnership` / accept-pattern. The owner can pause/unpause/revoke but cannot transfer the role. If the deployer key is lost, the protocol can never be unpaused or have eligibility revoked again (though borrowers can still self-serve the rest of the flow, so the impact is contained).
**Impact:** Operational rigidity; acceptable for a hackathon demo. For production use OpenZeppelin `Ownable2Step`.
**Recommendation:** Use `Ownable` from OpenZeppelin (you already import `ReentrancyGuard` from the same library) — gets you `transferOwnership`, `renounceOwnership`, and the `onlyOwner` modifier for free, replacing the hand-rolled modifier at line 64.

---

#### I4. `borrowerRevocationVersion` and `eligibilityRevoked` overlap in semantics
**File:** `src/CreditGateVault.sol:48-49, 116-122, 216-222`
**Description:** Both `eligibilityRevoked[borrower]` (a `bool`) and `borrowerRevocationVersion[borrower]` (a `uint8`) track revocation state. The check at line 217 is `revoked && attestation.revocationVersion <= borrowerRevocationVersion[borrower]`. If `eligibilityRevoked` were ever reset to `false` (no such function exists today), the version alone would not block — the flag gates the version check. This is fine for current code (revocation is one-way) but the dual-mechanism invites bugs if a future "un-revoke" path is added.
**Impact:** None currently; maintainability smell.
**Recommendation:** Keep both, document the invariant ("once revoked, never un-revoked except by owner via a future path that also bumps the version"), or consolidate to version-only with `borrowerRevocationVersion > 0 ⟹ revoked`.

---

## Per-checklist summary (answers to the audit brief)

1. **Signature verification (`submitEligibility`)** — EIP-191 prefix is correct (`\x19Ethereum Signed Message:\n32`), domain separator is hashed into the payload, signer is checked against immutable `teeAuthority`. **Malleability bounds missing (M1)** but not exploitable for forgery due to EIP-2. `v`/`s` should be range-checked for hygiene. No `recovered == address(0)` guard, but `address(0) != teeAuthority` (constructor requires non-zero) so a malformed signature that yields `address(0)` is correctly rejected.
2. **Replay protection** — Stale-attestation replay is blocked by `expiry` (line 213). Cross-loan replay within a revocation epoch is **weakly blocked (M2)** — the nonce is per-borrower not per-loan and never incremented, so the only true scoping is the borrower address match. Revocation replay is blocked by `revocationVersion` comparison. **Recommend bumping nonce on revocation (M2).**
3. **Reentrancy** — `nonReentrant` is on **all 8 external mutating entry points** (`depositCollateral`, `withdrawCollateral`, `requestEligibility`, `submitEligibility`, `drawLoan`, `submitRepaymentProof`, `liquidate`, plus `pause`/`unpause`/`revokeEligibility`/`registerXRPLAddress` are protected by `onlyOwner`/`whenNotPaused` or are trivial). State changes (zeroing collateral, advancing state) consistently happen **before** the `safeTransfer` external call in `withdrawCollateral` (lines 171-175), `drawLoan` (lines 314-321), and `submitRepaymentProof` (lines 381-385). ✅ Good.
4. **Access control** — `pause`/`unpause`/`revokeEligibility` are `onlyOwner` ✅. `liquidate` is intentionally permissionless (correct for trustless default) ✅. All borrower-flow functions enforce `loan.borrower == msg.sender` (the `NotBorrower` require) ✅. No missing auth found. `owner` cannot be transferred (I3) — operational, not security.
5. **Integer math** — **No `unchecked` blocks anywhere.** Solidity 0.8.x revert-on-overflow is in full force. `requiredRepaymentDrops = loanAmount * 1e18 / xrpUsd18dp` (line 306): `loanAmount * 1e18` cannot overflow for realistic 6-decimal loan amounts (max realistic ~1e15 → product 1e33 < 2^256). Collateral math at line 294-297 uses `collateralUsd18 * 10000` and `loanUsd18 * collateralRatioBps` — both safe for realistic magnitudes; would only overflow at astronomically large collateral (~1e51 units of 6dp FXRP, i.e. 1e45 USD), not reachable. `int256(resp.receivedAmount)` cast at line 356: if `resp.receivedAmount` is a `uint256` interpreted as `int256`, values ≥ 2^255 would wrap to negative and the `<` comparison would reject — safe-by-rejection. ✅
6. **FDC proof verification** — `proofConsumed[proofHash]` is set **after** verification (line 378) and the check is **before** verification (line 346), correctly preventing double-consume. `proofHash = keccak256(abi.encode(proof))` is deterministic over the entire `Proof` struct, so the same proof cannot be replayed. **Front-running is not a concern** because the proof can only close the loan it's bound to (via `expectedCommitment` match on `loanId + borrower + amount + deadline`), and only `loan.borrower` can submit (line 342). ✅ Excellent.
7. **Collateral accounting** — Borrower cannot withdraw more than deposited: `withdrawCollateral` zeroes `loan.collateralAmount` (line 172) before `safeTransfer(msg.sender, amount)` (line 175) where `amount == loan.collateralAmount`. `submitRepaymentProof` zeroes collateral (line 382) before transfer (line 385). `liquidate` zeroes collateral (line 401) and does **not** transfer it (collateral stays in vault — see L4). No path lets a borrower extract collateral they didn't deposit. ✅
8. **Deadline / FTSO freshness** — `FtsoV2Interface.getFeedByIdInWei` returns `(price, timestamp)`. Zero-price is rejected (line 285, `FTSOPriceZero`). Staleness check (line 286) rejects if `block.timestamp - feedTimestamp > ftsoStalenessLimit`. ✅ Correct. Minor edge case if `feedTimestamp > block.timestamp` (L2) — reverts with opaque panic code, safe but ungainly.
9. **Eligibility expiry** — Checked at `submitEligibility` time (line 213). **Not re-checked at `drawLoan` time (L1)** — expired eligibility can still be drawn. Medium-low severity.
10. **Replay across loans** — Addressed in M2: weak per the nonce design. The commitment (`_computeCommitment`) correctly binds `loanId` and `address(this)` (lines 432-441), so a repayment proof for loan A cannot close loan B. ✅ for repayment; ⚠️ for eligibility (M2).
11. **Edge cases**:
    - **Zero-amount deposit** → `revert ZeroAmount()` (line 145) ✅
    - **Zero-amount loan** → `revert ZeroAmount()` (line 275) ✅
    - **Self-liquidation** → not a concept here (no liquidation reward to front-run); any caller can liquidate a defaulted loan, which only zeroes collateral in-vault. No MEV from self-liquidation ✅
    - **Drawing 0 loan** → rejected ✅
    - **Repaying wrong amount** → `InsufficientRepayment` if `receivedAmount < requiredRepaymentDrops` (line 356). Note: **overpayment is accepted** (you can repay more drops than required and still close the loan — the excess is not refunded, which is borrower-friendly but means the borrower loses the overage). This is acceptable for a credit gate.
    - **Repaying to wrong XRPL address** → blocked by `RepaymentReceiverMismatch` (line 366) ✅ (but see L5 for the re-binding weakness).
    - **Memo missing / wrong length / wrong commitment** → blocked (lines 370-376) ✅

---

## Positive findings

1. **`ReentrancyGuard` on all entry points + state-before-external-call** — textbook adherence to the checks-effects-interactions pattern. This is the single most important defensive pattern and it's correctly applied everywhere tokens move.
2. **`SafeERC20` used throughout** — `safeTransfer` / `safeTransferFrom` (lines 156, 175, 321, 385) correctly handle non-reverting ERC-20s. Pulling collateral via `transferFrom` (not `approve`-then-`transfer`) is the modern approach.
3. **Commitment binding is strong** — `_computeCommitment` (line 426) hashes `protocolVersion + address(this) + loanId + borrower + amount + deadline`. Including `address(this)` means a redeployed vault with the same loan id cannot accept proofs minted for the old vault. Including `loanId` + `borrower` + `amount` + `deadline` means proofs are loan-specific. This is the right design for FDC memo-binding.
4. **XRPL receiver binding** — `registerXRPLAddress` + `RepaymentReceiverMismatch` (lines 128-131, 364-368) closes the "repay to a different XRPL address" substitution attack. The design intent is sound even though the implementation has a re-binding weakness (L5).
5. **FDC anti-replay** — `proofConsumed` mapping (line 50, 346, 378) correctly prevents double-closing a loan with the same proof, and the check-then-set ordering is correct.
6. **Permissionless liquidation** — letting anyone call `liquidate` once the deadline passes is the *correct* choice for a trustless protocol; it prevents the owner from protecting defaulted borrowers.
7. **Custom errors throughout** — `CreditGateTypes` defines descriptive custom errors (`InsufficientCollateral`, `FTSOPriceStale`, `CommitmentMismatch`, etc.) which is better than string reverts for both gas and DX. Each revert path emits a structural error.
8. **Immutability** — all config (`fxrp`, `usdt0`, `teeAuthority`, `collateralRatioBps`, `ftsoV2`, `fdcVerification`, `loanDuration`) is `immutable`, preventing post-deploy tampering.
9. **Zero-address guards in constructor** (lines 86-91) — rejects misconfigured deployment up front.
10. **EIP-191 prefix is correctly applied** — `keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash))` (lines 235-237) is the canonical EIP-191 personal-sign layout. Many hackathon contracts get this wrong; this one doesn't.

---

## Bottom line for hackathon judges

**CreditGateVault is a competently-engineered, auditable contract that implements a non-trivial cross-chain credit flow (Flare FTSOv2 price + FDC XRPL payment verification + TEE eligibility attestations + memo-binding) without introducing exploitable value-loss paths.** The four "MEDIUM/LOW" items (M1 signature-malleability hygiene, M2 nonce-not-incremented weakening cross-loan eligibility replay resistance, L1 no re-check of eligibility expiry at draw time, L4 defaulted collateral has no recovery path) are real polish gaps a serious auditor would flag, but none of them allow an attacker to steal funds, drain the vault, or forge an attestation. The contract correctly uses OpenZeppelin `ReentrancyGuard` + `SafeERC20` on every external call, follows checks-effects-interactions, scopes repayment proofs to a specific loan via a cryptographically-bound commitment, and rejects zero-price / stale FTSO feeds. The biggest demonstration risk for a live demo is **L4**: any loan you liquidate during the demo will permanently lock its FXRP in the vault with no `onlyOwner` recovery function — add a one-line `recoverDefaultedCollateral` before showing liquidation live, or avoid liquidating during the demo. For a hackathon this is a strong, defensible submission; for production, address M1+M2 and add Ownable + a collateral recovery path.
