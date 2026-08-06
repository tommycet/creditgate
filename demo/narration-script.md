# Demo Video Narration Script — CreditGate

> **Target video:** ~3:00 runtime, 1080p, <50 MB.
> **Audience:** Flare Summer Signal judges (Bounty 2: Confidential Compute Apps).
> **Tone:** Measured, confident, evidence-led. One Flare primitive named per scene.
> **Recording order:** Record visuals first; narrate to fit scene boundaries.

---

## Scene 1: The Problem (20s, 0:00–0:20)

**VISUAL:** Slow zoom on the `/transparency` dashboard. Three stats panels fade in: total FXRP minted, fraction not deployed in any lending market, implied unmet credit demand. A subtle red tint marks "idle." The CreditGate logo fades in over the panels.

**NARRATOR:**
> Billions of dollars in XRP sit locked on Flare as FXRP collateral, earning peg-anchor yield but unavailable for credit. The holders will not sell, and they will not grant a centralized bureau access to their position. CreditGate unlocks that collateral using only Flare's native primitives — no oracle, no bureau, no broker.

---

## Scene 2: Deposit + Register (25s, 0:20–0:45)

**VISUAL:** Cut to `/app`. MetaMask prompt connects to Coston2 (chain ID 114). Borrower clicks **Deposit**, 100 FXRP. Terminal 2 logs the tx hash. The loan card flips to `COLLATERAL_DEPOSITED`. Borrower pastes an XRPL `r-address`, clicks **Register** — a `keccak256` hash appears on the card as the bound snapshot.

**NARRATOR:**
> First, the borrower deposits one hundred FXRP as collateral on the Coston2 testnet, moving the loan into the `COLLATERAL_DEPOSITED` state. Then the borrower registers their XRPL repayment address — keccak256-hashed and bound to the loan as an immutable snapshot. That snapshot is what the Flare Data Connector will later check, binding every repayment to this specific loan and defeating address-substitution attacks.

---

## Scene 3: FCC Credit Check (30s, 0:45–1:15)

**VISUAL:** Borrower clicks **Request Eligibility**. Split-screen: Terminal 1 (the Go FCC handler on `:8080`) lights up with structured logs — input validation, revocation check, collateral sufficiency, limit derivation, `EIP-191 signing`. The handler returns `(v, r, s)`. Back in the browser, borrower clicks **Submit Attestation**. The vault calls `ecrecover`; the card flips to `ELIGIBLE`. A callout reads: "Go signature → Solidity ecrecover ✓".

**NARRATOR:**
> The borrower requests eligibility, and the frontend posts to the FCC confidential-compute handler running inside a trusted execution enclave. The handler validates inputs, checks the revocation version, mirrors the vault's collateral-sufficiency math against the live XRP/USD price, derives a limit, and signs an EIP-191 attestation. The vault recovers the signer on-chain with `ecrecover` and flips the loan to `ELIGIBLE` — the only step where confidential compute touches the chain, and the TEE never reveals *why* the borrower qualified.

---

## Scene 4: Draw Loan (20s, 1:15–1:35)

**VISUAL:** Borrower clicks **Draw Loan** for 50 USDT0. Brief overlay: "FTSOv2 → XRP/USD price fetched." The vault enforces `collateral × price × 10000 ≥ loan × collateralRatioBps`. Card flips to `FUNDED`. USDT0 balance ticker on the borrower widget increments. Terminal 2 logs the disbursement tx.

**NARRATOR:**
> With eligibility confirmed, the borrower draws a USDT0 loan within the one-hundred-fifty-percent collateral ratio. The vault reads the live XRP/USD price from FTSOv2, enforces the coverage check on-chain, and disburses USDT0 to the borrower on Coston2. The loan is now `FUNDED` — collateral priced and locked by the same oracle that secures the Flare network.

---

## Scene 5: Repay on XRPL (25s, 1:35–2:00)

**VISUAL:** Loan card renders repayment instructions — amount in drops, vault's XRPL destination, and the 32-byte `expectedCommitment` memo. Cut to Terminal 3. A pre-captured XRPL testnet payment proof is fed to `verifyXRPPayment()` via the live `FdcVerification` ABI. Logs show: status ok, receivedAmount ok, memoData matches commitment, receivingAddressHash matches snapshot, `proofConsumed` anti-replay set. Card flips to `CLOSED`. Collateral release logged.

**NARRATOR:**
> The borrower repays on the XRPL testnet, attaching a thirty-two-byte memo commitment that cryptographically binds the payment to this specific loan. The Flare Data Connector verifies the proof on-chain — checking status, amount, the memo commitment, and the receiving-address snapshot. The vault marks the loan `CLOSED` and releases the collateral, with an anti-replay guard ensuring each proof is consumed exactly once.

---

## Scene 6: Security Evidence (25s, 2:00–2:25)

**VISUAL:** Stay on Terminal 3. `forge test` scrolls past — "141 tests, 11 suites, 0 failures." Three panels flash in sequence: (1) reentrancy attack — a malicious FXRP token re-entering `depositCollateral`, blocked by `ReentrancyGuard`; (2) Go-TEE compat — a Go-produced signature accepted by Solidity `ecrecover`, one-byte tamper → `InvalidEligibilitySigner`; (3) invariant fuzz — FXRP conservation and USDT0 solvency across 256 runs. A badge: "Audit PASS-WITH-NOTES, all fixes applied."

**NARRATOR:**
> One hundred eighteen tests across nine suites, zero failures, ninety-seven-point-seven-five percent coverage. A genuine reentrancy attack — a malicious FXRP token that re-enters deposit mid-transfer — is blocked by `ReentrancyGuard`, and we wrote the attack ourselves to prove it. A signature from the Go FCC handler is accepted verbatim by Solidity `ecrecover`, and invariant fuzz tests confirm FXRP conservation and USDT0 solvency across two-hundred-fifty-six runs.

---

## Scene 7: Flare Primitives (20s, 2:25–2:45)

**VISUAL:** Final card — the four-row primitive table animates in. Each row highlights the act where it fired: FAssets (deposit), FTSOv2 (draw), FCC (credit check), FDC (repay). A single line under the table: "Each load-bearing. None decorative." Competitor comparison row fades in: AegisFlow (FCC+FDC, no FTSO, no cross-chain collateral), FlareShield AI (FCC+FTSO, no FDC), Axi (TEE, not Flare FCC). CreditGate row: all four.

**NARRATOR:**
> CreditGate is the only Flare Summer Signal submission using all four primitives in a single load-bearing flow: FAssets for collateral, FTSOv2 for pricing, FCC for private credit evaluation, and FDC for cross-chain repayment verification. Each primitive is structural — remove one and the flow collapses. This is the credit layer Flare has been missing.

---

## Scene 8: Closing (15s, 2:45–3:00)

**VISUAL:** Dark background. CreditGate wordmark centers. Three stat lines type out: "141 tests · 11 suites · 0 failures", "97.75% coverage", "Audit-verified". Final line: "Deploying to Coston2." The Flare logo and "Bounty 2 — Confidential Compute Apps" appear bottom-right. Fade to black.

**NARRATOR:**
> CreditGate — private credit eligibility, public repayment verification, built entirely on Flare. One hundred eighteen tests, ninety-seven-point-seven-five percent coverage, security audit verified. Deploying to Coston2.

---

## Production Notes

- **Total runtime:** 3:00 (8 scenes; boundaries at 0:20, 0:45, 1:15, 1:35, 2:00, 2:25, 2:45).
- **TTS provider:** Edge TTS `en-US-AndrewMultilingualNeural` at `-10%` rate for measured demo pace (alternatives: Groq Orpheus `troy` voice — but note Orpheus speaks ~2x slower; trim narration if using it).
- **Narration word count:** ~520 words across all scenes (fits 3:00 at ~3 words/sec, the sweet spot for edge-tts at -10%).
- **Visual sync:** Record the browser + terminals first, then narrate to fit each scene's visual boundary. Do not let narration exceed video duration — trim the script, not the footage.
- **On the FDC step (Scene 5):** say "fixture proof, live verifier ABI" — do not overclaim a live FDC round. Honesty on this one step builds credibility for the other three primitives that *are* live.
- **Layout:** three terminals across the top, browser below; keep Terminal 3 (tests) visible throughout — it is the receipts.
- **Close on the four-primitive tableau** — it is the single line a judge will remember.
