# CreditGate — 3-Minute Demo Script

> **For judges of Flare Summer Signal — Bounty 2 (Confidential Compute Apps).**
> CreditGate is the only discovered submission that uses **all four** Flare primitives — FAssets, FTSOv2, FCC, and FDC — in a single load-bearing product flow. This demo proves it in three minutes.

## Setup (15s)

Three terminals side-by-side, narrated as you start:

- **Terminal 1 — FCC handler running on `:8080`** (the Go TEE credit evaluator)
  ```bash
  cd fcc/credit-extension/extension
  export CREDITGATE_SIGNING_KEY=<hex-key-matching-TEE_AUTHORITY>
  go run .   # → "listening on :8080"
  ```
- **Terminal 2 — Frontend served on `:3000`** (Next.js + wagmi, Coston2)
  ```bash
  cd frontend && npm run dev   # → http://localhost:3000
  ```
- **Terminal 3 — Forge test output, 118 tests green** (the evidence backbone)
  ```bash
  forge test   # → "118 tests passed, 0 failures" across 9 suites
  ```

> **Opening line:** *"Three terminals — the TEE credit evaluator, the borrower UI, and the test suite. Watch how they compose into one credit flow on Flare."*

---

## Act 1: The Problem (30s)

Stand on the **transparency dashboard** (`/transparency` in the frontend).

- **"Billions of dollars of XRP sit idle on Flare as FXRP collateral. The holders earn peg-anchor yield — but they can't borrow against it. Selling breaks their position; borrowing requires a trusted credit bureau that XRP holders, by temperament, won't grant."**
- Cursor over the **idle FXRP stats** panel: total FXRP minted on Coston2, the fraction not deployed in any lending market, the implied unmet credit demand.
- **"CreditGate unlocks that collateral without a centralized bureau — using only Flare primitives. The same primitives that secure the network secure the loan."**

> Land the wedge vs. competitors: this is a *post-deposit credit gate* (FCC evaluates → vault enforces), not a pre-issuance compliance screen. We touch FAssets **and** FTSO **and** FCC **and** FDC in a single flow.

---

## Act 2: Deposit + Credit Check (45s)

Switch to **`/app`** — the borrower lifecycle view.

1. **Connect wallet** (MetaMask, Coston2 network, chain ID 114).
2. **Deposit 100 FXRP collateral** → click *Deposit* → real Coston2 tx, hash visible in Terminal 2 logs. State: `COLLATERAL_DEPOSITED`.
3. **Register XRPL r-address** → the borrower's XRPL account is hashed via `keccak256` and bound to the loan (this snapshot is what FDC will later check, defeating repayment-substitution attacks).
4. **Request eligibility** → the frontend POSTs to the FCC Go handler (`localhost:8080/action`, `opCommand: EVALUATE`).
   - **Terminal 1 lights up:** the handler runs its credit pipeline — input validation → revocation check → collateral sufficiency (mirroring the vault's `drawLoan` math against the live XRP/USD price) → limit derivation → **EIP-191 signing**.
   - Returns `(v, r, s)` over `keccak256(abi.encode(DOMAIN, borrower, limit, expiry, nonce, revocationVersion))`.
5. **Submit attestation** → click *Submit Attestation* → the vault calls `ecrecover` on the Go-produced signature.
   - **State: `ELIGIBLE`.**
   - **"That signature came from a Go process; the Solidity vault accepts it verbatim. We proved that with a dedicated cross-language test — keep watching Terminal 3."**

> This is the **only** step where off-chain confidential compute touches the chain. The TEE never reveals *why* the borrower qualified — only a signed yes/no with a limit.

---

## Act 3: Draw Loan + Repay (45s)

1. **Draw 50 USDT0 loan** (within the 150% collateral ratio).
   - Click *Draw Loan* → **FTSOv2 reads the live XRP/USD price** → vault enforces `collateral × price × 10000 ≥ loan × collateralRatioBps`.
   - **State: `FUNDED`.** USDT0 disbursed to the borrower on Coston2.
2. **Show the XRPL repayment instructions** rendered on the loan card:
   - **Amount:** `requiredRepaymentDrops` XRP (computed on-chain as `loanAmount × 1e18 ÷ XRP/USD price`).
   - **Destination:** the vault's XRPL address.
   - **MemoData:** the loan's 32-byte `expectedCommitment` (domain-separated, loan-specific) — *paste this or the FDC proof will revert*.
3. **"In production, the borrower repays on XRPL testnet; the FDC then verifies the payment on Flare."** Switch to **Terminal 3** and run the FDC lifecycle test:
   ```bash
   forge test --match-contract FDC -vv   # → CreditGateVaultFdcFixtureTest
   ```
   - A pre-captured XRPL payment proof is fed to `verifyXRPPayment()`.
   - **Real proof, real verification** — the vault checks status, receivedAmount, hasMemoData, memo == commitment, receivingAddressHash == snapshot, and `proofConsumed` anti-replay.
   - **State: `CLOSED`.** Collateral released.
4. **Evidence tag:** `FDC FIXTURE` (pre-captured proof verified locally; live `FdcVerification` at `0x906507E0B64bcD494Db73bd0459d1C667e14B933` uses the exact same `verifyXRPPayment` code path).

> Why fixture, not live? FDC voting-round finalization is ~180s on Coston2 — too long for a 3-minute demo. We pre-capture a real XRPL payment's FDC proof and verify it through the production verifier ABI. The verifier address is the live one; only the proof source is a fixture.

---

## Act 4: Security + Evidence (30s)

Stay on Terminal 3. Run the full suite on camera:

```bash
forge test   # → 118 tests, 9 suites, 0 failures
```

Highlight three categories of evidence (panels prepared as `forge test --match-contract <X> -vv` output):

- **Reentrancy attack tests** (`CreditGateVault.malicious-reentrancy.t.sol`, 3 tests):
  a malicious FXRP token that calls `depositCollateral` from inside `transferFrom` — **blocked by `ReentrancyGuard`**. "We didn't just add the guard; we wrote an attack that proves it."
- **Go-TEE cross-language compatibility** (`CreditGateVault.go-tee-compat.t.sol`, 2 tests):
  Go handler produces a real EIP-191 signature → Solidity `ecrecover` accepts it → `ELIGIBLE`. Tamper one byte of the limit → `InvalidEligibilitySigner`. "The TEE and the vault agree on bytes."
- **Invariant tests** (`CreditGateVault.invariant.t.sol`, 5 tests):
  **FXRP conservation** (vault collateral never leaks) + **USDT0 solvency** (vault never disburses more than it holds) + state ordering, across fuzzed inputs.

> **Security audit: PASS-WITH-NOTES, all fixes applied** (M1 signature s/v bounds + nonzero recovered; M2 nonce rotation on revoke; L1 expiry re-check in `drawLoan`; L4 default recovery; L5 source-address snapshot at draw time).

---

## Act 5: Flare Primitives (15s)

Final card — the four-primitive claim, on screen:

| Primitive | Where you just saw it |
|-----------|----------------------|
| **FAssets (FXRP)** | Act 2 — the 100 FXRP collateral deposit |
| **FTSOv2** | Act 3 — the XRP/USD price that gates the loan |
| **FCC** | Act 2 — the private Go credit evaluator → EIP-191 attestation |
| **FDC** | Act 3 — the on-chain XRPL repayment proof verification |

- **"CreditGate uses all four Flare primitives, each load-bearing. None is decorative."**
- **"This is the only submission in Bounty 2 binding a private eligibility check (FCC) to a public cross-chain repayment verification (FDC) in a single product flow."** — per our competitive scan of named BUIDLs (AegisFlow: FCC+FDC, no FTSO, no cross-chain collateral; FlareShield AI: FCC+FTSO, no FDC; Axi: TEE, not Flare FCC).

---

## Key Numbers

| Metric | Value |
|--------|-------|
| **Tests passing** | 118 across 9 suites, 0 failures |
| **Flare primitives used** | 4 — FAssets (FXRP) + FTSOv2 + FCC + FDC |
| **Security fixes** | 5 (audit-verified: M1, M2, L1, L4, L5) |
| **Go-TEE cross-language tests** | 2 (Go signature → Solidity `ecrecover`) |
| **Reentrancy attack tests** | 3 (malicious FXRP token blocked) |
| **Invariant/fuzz tests** | 5 (FXRP conservation + USDT0 solvency) |
| **Bounty** | Confidential Compute Apps (Bounty 2) |
| **Network** | Coston2 (chain ID 114) |

---

## Recording Notes

- **Resolution:** 1080p, ~3:00 runtime, <50 MB for upload.
- **Layout:** three terminals across the top, browser below; keep Terminal 3 (tests) visible throughout — it's the receipts.
- **Narrate the Flare primitive at each step** — call out FAssets / FTSO / FCC / FDC by name as each fires.
- **On the FDC step** say *"fixture proof, live verifier ABI"* — don't overclaim. Honesty on this one step builds credibility for the other three primitives that *are* live.
- **Close on the four-primitive tableau** — it's the single line a judge will remember.
