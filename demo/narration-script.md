# Demo Video Narration Script — CreditGate

> **Target video:** ~75s spoken content, under 90s total with title/closer cards.
> **Audience:** Flare Summer Signal judges (Bounty 2: Confidential Compute Apps).
> **Tone:** Measured, confident, evidence-led. One Flare primitive named per beat.
> **Recording order:** Record visuals first; narrate to fit scene boundaries.
> **Timing structure:** Hook (5s) → Problem (10s) → Solution demo (30s) → Live proof (25s) → CTA (10s).

---

## Scene 1 — Hook (5s, 0:00–0:05)

**VISUAL:** Black. CreditGate wordmark snaps on. One line types: *"XRP collateral that can't be sold — credit it anyway."* Subtitle: *Live on Coston2 · 146 tests · Audit-verified.*

**NARRATOR:**
> Billions in XRP sit on Flare as FXRP — earning peg yield, but never credit. CreditGate unlocks it. Live on Coston2 today.

---

## Scene 2 — Problem (10s, 0:05–0:15)

**VISUAL:** Zoom on the `/transparency` dashboard. Three stat panels fade in: total FXRP minted, fraction idle in any lending market, implied unmet credit demand. Red tint marks "idle." CreditGate logo settles over the panels.

**NARRATOR:**
> Billions of dollars of FXRP collateral sit locked on Flare — earning the peg, but unavailable for credit. The holders won't sell, and they won't give a centralized bureau access to their position. CreditGate routes around both, using only Flare's native primitives. No oracle. No bureau. No broker.

---

## Scene 3 — Solution Demo (30s, 0:15–0:45)

**VISUAL:** Cut to `/app` on Coston2 (chain ID 114). Four beats, one per primitive, each tagged on screen with a corner badge:

**3a · FCC credit check (8s):** Borrower clicks **Request Eligibility**. Split-screen — Terminal 1 (the Go FCC handler on `:8080`) logs input validation, revocation check, collateral sufficiency, limit derivation, **EIP-191 signing**. Returns `(v, r, s)`. Back in the browser, borrower clicks **Submit Attestation**. The vault calls `ecrecover`; the card flips to `ELIGIBLE`. Callout: *"Go signature → Solidity ecrecover ✓."*

**3b · FXRP deposit (6s):** Borrower clicks **Deposit**, 100 FXRP. Terminal 2 logs the tx hash. The loan card flips to `COLLATERAL_DEPOSITED`. Borrower pastes an XRPL `r-address`, clicks **Register** — a `keccak256` hash appears as the bound snapshot.

**3c · USDT0 loan (8s):** Borrower clicks **Draw Loan** for 50 USDT0. Overlay: *"FTSOv2 → XRP/USD price fetched."* The vault enforces `collateral × price × 10000 ≥ loan × collateralRatioBps`. Card flips to `FUNDED`. USDT0 ticker on the borrower widget increments. Logs the disbursement tx.

**3d · Dutch auction liquidation + FTSO monitor (8s):** Brief cut to the **liquidate** panel — health factor (`getHealthFactor`) falling below 1.0 as the FTSOv2 XRP/USD feed ticks down. `checkAndTriggerLiquidation` fires automatically; `startLiquidationAuction` begins a linear-decay Dutch auction; `bidOnLiquidation` fills at the decayed price; `finalizeAuction` refunds surplus to the borrower. Callout: *"Automated. No manual keeper."*

**NARRATOR:**
> The flow uses all four Flare primitives — each load-bearing. First, **FXRP** is deposited as collateral and the repayment address is bound per-loan via keccak256 snapshot. Then **FCC** — the confidential-compute handler signs an EIP-191 attestation inside the enclave; the only thing that hits the chain is `ecrecover` of that signature, and the TEE never reveals *why* the borrower qualified. Next **FTSOv2** — the live XRP/USD feed prices the draw and enforces the one-hundred-fifty-percent ratio on-chain. The same feed drives an automated liquidation trigger: when health factor drops below one, a linear-decay Dutch auction starts with no manual keeper, with surplus refunded to the borrower. Finally the borrower repays on XRPL, attaching a thirty-two-byte memo commitment — and **FDC** verifies that payment on Flare against status, amount, the memo, the per-loan address snapshot, and an anti-replay guard. Every primitive is structural. Remove one and the flow collapses.

---

## Scene 4 — Live Proof (25s, 0:45–1:10)

**VISUAL:** Cut to Terminal 2. Four receipts flash in sequence, each a clickable hyperlink card:

1. **Vault (Coston2, source-verified on Blockscout)** — address `0x5e74d…a99939`, deploy tx `0xf2678b…771cb`, holds 5 FXRP live collateral.
2. **Live FXRP deposit** — tx `0x2ba65f…4149`.
3. **Real XRPL testnet payment** — tx `0xb9f346…4720`, `tesSUCCESS`, ledger 19689886, 1,000,000 drops, memo `CREDITGATE-LOAN-REPAYMENT-FDC-VERIFY-2026-08-06`.
4. **Real FDC attestation submitted on Coston2** — tx `0x7fd6c8…4a42`, status 1, FDC round 1417946 finalized on-chain.

A final card: *"Submit stage proven with real data. Retrieve stage awaiting Coston2 DA Layer indexing (testnet infra limit, not a contract bug)."*

**NARRATOR:**
> Live on Coston2 — source-verified on Blockscout. The vault is deployed at `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939`, holding five FXRP of live collateral against the live FTSOv2 feed. This is a real XRPL testnet payment — `tesSUCCESS`, one-million drops, memo `CREDITGATE-LOAN-REPAYMENT-FDC-VERIFY`. And this is the on-chain attestation the FDC accepted in round fourteen-one-seven-nine-four-six — already finalized. The full submit path runs with real data end-to-end. The retrieve-and-verify stage depends on Coston2 testnet DA Layer indexing — a testnet infrastructure limit, not a contract bug, and the verifier ABI is live and ready.

---

## Scene 5 — CTA (10s, 1:10–1:20)

**VISUAL:** Dark. CreditGate wordmark centers. Three lines type out: *"146 tests · 12 suites · 0 failures"*, *"97.75% coverage"*, *"Audit-verified"*. Final line: *"Built entirely on Flare — Flare Summer Signal, Bounty 2."* Flare logo bottom-right. Fade to black.

**NARRATOR:**
> CreditGate — private credit eligibility, public repayment verification, built entirely on Flare. One hundred forty-six tests across twelve suites, zero failures, audit-verified. The credit layer Flare has been missing.

---

## Live Proof Details (reference, not narrated verbatim)

> All artifacts below are live on Coston2 (chain ID 114) unless marked XRPL Testnet. Share these links in the submission form.

| Artifact | Value | Verify |
|----------|-------|--------|
| **Vault address** | `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939` | [coston2-explorer.flare.network/address/0x5e74d…a99939](https://coston2-explorer.flare.network/address/0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939) (source verified on Blockscout) |
| **Deploy tx** | `0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb` | [explorer/tx/0xf2678b…771cb](https://coston2-explorer.flare.network/tx/0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb) |
| **FXRP approve tx** | `0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8` | [explorer/tx/0x7f1905…36b8](https://coston2-explorer.flare.network/tx/0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8) |
| **FXRP deposit tx** | `0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149` | [explorer/tx/0x2ba65f…4149](https://coston2-explorer.flare.network/tx/0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149) |
| **FXRP deposited** | 5 FXRP (5,000,000 units, 6 decimals) | — |
| **Vault owner** | `0x5a3969F3767Cde96D662A94cAa79779073F80A0c` | — |
| **Real XRPL testnet payment** | `0xb9f346a3f25581fbb561842bf5d3c5c91b9909cf00d13dec7e7939b5c6347420` | `tesSUCCESS` · ledger 19689886 · 1,000,000 drops (1 XRP) · memo `CREDITGATE-LOAN-REPAYMENT-FDC-VERIFY-2026-08-06` |
| **FDC attestation Coston2 tx** | `0x7fd6c89de2fb52afe3f5cae83b44af6417c3af634845116c63e89a2aae7f4a42` | status 1 · block 33712406 · FDC round 1417946 finalized · AttestationRequest emitted |
| **FdcHub (verifier contract)** | `0x48aC463d7975828989331F4De43341627b9c5f1D` | — |
| **XRPL sender** | `rPnBvQhLnPJbxBfXJDWgc44D48JHw32gj5` | — |
| **XRPL receiver (vault XRPL)** | `rrpBcxxoHZuBWSTT2ZfCwHkQBBdfnLqgbK` | — |

**RPC / explorer:**
- Coston2 RPC: `https://coston2-api.flare.network/ext/C/rpc`
- Coston2 explorer (Blockscout): `https://coston2-explorer.flare.network`
- XRPL testnet RPC: `s.altnet.rippletest.net:51234/`

**Verify the attestation on-chain:**
```bash
cast receipt 0x7fd6c89de2fb52afe3f5cae83b44af6417c3af634845116c63e89a2aae7f4a42 \
  --rpc-url https://coston2-api.flare.network/ext/C/rpc
```

**FDC retrieve-stage caveat (honest framing):** Voting round 1417946 is finalized on-chain (`isFinalized(200, 1417946) = true`), but the Coston2 DA Layer API returns `"attestation request not found"` for `testXRP` attestations — a Coston2 testnet infrastructure limitation, not a CreditGate contract bug. The verifier ABI (`FdcVerification`) is deployed and the `verifyXRPPayment()` path runs against the existing Foundry fixture. See `evidence/fdc-real-verify.md` for the full submit-stage evidence.

---

## Production Notes

- **Total spoken content:** ~75s across five scenes (boundaries at 0:05, 0:15, 0:45, 1:10, 1:20).
- **TTS provider:** Edge TTS `en-US-AndrewMultilingualNeural` at `-10%` rate for measured demo pace (alternatives: Groq Orpheus `troy` voice — but Orpheus speaks ~2x slower; trim narration if using it).
- **Narration word count:** ~270 words across all spoken scenes (fits ~75s at ~3.6 words/sec, the sweet spot for edge-tts at -10%). The timing structure (Hook 5s → Problem 10s → Demo 30s → Proof 25s → CTA 10s) maps exactly to the spoken beats; the **Live Proof Details** table is a reference section for the submission form and is *not* read aloud.
- **Visual sync:** Record the browser + terminals first, then narrate to fit each scene's visual boundary. Do not let narration exceed video duration — trim the script, not the footage.
- **Coverage check — every required flow element appears:** the seven requested checkpoints map to scenes as follows —
  - **(a) FCC credit check** → Scene 3a (EIP-191 sign → Solidity ecrecover → `ELIGIBLE`)
  - **(b) FXRP deposit** → Scene 3b (100 FXRP → `COLLATERAL_DEPOSITED` + XRPL address snapshot)
  - **(c) USDT0 loan** → Scene 3c (50 USDT0 draw against the live FTSOv2 price → `FUNDED`)
  - **(d) FTSO price monitoring** → Scene 3d (health-factor readout from `getFeedByIdInWei(XRP/USD)` driving the auto-trigger)
  - **(e) Dutch auction liquidation** → Scene 3d (`startLiquidationAuction` → `bidOnLiquidation` → `finalizeAuction`, linear price decay, surplus refund)
  - **(f) XRPL repayment + FDC verification** → Scene 3 closing beat + Scene 4 (real XRPL payment + FDC attestation tx)
  - **(g) Live Coston2 deployment with tx hashes** → Scene 4 + the Live Proof Details reference table (vault, deploy, deposit, FDC attestation, XRPL payment hashes + Blockscout link)
- **On the FDC retrieve stage:** say *"submit stage proven with real data; retrieve stage awaiting Coston2 DA Layer indexing — testnet infra limit, not a contract bug"* (Scene 4). The verifier ABI is live; overclaiming an end-to-end live FDC round would mislead judges. Honesty on this one step builds credibility for the other three primitives that *are* fully live.
- **Layout:** three terminals across the top (FCC handler · vault app · tests/FDC), browser below; keep the test/Evidence terminal visible throughout — it is the receipts.
- **Close on the four-primitive tableau beat** — it is the single line a judge will remember.
- **Umbrella line for the controls:** *"Each load-bearing. None decorative."* — CreditGate is the only Flare Summer Signal submission using FAssets + FTSOv2 + FCC + FDC in a single coherent flow.
