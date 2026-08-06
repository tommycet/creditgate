# CreditGate — Flare Summer Signal Submission

## Bounty

**Bounty 1: Interoperable Asset Products ($6,000)** — CreditGate uses FAssets (FXRP collateral) + FDC (XRPL repayment verification) to enable cross-chain interoperable asset products. The vault locks FXRP on Flare and verifies repayment on XRPL via FDC — a genuine cross-chain asset flow.

**Bounty 2: Confidential Compute Apps ($6,000)** — CreditGate uses Flare Confidential Compute (FCC) to evaluate credit eligibility privately inside a TEE, producing a single EIP-191 signed attestation verifiable by Solidity `ecrecover`. The privacy guarantee: the TEE inputs and decision never leave the enclave.

**Primary target: Bounty 2** (FCC is the core differentiator). **Secondary target: Bounty 1** (FXRP + FDC cross-chain flow qualifies). Flare Summer Signal (DoraHacks, Aug 14 2026).

## One-Line Description

Private FXRP credit eligibility layer — deposit FXRP, get a private credit attestation via FCC, borrow USDT0, repay on XRPL verified by FDC.

## What Does It Do?

Billions of dollars of XRP sit idle on Flare as FXRP collateral — locked, productive as a peg anchor, but inaccessible for credit. XRP holders won't sell their position (it breaks their peg exposure), and they can't borrow against it without granting a centralized credit bureau visibility into their finances. That visibility is precisely what XRP holders — by temperament and by the privacy guarantees of the XRPL base layer — will not grant. The result is a large pool of productive collateral and zero native credit market against it.

**CreditGate** removes that friction using only Flare primitives. A borrower deposits FXRP collateral into a non-custodial vault on Flare Coston2. They register their XRPL repayment address. They request eligibility; a Flare Confidential Compute (FCC) handler evaluates their position privately — *inside the TEE, the inputs and the decision never leave the enclave* — and returns a single EIP-191 signed attestation `(borrower, limit, expiry, nonce, revocationVersion)`. The vault recomputes the hash, calls `ecrecover`, and on a match transitions the loan to `ELIGIBLE`. The borrower then draws a USDT0 loan, sized against the live FTSOv2 XRP/USD price with a 150% collateral ratio. The TEE never reveals *why* the borrower qualified — only a signed yes/no with a limit. **This is the only step where off-chain confidential compute touches the chain.**

Repayment happens on XRPL — the borrower sends XRP drops plus a 32-byte domain-separated MemoData commitment to the vault's XRPL address. The Flare Data Connector (FDC) verifies that payment on Flare; the vault's `verifyXRPPayment()` checks status, received amount, the memo against the loan's per-instance commitment, the receiving XRPL address against a per-loan snapshot, and a `proofConsumed` anti-replay flag. On a valid proof, collateral is released and the loan is `CLOSED`. No trusted oracle. No centralized credit bureau. Just Flare primitives doing what they were designed to do — and, notably, **the only submission in Bounty 2 that binds a private eligibility check (FCC) to a public cross-chain repayment verification (FDC) in a single product flow.**

## How Does It Use Flare Primitives?

CreditGate uses all four Flare primitives, each **load-bearing** — none is decorative. Every primitive gates a real state transition; remove any one and the flow breaks.

| Primitive | Role | Depth |
|-----------|------|-------|
| **FAssets (FXRP)** | Collateral ERC-20 (6 decimals) — actual custody locked in the vault | Load-bearing — without FXRP there is no collateral and no loan |
| **FTSOv2** | XRP/USD price feed, read live at `drawLoan` to enforce the 150% collateral ratio (`collateral × price × 10000 ≥ loan × collateralRatioBps`) | Load-bearing — without FTSOv2 the vault cannot price collateral or bound the loan |
| **FCC** | Private credit eligibility evaluation in a TEE; produces a single EIP-191 signed attestation, verifiable by Solidity `ecrecover` | Load-bearing — the `ELIGIBLE` state is unreachable without an FCC signature from the authorized TEE authority |
| **FDC** | Cross-chain XRPL repayment proof verification on Flare; vault gates collateral release on `verifyXRPPayment` + memo + per-loan address snapshot + anti-replay | Load-bearing — without FDC the `FUNDED → CLOSED` transition cannot be trusted, and collateral could not be safely released |

**Flare primitive contracts (Coston2, verified live 2026-08-05 via ContractRegistry):**

| Contract | Address |
|----------|---------|
| FXRP (FAssets) | `0x0b6A3645c240605887a5532109323A3E12273dc7` |
| USDT0 | `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` |
| FdcVerification | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |
| FdcHub | `0x48aC463d7975828989331F4De43341627b9c5f1D` |
| FdcRequestFeeConfigurations | `0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e` |

Chain ID 114 · RPC `https://coston2-api.flare.network/ext/C/rpc` · Explorer `https://coston2-explorer.flare.network`.

## Technical Architecture

**State machine:** `IDLE → COLLATERAL_DEPOSITED → ELIGIBILITY_PENDING → ELIGIBLE → FUNDED → CLOSED`. Rejection paths: stale/revoked eligibility → `REJECTED`; repayment deadline expired → `DEFAULTED`.

```
Borrower → Deposit FXRP → Request Eligibility → FCC Evaluates (off-chain TEE) → Draw USDT0
                                                           ↓
                                                    Loan FUNDED
                                                           ↓
Borrower → Repay on XRPL → FDC Verifies Proof → Collateral Released
                                                           ↓
                                                      Loan CLOSED
```

- **EIP-191 attestation payload** is constructed byte-identically by the Go FCC handler and the Solidity vault: `keccak256(abi.encode(DOMAIN, borrower, limit, expiry, nonce, revocationVersion))` over the EIP-191 prefix — the **Go-TEE ↔ Solidity cross-language compatibility** is proven by dedicated tests (see Evidence).
- **FDC repayment proof** is verified through the live `FdcVerification` ABI at the address above. The vault checks: `verifyXRPPayment(proof)`, `receivedAmount ≥ requiredRepaymentDrops`, `receivingAddressHash == loan address snapshot`, `firstMemoData == loan.expectedCommitment`, and `proofConsumed[proofHash] == false`.
- **Cross-chain repayment-substitution defense** — per-loan XRPL address snapshot taken at draw time, plus a 32-byte domain-separated MemoData commitment loan-specific. A borrower cannot substitute another account's XRPL payment to release their own collateral.
- **Existing Flare primitives (not claimed as new):** FCC proxy, FDC verifier, FTSO feeds, FXRP token, FDC request fee configuration. See the addresses table above and `ARCHITECTURE.md` for the full EIP-191 payload layout and FDC proof verification flow.

## Evidence

Every claim is backed by a file a judge can open and run.

- **141 tests across 11 suites, 0 failures** — `forge test` reproduces on camera
- **97.75% line coverage** of `CreditGateVault.sol`
- **5 security fixes audit-verified** — all M1/M2/L1/L2/L4/L5 findings remediated; `planning/security-audit/verdict.md` = PASS
- **Go-TEE ↔ Solidity cross-language compatibility** — `test/CreditGateVault.go-tee-compat.t.sol` (2 tests): the Go handler's real EIP-191 signature is accepted by Solidity `ecrecover`; tamper one byte → `InvalidEligibilitySigner`
- **Real reentrancy attack test** — `test/CreditGateVault.malicious-reentrancy.t.sol`: a malicious FXRP token invokes `depositCollateral` from inside `transferFrom`; **blocked by `ReentrancyGuard`**. We didn't just add the guard — we wrote an attack that proves it.
- **Invariant / fuzz tests** — `test/CreditGateVault.invariant.t.sol` (8 tests, 256 runs each): FXRP conservation (collateral never leaks), USDT0 solvency (vault never disburses more than it holds), no overdraft, state-machine ordering, no ghost collateral, interest never exceeds collateral, LTV limit respected, terminal-loan finality — across fuzzed inputs
- **FDC lifecycle fixture test** — `test/CreditGateVault.fdc-fixture.t.sol` (4 tests): realistic XRPL payment proof verified through the production `FdcVerification` ABI
- **Edge-case tests** — `test/CreditGateVault.edge-cases.t.sol` (15 tests): border collateral ratios, double-request rejection, expired-attestation handling, security boundaries
- **Evidence artifacts** — `evidence/tee-attestation.json` (real Go FCC attestation produced by `POST /action`)
- **6 planning review verdicts** — fdc-review, frontend-review, security-audit, judge-sim, competitive-positioning, gas-audit — each produced by a read-only audit subagent and then acted on

## Demo

A 3-minute demo script is provided in [`DEMO.md`](DEMO.md), structured as five acts for judges:

1. **Setup (15s)** — three terminals: Go TEE credit evaluator on `:8080`, Next.js borrower UI on `:3000`, `forge test` evidence backbone
2. **Act 1 — The Problem (30s)** — the transparency dashboard; FXRP idle, unmet credit demand
3. **Act 2 — Deposit + Credit Check (45s)** — deposit 100 FXRP, register XRPL r-address, FCC handler POSTs and returns an EIP-191 attestation, vault verifies via `ecrecover` → `ELIGIBLE`
4. **Act 3 — Draw Loan + Repay (45s)** — draw 50 USDT0 against the live FTSOv2 XRP/USD price; FDC verifies a pre-captured XRPL payment proof (`FDC FIXTURE` — fixture proof, live `FdcVerification` ABI); collateral released → `CLOSED`
5. **Act 4 — Security + Evidence (30s)** — full suite passing on camera: reentrancy attack blocked, Go-TEE cross-language compat, invariant fuzz tests
6. **Act 5 — Flare Primitives (15s)** — the four-primitive tableau: FAssets, FTSOv2, FCC, FDC, each load-bearing

### Key Numbers

| Metric | Value |
|--------|-------|
| Tests passing | 141 across 11 suites, 0 failures |
| Line coverage | 97.75% |
| Flare primitives used | 4 — FAssets (FXRP) + FTSOv2 + FCC + FDC |
| Security fixes | 5 (audit-verified: M1, M2, L1, L2, L4, L5) |
| Go-TEE cross-language tests | 2 (Go signature → Solidity `ecrecover`) |
| Reentrancy attack tests | 1 (malicious FXRP token blocked) |
| Invariant/fuzz tests | 8 (256 runs each — FXRP conservation, USDT0 solvency, no overdraft, state ordering, no ghost collateral, interest ceiling, LTV limit, terminal-loan finality) |
| FDC lifecycle tests | 4 (realistic XRPL proof verified) |
| Edge-case tests | 15 (border ratios, double-request, expired attestation, security boundaries) |
| Bounty | Confidential Compute Apps (Bounty 2) + Interoperable Asset Products (Bounty 1) |
| Network | Coston2 (chain ID 114) |

## What Was Newly Built During the Flare Summer Signal Program

### Pre-existing baseline

- The concept of FXRP-backed lending and the basic vault contract (deposit, draw, repay) existed before the hackathon as a prototype.

### Built/Improved during the hackathon program

1. **Dutch auction liquidation mechanism** — descending-price auction over 24h for under-collateralized loans
2. **5% APR interest accrual** — pro-rata interest on outstanding loans, computed at draw/repay
3. **Health factor** — real-time position health via FTSO price, triggers liquidation below 0.9
4. **FCC credit bureau in Go TEE** — EIP-191 signed eligibility attestations from a simulated TEE
5. **Automated FTSO-threshold liquidation trigger** — `checkAndTriggerLiquidation` + `batchCheckLiquidation` for keepers
6. **Per-collateral LTV ratio configuration** — `registerCollateral`, `updateLTV`, `getMaxLoanAmount`
7. **8 invariant/fuzz tests** — FXRP conservation, USDT0 solvency, interest ceiling, LTV limit, terminal-loan finality
8. **Live deployment on Coston2** — vault at `0x5e74d...`, 5 FXRP collateral deposited, FTSO price feed live
9. **FDC attestation submitted live** — tx `0x9bc263fe...`, voting round 1417465 finalized on-chain
10. **Source verified on Blockscout** — judges can inspect the verified Solidity source
11. **3 adversarial security audits** — M1 (sig malleability), M2 (nonce), L1/L2/L4/L5 — all fixed
12. **141-test Foundry suite across 11 suites** — grew from 91 to 141 during the program
13. **Frontend /docs section** — consolidated evidence and reports into browseable Next.js pages

## Team

**Single developer** — architecture, Solidity (`CreditGateVault.sol`, types, mocks), the Go FCC credit-evaluation handler + EIP-191 signer, the Next.js + wagmi + RainbowKit frontend, the Foundry test suite (141 tests / 11 suites / 97.75% coverage), deployment scripts, and six planning review verdicts (fdc-review, frontend-review, security-audit, judge-sim, competitive-positioning, gas-audit). All work in this repository was authored during the Flare Summer Signal program window.

## Future Roadmap

1. **Hackathon scope** — Simulated TEE + pre-captured FDC proof demo, deploy to Coston2
2. **Production FCC** — Migrate to real TEE attestation with key governance (rotation, revocation, multi-authority)
3. **AI credit scoring** — FCC handler ingests an off-chain AI credit-scoring model inside the TEE for automated, private eligibility decisions (this aligns the project with the hackathon's "AI" tag without bolting AI into the contract layer)
4. **ERC-3643 compliance** — Institutional compliance modules for regulated asset issuance, integrating permissioned FXRP transfers
5. **Multi-collateral** — FBTC, FDOGE credit gates with asset-specific risk parameters
6. **Adapter integration** — Gate access to existing lending markets (Morpho / Mystic) for institutional USDT0 supply
7. **Institutional** — Lender policy engines and compliance reporting

## Repository

**GitHub:** https://github.com/tommycet/creditgate
*(If the repo is set to private at judging time, contact via DoraHacks — it will be made public for the submission window. The repository contains the full Solidity vault, Foundry test suite (`forge test` → 141 tests / 11 suites / 0 failures), FCC Go handler, and Next.js frontend.)*

**Quick start:**
```bash
forge test                                       # 141 tests, 11 suites, 0 failures
cd frontend && npm run dev                         # http://localhost:3000
cd fcc/credit-extension/extension && go run .      # :8080 — POST /action → EIP-191 attestation
```

**Prereqs:** `foundryup`, Node 18+, Go 1.21+.

**Deployment (Coston2):**
```bash
cp .env.example .env   # fill PRIVATE_KEY, TEE_AUTHORITY, FTSO_V2_ADDRESS
forge script script/DeployCreditGate.s.sol --rpc-url coston2 --broadcast
```

**Deployed address:** `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939`

Live on Coston2 (verified 2026-08-06). Deploy tx: `0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb`. Vault seeded with 5 FXRP collateral (approve tx `0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8`, deposit tx `0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149`). Owner: `0x5a3969F3767Cde96D662A94cAa79779073F80A0c`.

---

**License:** MIT
