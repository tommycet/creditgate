# CreditGate

> 🏆 **Bounty 2 — Confidential Compute Apps** (primary) · **Bounty 1 — Interoperable Asset Products** (secondary) · Flare Summer Signal (DoraHacks, Aug 14 2026) · $6,000 prize pool each

**Private FXRP credit eligibility layer for Flare — deposit FXRP, get a confidential credit attestation via FCC, borrow USDT0, repay on XRPL verified by FDC.**

|  |  |  |  |  |
|---|---|---|---|---|
|| 🟢 **Live on Coston2** | ✅ **171 tests** | ✅ **8 invariants** | ✅ **4 Flare primitives** | ✅ **Source verified** ||

**Quick links:** [Vault on Coston2 Explorer](https://coston2-explorer.flare.network/address/0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939) · [Frontend /docs](frontend/src/app/docs/page.tsx) · [SUBMISSION.md](SUBMISSION.md) · [ARCHITECTURE.md](ARCHITECTURE.md) · [DEMO.md](DEMO.md)

---

## The Problem

Billions of dollars of XRP sit idle on Flare as FXRP collateral — locked, productive as a peg anchor, but inaccessible for credit. XRP holders won't sell their position, and can't borrow against it without granting a centralized credit bureau visibility into their finances — which they won't grant. The result: a large pool of productive collateral and zero native credit market against it.

## The Solution

**CreditGate removes that friction using only Flare primitives:**

1. Borrower deposits **FXRP** collateral into a non-custodial vault on Flare
2. Registers their XRPL repayment address
3. A **FCC** handler evaluates credit eligibility *inside a TEE* — inputs and decision never leave the enclave — and returns a single EIP-191 signed attestation
4. Vault recomputes the hash, calls `ecrecover`, transitions loan to `ELIGIBLE`
5. Borrower draws a **USDT0** loan sized against the live **FTSOv2** XRP/USD price (150% collateral ratio)
6. Borrower repays on XRPL with a 32-byte domain-separated MemoData commitment
7. **FDC** verifies the XRPL payment on Flare; vault checks status, amount, memo, receiver, anti-replay → collateral released, loan `CLOSED`

**No trusted oracle. No centralized credit bureau.** And **the only Bounty 2 submission binding private eligibility (FCC) → public cross-chain verification (FDC) in a single product flow.**

---

## How CreditGate Uses Flare

| Primitive | Role | Load-bearing? |
|-----------|------|---------------|
| **FAssets (FXRP)** | Collateral ERC-20 (6 decimals) — actual custody | ✅ Yes — without FXRP there is no collateral |
| **FTSOv2** | XRP/USD price feed at `drawLoan` — enforces 150% collateral ratio | ✅ Yes — vault cannot price collateral or bound the loan |
| **FCC** | Private credit eligibility in TEE → single EIP-191 attestation verifiable by `ecrecover` | ✅ Yes — `ELIGIBLE` state unreachable without FCC signature. Go handler implemented per Flare's FCC extension spec; EIP-191 signature verified on-chain via `ecrecover`. TEE hardware attestation is a testnet → mainnet migration step, not a design gap. |
| **FDC** | Cross-chain XRPL repayment proof verification — gates collateral release | ✅ Yes — `FUNDED → CLOSED` transition cannot be trusted without it |

**Flare primitive contracts (Coston2, verified live 2026-08-05 via ContractRegistry):**

| Contract | Address |
|----------|---------|
| FXRP (FAssets) | `0x0b6A3645c240605887a5532109323A3E12273dc7` |
| USDT0 | `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` |
| FdcVerification | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |
| FdcHub | `0x48aC463d7975828989331F4De43341627b9c5f1D` |
| FdcRequestFeeConfigurations | `0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e` |

Chain ID 114 · RPC `https://coston2-api.flare.network/ext/C/rpc` · Explorer `https://coston2-explorer.flare.network`

---

## Quick Start (3 commands)

```bash
# 1. Contracts — 171 tests across 15 suites, 0 failures
forge test

# 2. Frontend — Next.js + wagmi + RainbowKit (http://localhost:3000)
cd frontend && npm run dev

# 3. FCC handler — Go TEE credit evaluator + EIP-191 signer (:8080)
cd fcc/credit-extension/extension && go run .
# POST /action → returns EIP-191 eligibility attestation accepted by Solidity ecrecover
```

> **Prereqs:** `foundryup`, Node 18+, Go 1.21+. For Coston2 deployment see [Deployment](#deployment) below.

---

## Built During the Hackathon

CreditGateVault came in as a basic deposit/draw/repay prototype. During the Flare Summer Signal window it grew to a full lending primitive — every capability below is exercised by the test suite and reflected on the frontend. (Full list in [SUBMISSION.md § What Was Newly Built](SUBMISSION.md).)

- **`CreditGateVault.sol`** — State machine, FXRP/USDT0 custody, collateral ratio enforcement
- **`CreditGateInstructionSender.sol` + Go TEE handler** — FCC CREDIT/EVALUATE eligibility evaluator (simulated TEE), per official Flare Compute Extension architecture
- **XRPL address binding** — borrower registers their XRPL r-address; FDC repayment proof must match (prevents repayment substitution)
- **32-byte XRPL MemoData commitment binding** — domain-separated, loan-specific
- **FDC repayment proof verification** — status, amount, memo, receiver, and source checks
- **Dutch auction liquidation** — descending-price auction for under-collateralized loans, bounded penalties, monotonic price decay
- **5% APR interest accrual** — pro-rata interest on outstanding loans, required to be covered by MemoData
- **Automated FTSO-threshold liquidation trigger** — `checkAndTriggerLiquidation` / `batchCheckLiquidation` over the live FTSOv2 feed, no manual keeper required
- **Per-collateral LTV ratio configuration** — `registerCollateral` / `updateLTV` / `getMaxLoanAmount` for multi-asset onboarding
- **Health factor & portfolio views** — `getHealthFactor`, `getLoanSummary`, `getPortfolioSummary`
- **Mock credit bureau in TEE** — reproducible off-chain evaluation; bureau output never exposed in cleartext, only signed attestation crosses the trust boundary
- **Borrower reputation tracking** — on-chain history (totalBorrowed, totalRepaid, loansCompleted, loansDefaulted) powering FCC credit scoring (Aave/ARCx pattern)
- **24h grace period** — borrower protection before liquidation; 24-hour window after deadline prevents instant seizure (Aave V3/Compound V3 pattern)
- **171-test Foundry suite across 15 suites** (8 invariant/fuzz tests, cross-language Go-TEE ↔ Solidity compat, real malicious-token reentrancy attack)
- **React lifecycle UI** with a `/docs` section consolidating architecture, deployment, testing, security evidence
- **Live deployment on Coston2** + source verified on Blockscout

**Existing Flare primitives (not claimed as new):** FCC proxy, FDC verifier, FTSO feeds, FXRP token, FDC request fee configuration. See the addresses table above.

---

## Why CreditGate Wins

Competitive intel gathered from the live DoraHacks BUIDL listing (see `planning/competitive-positioning/verdict.md`).

| # | Advantage | Evidence |
|---|-----------|----------|
| 1 | **Only submission using all 4 Flare primitives as load-bearing** — FAssets/FXRP + FTSOv2 + FCC + FDC. AegisFlow omits FTSO; FlareShield AI omits FDC; Axi uses SGX/NOX, not Flare FCC. | Flare table above (all ✅ load-bearing) |
| 2 | **Only submission binding FCC (private eligibility) → FDC (public cross-chain verification)** in a single product flow. | `ARCHITECTURE.md` + state machine |
| 3 | **Real reentrancy attack test** — malicious FXRP token invokes `depositCollateral` from `transferFrom`; blocked by `ReentrancyGuard`. | `test/CreditGateVault.malicious-reentrancy.t.sol` |
| 4 | **Go-TEE ↔ Solidity cross-language compatibility** — 2 tests prove the Go handler's EIP-191 signature is accepted by Solidity `ecrecover`. | `test/CreditGateVault.go-tee-compat.t.sol` |
| 5 | **171 tests / 15 suites + 8 invariant/fuzz + security audit clean** — all M1/M2/L1/L2/L4/L5 findings fixed. | `planning/security-audit/verdict.md` (PASS) + `forge test` |
| 6 | **Cross-chain repayment-substitution defense** — per-loan XRPL address snapshot + 32-byte domain-separated MemoData commitment. | `src/CreditGateVault.sol` + `ARCHITECTURE.md` |

---

## Evidence

Every claim is backed by a file a judge can open and run. Six planning review verdicts were produced by read-only audit subagents and then acted on. Full breakdown in [SUBMISSION.md § Evidence](SUBMISSION.md) and `evidence/test-summary.md`.

| Metric | Value |
|--------|-------|
| Tests passing | 171 across 15 suites, 0 failures |
| Line coverage | 97.75% of `CreditGateVault.sol` |
| Invariant/fuzz tests | 8 (FXRP conservation, USDT0 solvency, no overdraft, state ordering, no ghost collateral, interest ceiling, LTV limit, terminal-loan finality) |
| Go-TEE cross-language tests | 2 (Go signature → Solidity `ecrecover`) |
| Reentrancy attack tests | 1 (malicious FXRP token blocked) |
| FDC lifecycle tests | 4 (realistic XRPL proof verified) |
| Security fixes | 5 (audit-verified: M1, M2, L1, L2, L4, L5) |

Key test files:

| File | What it proves |
|------|----------------|
| `test/CreditGateVault.t.sol` | 69 unit tests — all state transitions, error paths, interest-accrual math |
| `test/CreditGateVault.invariant.t.sol` | 8 invariant/fuzz tests — FXRP conservation, USDT0 solvency, state ordering |
| `test/CreditGateVault.go-tee-compat.t.sol` | 2 cross-language tests — Go TEE signature accepted by Solidity `ecrecover` |
| `test/CreditGateVault.malicious-reentrancy.t.sol` | 1 truly-malicious-token test — real malicious FXRP callback blocked by `ReentrancyGuard` |
| `test/CreditGateVault.fdc-fixture.t.sol` | 4 FDC lifecycle tests — realistic XRPL proof verified by vault |
| `test/CreditGateVault.edge-cases.t.sol` | 15 edge-case boundary tests |
| `test/CreditGateVault.auction.t.sol` | 5 Dutch auction liquidation tests |
| `test/CreditGateVault.views.t.sol` | 15 view tests — health factor, loan/portfolio summary |
| `test/CreditGateVault.ltv.t.sol` | 11 per-collateral LTV configuration tests |
| `test/CreditGateVault.trigger.t.sol` | 9 automated FTSO-threshold liquidation trigger tests |
| `test/CreditGateVault.security-edge.t.sol` | 5 critical security edge-case tests — negative FDC amount, cross-loan replay, past-deadline accrual, paused-vault liquidation, LTV non-retroactive |
| `test/CreditGateVault.reputation.t.sol` | 5 borrower reputation tests — totalBorrowed/totalRepaid/loansCompleted/loansDefaulted tracking, getReputation view (Aave/ARCx pattern) |
| `test/CreditGateVault.grace-period.t.sol` | 7 grace-period tests — 24h default window before liquidation, owner-only update, 30-day cap (Aave V3 / Compound V3 pattern) |
| `evidence/tee-attestation.json` | Real attestation produced by the Go FCC handler (POST /action) |

---

## Deployment

**Network:** Coston2 testnet (chain ID 114)

| Contract | Address |
|----------|---------|
| CreditGateVault | `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939` |
| FXRP | `0x0b6A3645c240605887a5532109323A3E12273dc7` |
| USDT0 | `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` |
| FdcVerification | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |

```bash
cp .env.example .env   # fill PRIVATE_KEY, TEE_AUTHORITY, FTSO_V2_ADDRESS
forge script script/DeployCreditGate.s.sol --rpc-url coston2 --broadcast
```

### Live Deployment on Coston2

CreditGateVault is **deployed and live** on Coston2 (verified 2026-08-06). Vault holds 5 FXRP of live collateral, ready to draw loans against the live FTSOv2 XRP/USD feed.

| Artifact | Value |
|----------|-------|
| Vault address | `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939` |
| Deploy tx | [`0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb`](https://coston2-explorer.flare.network/tx/0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb) |
| FXRP approve tx | [`0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8`](https://coston2-explorer.flare.network/tx/0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8) |
| FXRP deposit tx | [`0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149`](https://coston2-explorer.flare.network/tx/0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149) |
| FDC attestation tx | [`0x7fd6c89de2fb52afe3f5cae83b44af6417c3af634845116c63e89a2aae7f4a42`](https://coston2-explorer.flare.network/tx/0x7fd6c89de2fb52afe3f5cae83b44af6417c3af634845116c63e89a2aae7f4a42) | Block 33712406 | Real XRPL testnet tx `0xb9f346a3…4720` (ledger 19689886), round 1417946 finalized |
| VFXRP deposited | 5,000,000 (5 FXRP, 6 dp) |
| Owner | `0x5a3969F3767Cde96D662A94cAa79779073F80A0c` |

### Evidence Modes

| Surface | Label | Status |
|---------|-------|--------|
| Coston2 vault/deposit/draw txs | `LIVE Coston2` | Deployed 2026-08-06 |
| FCC eligibility | `Go HANDLER (LIVE)` + `TEE ATTESTATION (SIMULATED)` | Real Go FCC extension produces valid EIP-191 signatures; TEE hardware attestation simulated on testnet |
| XRPL payment | `LIVE XRPL TESTNET` | Live transaction captured |
| FDC attestation submit | `LIVE` | Real XRPL testnet tx → on-chain attestation, round 1417946 finalized |
| FDC proof retrieve/verify | `INFRA-LIMITED` | Coston2 DA Layer doesn't index testXRP attestations |
| Mocks in Foundry | `TEST FIXTURE` | Never presented as deployed evidence |

---

## Frontend

```bash
cd frontend
npm install
echo "NEXT_PUBLIC_VAULT_ADDRESS=0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939" > .env.local
npm run dev    # http://localhost:3000 — judge-facing app, live borrower lifecycle UI
# /docs section surfaces architecture, deployment, testing, security evidence
```

Next.js 15 + wagmi v2 + RainbowKit, 6 routes prerendered, full CreditGate lifecycle UI.

### FCC Credit Extension (Go TEE handler)

```bash
cd fcc/credit-extension/extension
export CREDITGATE_SIGNING_KEY=<your-private-key-hex>   # same as TEE_AUTHORITY in .env
go run .   # listens on :8080
# POST /action → returns EIP-191 eligibility attestation
```

---

## Roadmap

1. **Hackathon scope** — Simulated TEE + pre-captured FDC proof demo, deployed to Coston2 ✅
2. **Production FCC** — Migrate to real TEE attestation with key governance (rotation, revocation, multi-authority)
3. **AI credit scoring** — Off-chain AI credit-scoring model inside the TEE for automated, private eligibility decisions
4. **ERC-3643 compliance** — Institutional compliance modules for regulated asset issuance, permissioned FXRP transfers
5. **Multi-collateral** — FBTC, FDOGE credit gates with asset-specific risk parameters
6. **Adapter integration** — Gate access to existing lending markets (Morpho / Mystic)
7. **Institutional** — Lender policy engines and compliance reporting

---

## Repository

**GitHub:** https://github.com/tommycet/creditgate *(made public for the Flare Summer Signal submission window; if private at judging time, contact via DoraHacks)*

## License

MIT
