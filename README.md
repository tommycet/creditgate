# CreditGate

> 🏆 **Bounty 2 — Confidential Compute Apps** | Flare Summer Signal (DoraHacks, Aug 14 2026) | $6,000 prize pool

**Private FXRP credit eligibility layer for Flare.**

Billions of dollars of XRP sit idle on Flare as FXRP collateral — locked, productive as a peg anchor, but inaccessible for credit. XRP holders won't sell their position, but they can't borrow against it without a trusted private credit evaluation. **CreditGate solves this**: deposit FXRP collateral on Flare, receive a confidential eligibility attestation via FCC (Flare Confidential Compute), draw a USDT0 loan, and repay on XRPL. Repayment is verified on-chain via FDC (Flare Data Connector) with a 32-byte MemoData commitment binding — no trusted oracle, no centralized credit bureau, just Flare primitives doing what they're designed to do.

---

## Quick Start (3 commands)

```bash
# 1. Contracts — 91 tests across 7 suites, 0 failures
forge test

# 2. Frontend — Next.js + wagmi + RainbowKit (http://localhost:3000)
cd frontend && npm run dev

# 3. FCC handler — Go TEE credit evaluator + EIP-191 signer (:8080)
cd fcc/credit-extension/extension && go run .
# POST /action → returns EIP-191 eligibility attestation accepted by Solidity ecrecover
```

> **Prereqs:** `foundryup`, Node 18+, Go 1.21+. For Coston2 deployment see [Deployment](#deployment) below.

---

## Why CreditGate Wins

Competitive intel gathered from the live DoraHacks BUIDL listing (see `planning/competitive-positioning/verdict.md`). Five defensible advantages over the other Bounty 2 submissions (AegisFlow, FlareShield AI, Axi):

| # | Advantage | Evidence |
|---|-----------|----------|
| 1 | **Only submission using all 4 Flare primitives as load-bearing** — FAssets/FXRP + FTSOv2 + FCC + FDC. AegisFlow omits FTSO; FlareShield AI omits FDC; Axi uses SGX/NOX, not Flare FCC. | `README` Flare table below (all ✅ load-bearing) |
| 2 | **Only submission binding FCC (private eligibility) → FDC (public cross-chain verification)** in a single product flow. | `ARCHITECTURE.md` + state machine |
| 3 | **Real reentrancy attack test** — malicious FXRP token invokes `depositCollateral` from `transferFrom`; blocked by `ReentrancyGuard`. | `test/CreditGateVault.malicious-reentrancy.t.sol` |
| 4 | **Go-TEE ↔ Solidity cross-language compatibility** — 2 tests prove the Go handler's EIP-191 signature is accepted by Solidity `ecrecover`. No competitor surfaces this. | `test/CreditGateVault.go-tee-compat.t.sol` |
| 5 | **91 tests / 7 suites + invariant fuzz + security audit clean** — deepest *verifiable* engineering evidence among named competitors; all M1/M2/L1/L2/L4/L5 findings fixed. | `planning/security-audit/verdict.md` (PASS) + `forge test` |
| 6 | **Cross-chain repayment-substitution defense** — per-loan XRPL address snapshot + 32-byte domain-separated MemoData commitment. None of the competitors describe this. | `src/CreditGateVault.sol` + `ARCHITECTURE.md` |

---

## How CreditGate Uses Flare

| Primitive | Role | Load-bearing? |
|-----------|------|---------------|
| **FAssets (FXRP)** | Collateral ERC-20 (6 decimals) | ✅ Yes — actual collateral |
| **FTSOv2** | XRP/USD price feed for collateral ratio | ✅ Yes — enforces 150% ratio |
| **FCC** | Private credit eligibility evaluation | ✅ Yes — gates loan drawdown |
| **FDC** | XRPPayment proof verification | ✅ Yes — gates collateral release |

**Flare primitive contracts (Coston2, verified live 2026-08-05 via ContractRegistry):**

| Contract | Address |
|----------|---------|
| FXRP (FAssets) | `0x0b6A3645c240605887a5532109323A3E12273dc7` |
| USDT0 | `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` |
| FdcVerification | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |
| FdcHub | `0x48aC463d7975828989331F4De43341627b9c5f1D` |
| FdcRequestFeeConfigurations | `0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e` |

**Chain ID 114 · RPC `https://coston2-api.flare.network/ext/C/rpc` · Explorer `https://coston2-explorer.flare.network`**

---

## Architecture

```
Borrower → Deposit FXRP → Request Eligibility → FCC Evaluates → Draw USDT0
                                                           ↓
                                                    Loan FUNDED
                                                           ↓
Borrower → Repay on XRPL → FDC Verifies Proof → Collateral Released
                                                           ↓
                                                      Loan CLOSED
```

**State machine:** `IDLE → COLLATERAL_DEPOSITED → ELIGIBILITY_PENDING → ELIGIBLE → FUNDED → CLOSED`

**Rejection paths:**
- Stale/revoked eligibility → `REJECTED`
- Repayment deadline expired → `DEFAULTED`

Full design in [`ARCHITECTURE.md`](ARCHITECTURE.md) (EIP-191 payload layout, FDC proof verification flow, security fixes).

---

## What Was Newly Built (Hackathon)

- `CreditGateVault.sol` — State machine, FXRP/USDT0 custody, collateral ratio enforcement
- `CreditGateInstructionSender.sol` + Go TEE handler — FCC CREDIT/EVALUATE eligibility evaluator (simulated TEE), per official Flare Compute Extension architecture
- XRPL address binding — borrower registers their XRPL r-address; FDC repayment proof must match (prevents repayment substitution)
- 32-byte XRPL MemoData commitment binding — domain-separated, loan-specific
- FDC repayment proof verification — Status, amount, memo, receiver, and source checks
- Foundry test suite — **91 tests across 7 suites** (62 unit + 4 FDC lifecycle fixture + 5 invariant/fuzz + 2 Go-TEE cross-language + 1 truly-malicious-token reentrancy + 2 reentrancy/vault-solvency/FTSO-edge + 15 edge-case boundary tests: border collateral ratios, double-request rejection, expired attestation handling, security boundaries)
- React lifecycle UI — judge-facing demo interface

**Existing Flare primitives (not claimed as new):** FCC proxy, FDC verifier, FTSO feeds, FXRP token, FDC request fee configuration. See deployment table above for addresses and live verification date.

---

## Evidence Directory

Every claim above is backed by a file a judge can open and read. Six planning review verdicts were produced by read-only audit subagents and then acted on; the test files are runnable with `forge test`.

| File | What it proves |
|------|----------------|
| `test/CreditGateVault.t.sol` | 62 unit tests — all state transitions and error paths |
| `test/CreditGateVault.fdc-fixture.t.sol` | 4 FDC lifecycle tests — realistic XRPL proof verified by vault |
| `test/CreditGateVault.invariant.t.sol` | 5 invariant/fuzz tests — FXRP conservation, USDT0 solvency, state ordering |
| `test/CreditGateVault.go-tee-compat.t.sol` | 2 cross-language tests — Go TEE signature accepted by Solidity `ecrecover` |
| `test/CreditGateVault.malicious-reentrancy.t.sol` | 1 truly-malicious-token test — real malicious FXRP callback blocked by `ReentrancyGuard` |
| `test/CreditGateVault.reentrancy.t.sol` | 2 reentrancy/solvency/FTSO-edge tests — future-timestamp FTSO + insufficient-USDT0 draw reverted, vault solvency |
| `test/CreditGateVault.edge-cases.t.sol` | 15 edge-case boundary tests — border collateral ratios, double-request rejection, expired-attestation handling, security boundaries |
| `evidence/tee-attestation.json` | Real attestation produced by the Go FCC handler (POST /action) |
| `ARCHITECTURE.md` | EIP-191 payload layout, FDC proof verification flow, Flare primitive contracts, security fixes |
| `DEMO.md` | 90-second demo script for judges |
| `planning/fdc-review/verdict.md` | FDC script review — PASS-WITH-NOTES, fee-config bug found and fixed |
| `planning/frontend-review/verdict.md` | Frontend review — 6 lifecycle UX gaps found and fixed (PASS after remediation) |
| `planning/security-audit/verdict.md` | Security audit of `CreditGateVault.sol` — all M1/M2/L1/L2/L4/L5 findings remediated |
| `planning/gas-audit/verdict.md` | Gas audit — 7 opportunities quantified (~4,500–9,800 gas/lifecycle) |
| `planning/judge-sim/verdict.md` | Judge simulation — 7.4/10 weighted baseline and gap analysis |
| `planning/competitive-positioning/verdict.md` | Competitive intel — all known Bounty 2 competitors and differentiators |

Reproduce any verdict's evidence: `cat planning/<review>/verdict.md`.

---

## Deployment

**Network:** Coston2 testnet (chain ID 114)

| Contract | Address |
|----------|---------|
| CreditGateVault | `<DEPLOYED_ADDRESS>` *(faucet address `0x5a3969F3767Cde96D662A94cAa79779073F80A0c` pending Coston2 funding)* |
| FXRP | `0x0b6A3645c240605887a5532109323A3E12273dc7` |
| USDT0 | `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` |
| FdcVerification | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |

```bash
cp .env.example .env   # fill PRIVATE_KEY, TEE_AUTHORITY, FTSO_V2_ADDRESS
forge script script/DeployCreditGate.s.sol --rpc-url coston2 --broadcast
```

### Evidence Modes

| Surface | Label | Status |
|---------|-------|--------|
| Coston2 vault/deposit/draw txs | `LIVE Coston2` | After deployment |
| FCC eligibility | `SIMULATED TEE` | Simulated path, same EIP-191 signature shape |
| XRPL payment | `LIVE XRPL TESTNET` | Live transaction captured |
| FDC proof | `LIVE FDC` or `FDC FIXTURE` | Depends on verifier API access |
| Mocks in Foundry | `TEST FIXTURE` | Never presented as deployed evidence |

---

## Frontend

```bash
cd frontend
npm install
echo "NEXT_PUBLIC_VAULT_ADDRESS=<deployed-address>" > .env.local
npm run dev    # http://localhost:3000
# production build:
npm run build && npm start
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

1. **Hackathon scope** — Simulated TEE + pre-captured FDC proof demo
2. **Production FCC** — Migrate to real TEE attestation with key governance
3. **AI credit scoring** — FCC handler ingests an off-chain AI credit-scoring model inside the TEE for automated, private eligibility decisions
4. **ERC-3643 compliance** — Institutional compliance modules for regulated asset issuance, integrating permissioned FXRP transfers
5. **Multi-collateral** — FBTC, FDOGE credit gates with asset-specific risk
6. **Adapter integration** — Gate access to existing lending markets (Morpho/Mystic)
7. **Institutional** — Lender policy engines and compliance reporting

---

## License

MIT
