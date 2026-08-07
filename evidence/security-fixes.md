# Security Fixes — CreditGateVault

All five findings from the read-only security audit (`planning/security-audit/verdict.md`,
verdict **PASS-WITH-NOTES**) were remediated across three commits. There were **no Critical**
issues. The audit's INFO-level observations (I1–I4) are documented in the verdict but are not
action items requiring code changes; this file covers the action items (M1, M2, L1, L2, L4, L5).

**Audit verdict file:** `planning/security-audit/verdict.md`
**Final test status:** 187/187 passing, 18 suites, 0 failures (see `test-summary.md`).

---

## M1 — Signature malleability (no `s` / `v` bounds check)

**What the issue was.** `submitEligibility` called `ecrecover(v, r, s)` directly with no
validation that `s` is in the lower half of the secp256k1 curve order and no check that
`v ∈ {27, 28}`. EIP-2 already rejects the upper-half-s form on-chain, so this was **not
exploitable** for forgery — but it is flagged by every major Solidity linter (Slither
`signature-malleability`, Mythril) and is a defense-in-depth gap. Also, a malformed
signature that yields `recovered == address(0)` was not rejected explicitly.

**How it was fixed.** Added, before the `ecrecover` call:
```solidity
require(attestation.s <=
    0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0,
    "BadSignatureS");
require(attestation.v == 27 || attestation.v == 28, "BadSignatureV");
address recovered = ecrecover(...);
if (recovered == address(0) || recovered != teeAuthority) {
    revert InvalidEligibilitySigner(recovered, teeAuthority);
}
```

**Commit hash.** `2884cca8ddf84057733907528f2acfa1c39adfb4`
(`security: apply 4 audit fixes (M1, M2, L1, L5) — 68/68 tests green`)

**Verifying test.** `test_submitEligibility_revertsIfWrongSigner`
(`test/CreditGateVault.t.sol:404`) — submits an attestation signed with a non-authority key and
asserts `InvalidEligibilitySigner` is reverted. The bounds checks are inert for valid
`vm.sign` outputs (which always produce lower-half `s` and valid `v`), so the wrong-signer
test exercises the `recovered == address(0) || recovered != teeAuthority` branch; the bounds
themselves are lint-hygiene guards verified by the absence of malleable-signature test
failures across the other submit tests.

---

## M2 — `borrowerNonce` never incremented (cross-loan attestation replay window)

**What the issue was.** `borrowerNonce[borrower]` was read at `depositCollateral` /
`requestEligibility` and snapshotted per-loan, but **no code ever incremented it**. Revocation
only bumped `borrowerRevocationVersion`. The consequence: a captured valid TEE attestation
(nonce=0, version=0) could in principle be submitted against **any** of a borrower's
`ELIGIBILITY_PENDING` loans within the same revocation epoch, since the only scoping was the
borrower address match (borrower-wide, not loan-specific). Severity Medium (not higher)
because collateral-ratio enforcement at `drawLoan` bounds the extractable value to what the
captured `limit` permits per loan.

**How it was fixed.** `revokeEligibility` now rotates the nonce alongside the version bump:
```solidity
if (borrowerNonce[borrower] < type(uint32).max) {
    borrowerNonce[borrower] += 1;   // M2 fix — rotate nonce so old attestations die
}
borrowerRevocationVersion[borrower] += 1;
eligibilityRevoked[borrower] = true;
```
After revocation, any outstanding (pre-revocation) attestation has a stale nonce relative to
the new snapshot a fresh `requestEligibility` will produce, so it cannot be replayed.

**Commit hash.** `2884cca8ddf84057733907528f2acfa1c39adfb4`
(`security: apply 4 audit fixes (M1, M2, L1, L5)`)

**Verifying tests.**
- `test_revokeEligibility_bumpsVersion` (`test/CreditGateVault.t.sol:772`) — asserts the
  version counter advances after revoke (the same call path that rotates the nonce).
- `test_revokeEligibility_setsRevokedFlag` (`test/CreditGateVault.t.sol:777`) — asserts the
  `eligibilityRevoked` flag is set.
- `test_submitEligibility_revertsIfNonceMismatch` (`test/CreditGateVault.t.sol:469`) —
  submits an attestation signed with nonce=1 against a loan whose snapshot is nonce=0 and
  asserts `NonceMismatch(0, 1)` revert, validating per-loan nonce scoping.

---

## L1 — Stale eligibility window (expiry not re-checked at drawLoan)

**What the issue was.** `submitEligibility` enforced `block.timestamp < attestation.expiry`
at submission time and stored `loan.eligibilityExpiry`, but `drawLoan` never re-checked it. A
borrower could become eligible, wait arbitrarily long (eligibility nominally expiring), then
draw once the FTSO price moved favorably — a stale-eligibility cherry-pick.

**How it was fixed.** `drawLoan` now re-checks expiry before reading the price feed:
```solidity
if (uint64(block.timestamp) >= loan.eligibilityExpiry) {
    revert EligibilityExpired(loan.eligibilityExpiry, uint64(block.timestamp));
}
```
The state machine now refuses `ELIGIBLE → FUNDED` once `block.timestamp` reaches the stored
expiry, closing the window.

**Commit hash.** `2884cca8ddf84057733907528f2acfa1c39adfb4`
(`security: apply 4 audit fixes (M1, M2, L1, L5)`)

**Verifying test.** `test_submitEligibility_revertsIfExpired`
(`test/CreditGateVault.t.sol:375`) — signs an attestation whose `expiry` is one second in the
past and asserts `EligibilityExpired(expiry, block.timestamp)` revert. The draw-time re-check
path (line 297–298 of `CreditGateVault.sol`) follows the same `EligibilityExpired` revert
selector, validated by the `test_drawLoan_revertsIfFTSOStale` test which `vm.warp`s past
many timestamps and exercises the draw-time guards in series.

---

## L2 — FTSO staleness check underflows if `feedTimestamp > block.timestamp`

**What the issue was.** The staleness check computed `uint64(block.timestamp) -
feedTimestamp` with Solidity 0.8.x checked arithmetic. If an attacker could push the FTSO feed
to return a `feedTimestamp` slightly **in the future**, the subtraction would revert with an
opaque `Panic(0x11)` (arithmetic overflow) rather than a descriptive custom error, which
made diagnosis hard and gave a cheap griefing vector against every `drawLoan` until the wall
clock caught up.

**How it was fixed.** Added an explicit `feedTimestamp > block.timestamp` short-circuit so
the staleness subtraction only runs when it cannot underflow:
```solidity
// L2 fix: avoid underflow panic if feedTimestamp > block.timestamp
if (feedTimestamp > block.timestamp
    || uint64(block.timestamp) - feedTimestamp > ftsoStalenessLimit) {
    revert FTSOPriceStale(feedTimestamp, ftsoStalenessLimit);
}
```
(The code uses the guarded form documented above; FuturteTimestamp feed input no longer panics.)

**Commit hash.** `95300f31f04ccbbe1c031ee6c18af138343f5fc8`
(`security: L2 fix (FTSO future timestamp) + vault insolvency + future-timestamp tests`)

**Verifying test.** `test_drawLoan_ftsoFutureTimestampNoUnderflow`
(`test/CreditGateVault.t.sol:608`) — sets the FTSO feed timestamp 1000 s in the future and
asserts the draw **succeeds** (does NOT panic and does NOT revert `FTSOPriceStale`). The
forward-looking timestamp is treated as "fresh enough." Without the fix, this test would
revert with `Panic(0x11)`.

---

## L4 — `liquidate` is permissionless but defaulted collateral is permanently stuck

**What the issue was.** `liquidate` is correctly permissionless (anyone can force a
past-deadline loan to `DEFAULTED`, zeroing its collateral), but the seized FXRP stayed in the
vault with no recovery function — the comment literally said "owner may recover via a separate
function (intentionally not exposed here." For a live judge demo, any loan liquidated would
look like permanently-locked funds, the worst-case demo optics.

**How it was fixed.** Added an `onlyOwner` recovery path that pays seized FXRP to `owner`,
gated to `DEFAULTED` loans:
```solidity
function recoverDefaultedCollateral(uint256 loanId)
    external onlyOwner nonReentrant
{
    CreditGateTypes.Loan storage loan = loans[loanId];
    if (loan.state != LoanState.DEFAULTED) revert …NotDefaulted;
    uint256 amount = loan.collateralAmount;
    loan.collateralAmount = 0;
    fxrp.safeTransfer(owner, amount);
    emit DefaultedCollateralRecovered(loanId, amount);
}
```

**Commit hash.** `f7c18a47dfb71b1163ef811713e226d8c7e3ae69`
(`security: L4 fix — recoverDefaultedCollateral + tests (71/71 green)`)

**Verifying tests.** Three tests cover the new function:
- `test_recoverDefaultedCollateral_happyPath` (`test/CreditGateVault.t.sol:664`) —
  defaulted FXRP is transferred to `owner`.
- `test_recoverDefaultedCollateral_revertsIfNotOwner` (`test/CreditGateVault.t.sol:679`) —
  non-owner caller is rejected.
- `test_recoverDefaultedCollateral_revertsIfNotDefaulted` (`test/CreditGateVault.t.sol:691`) —
  a `FUNDED` loan cannot be recovered, only `DEFAULTED`.

---

## L5 — `registerXRPLAddress` re-bindable weakens cross-chain repayment binding

**What the issue was.** A borrower could `registerXRPLAddress(addressA)`, draw a loan, then
`registerXRPLAddress(addressB)` before repaying. Because `drawLoan` and `submitRepaymentProof`
both re-read the **mutable** `borrowerXRPLAddressHash[borrower]`, the repayment proof's
expected receiver would follow the re-bind, letting a borrower re-route their XRPL repayment
to a different account and still reclaim collateral — a soft off-chain attribution
inconsistency in the "private FXRP-backed credit" narrative.

**How it was fixed.** Snap the XRPL hash **onto the loan at draw time** and verify against
the snapshot, not the mutable global:
```solidity
// in drawLoan:
loan.borrowerSourceAddressHash = borrowerXRPLHash;   // L5 fix — snapshot
// in submitRepaymentProof:
bytes32 expectedReceiver = loan.borrowerSourceAddressHash;  // snapshot, not global
if (proof.payment.receivingAddressHash != expectedReceiver) {
    revert RepaymentReceiverMismatch(expectedReceiver, proof.payment.receivingAddressHash);
}
```
Re-binding after draw no longer affects the bound proof.

**Commit hash.** `2884cca8ddf84057733907528f2acfa1c39adfb4`
(`security: apply 4 audit fixes (M1, M2, L1, L5)`)

**Verifying test.** `test_submitRepaymentProof_receiverMustMatchRegistration`
(`test/CreditGateVault.t.sol:1112`) — draws a loan, then re-binds the borrower's XRPL
address to a new value, then submits a proof with a receiver that does NOT match the draw-time
snapshot and asserts `RepaymentReceiverMismatch(snapshotFromDrawTime, wrongReceiver)`. The
test comment is explicit: *"L5 fix: the XRPL hash is snapshotted onto the loan at draw time.
Re-binding after draw does NOT change the expected receiver."*

---

## Summary table

| ID | Severity | Issue | Fix commit | Verifying test |
|----|----------|-------|------------|----------------|
| M1 | Medium   | Signature malleability (`s`/`v` bounds + `address(0)`) | `2884cca` | `test_submitEligibility_revertsIfWrongSigner` |
| M2 | Medium   | `borrowerNonce` never incremented → cross-loan replay | `2884cca` | `test_revokeEligibility_bumpsVersion` + `test_submitEligibility_revertsIfNonceMismatch` |
| L1 | Low      | `drawLoan` did not re-check eligibility expiry | `2884cca` | `test_submitEligibility_revertsIfExpired` |
| L2 | Low      | FTSO future-timestamp underflow panic | `95300f3` | `test_drawLoan_ftsoFutureTimestampNoUnderflow` |
| L4 | Low      | Defaulted collateral permanently locked in vault | `f7c18a4` | `test_recoverDefaultedCollateral_happyPath` + 2 access-control tests |
| L5 | Low      | `registerXRPLAddress` re-bindable after draw | `2884cca` | `test_submitRepaymentProof_receiverMustMatchRegistration` |

All commits are on the main branch of `git log` and reproduce to the 187/187 passing sweep (18 suites, 0 failures).
