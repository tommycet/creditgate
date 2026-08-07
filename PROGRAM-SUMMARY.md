# CreditGate — Program Summary for Improvement Subagents

## Project
CreditGate: Private FXRP credit eligibility layer on Flare. Target: Flare Summer Signal hackathon (DoraHacks, Bounty 2: Confidential Compute Apps, $6K, deadline Aug 14 2026).

## Architecture
Borrower deposits FXRP collateral on Flare Coston2 → FCC Go handler evaluates credit privately and signs EIP-191 attestation → Borrower draws USDT0 loan (FTSO-priced) → Borrower repays on XRPL → FDC verifies repayment proof on-chain → Collateral released.

## File Roles
- `src/CreditGateVault.sol` — Main vault (state machine, collateral, loans, FDC verification)
- `src/CreditGateTypes.sol` — Types, errors, events, constants
- `src/mocks/` — MockERC20, MockFtsoV2, MockFdcVerification
- `test/CreditGateVault.t.sol` — 69 unit tests
- `test/CreditGateVault.fdc-fixture.t.sol` — 4 FDC lifecycle tests
- `test/CreditGateVault.invariant.t.sol` — 8 invariant/fuzz tests
- `test/CreditGateVault.go-tee-compat.t.sol` — 2 cross-language EIP-191 tests
- `test/CreditGateVault.malicious-reentrancy.t.sol` — 1 truly-malicious-token reentrancy attack test
- `test/CreditGateVault.reentrancy.t.sol` — 2 reentrancy / vault-solvency / future-FTSO-edge tests
- `test/CreditGateVault.edge-cases.t.sol` — 15 edge-case tests (border collateral ratios, double-request rejection, expired-attestation handling, security boundaries, etc.)
- `test/CreditGateVault.auction.t.sol` — 5 Dutch auction liquidation tests (startLiquidationAuction / bidOnLiquidation / finalizeAuction, linear price decay)
- `test/CreditGateVault.views.t.sol` — 15 health-factor + loan/portfolio summary view tests (getHealthFactor / getLoanSummary / getPortfolioSummary, interest-aware aggregation)
- `script/DeployCreditGate.s.sol` — Deployment script
- `script/fdcExample/` — FDC request/verify scripts
- `fcc/credit-extension/extension/` — Go FCC handler (credit evaluation + signing, /health endpoint, structured logging)
- `frontend/` — Next.js + wagmi + RainbowKit frontend (landing page stats badges, FCC attestation submission panel, liquidate button, full lifecycle button coverage)
- `evidence/` — Verifiable artifacts: `tee-attestation.json` (real Go FCC attestation), Coston2/FDC/XRPL fixtures & screenshots
- `README.md` — Project overview
- `ARCHITECTURE.md` — EIP-191 payload, FDC flow, Flare primitive addresses
- `DEMO.md` — 90-second demo script

## Current State (159 tests, 13 suites, 0 failures)
- 69 unit + 15 health-factor/view + 15 edge-case + 5 Dutch auction liquidation + 8 invariant/fuzz + 4 FDC fixture + 2 Go-TEE compat + 1 malicious-token reentrancy + 2 reentrancy/solvency/FTSO-edge + 11 LTV-config + 9 liquidation-trigger + 5 security-edge-case
- **Newer features added beyond the M1 security sweep** (grew the suite 91 → 159 tests / 7 → 13 suites):
  1. **Dutch auction liquidation** — when `getHealthFactor` drops below 1.0, anyone can start a linear-decay Dutch auction (`startLiquidationAuction` → `bidOnLiquidation` → `finalizeAuction`); surplus refunds the borrower.
  2. **Interest rate mechanism** — 5% APR simple interest prorated by seconds since draw (`getInterestOwed`), enforced in the FDC repayment check so MemoData must cover principal + accrued interest; `InterestAccrued` emitted on close.
  3. **Health factor & loan/portfolio views** — `getHealthFactor` (collateral×1e18 / (principal+interest), gates liquidation), `getLoanSummary`, `getPortfolioSummary`.
  4. **Mock credit bureau** — FCC TEE consults a reproducible mock bureau (score + attestation-based eligibility) instead of a centralized bureau; only the signed EIP-191 attestation crosses the trust boundary. See `ARCHITECTURE.md` § "Credit evaluation model".
  5. **Automated FTSO-threshold liquidation trigger** (`CreditGateVault.trigger.t.sol`, 9 tests) — `checkAndTriggerLiquidation(loanId)` reads the live FTSOv2 XRP/USD feed and auto-calls `startLiquidationAuction` when the recomputed health factor crosses the undercollateralization threshold, removing the need for a manual keeper. `batchCheckLiquidation(loanIds)` iterates a portfolio in one call; no-ops guard non-`FUNDED` loans, zero-price feeds, and the exact-threshold boundary. `triggeredAuctionIsFullyFunctional` proves the auto-started auction runs through bid + finalize end-to-end.
  6. **Per-collateral LTV ratio configuration** (`CreditGateVault.ltv.t.sol`, 11 tests) — `registerCollateral` / `updateLTV` onboard multiple collateral assets with per-asset loan-to-value ratios (default 65% on FXRP), so `drawLoan` and `getMaxLoanAmount` enforce `collateral × price × LTV ≥ loan` per-token instead of the single immutable `collateralRatioBps`. Per-token LTVs can only tighten below the constructor default; owner-only access control + `CollateralRegistered` / `LTVUpdated` events.
- Frontend builds (6 routes prerendered); landing page stats badges, FCC attestation submission panel, liquidate button, auction panel, health-factor readout, full-state color badges, error banner, token balances
- FCC Go handler ships `/health` endpoint + structured logging + EIP-191 signing accepted by Solidity `ecrecover`
- Security audit: PASS-WITH-NOTES (all fixes applied: M1/M2/L1/L2/L4/L5)
- Gas audit completed; top-3 audit findings applied (subagent 7 verdict written)
- USDT0 18-decimal correction applied across all test suites (was 6-decimal assumption; USDT0 on Coston2 is 18 decimals)
- Coston2 primitive addresses verified live 2026-08-05; `SafeERC20` import + env-var handling fixed in deploy script
- 6 planning verdicts: fdc-review, frontend-review, security-audit, judge-sim, competitive-positioning, gas-audit
- Judge sim v6 verdict (latest, 2026-08-06): **9.5/10** weighted across official criteria (Product usefulness 9.5 · Flare integration 9.7 · Technical execution 9.5 · Evidence of new work 9.4 · Clarity 9.3); previous verdicts v4=9.0, v5=9.4, all from a 7.4 baseline
- Deploy address: LIVE on Coston2 — `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939` (deploy tx `0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb`, 2026-08-06). Vault seeded with 5 FXRP collateral (approve tx `0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8`, deposit tx `0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149`).

## Known Gaps (from judge sim 7.4/10 + competitive positioning)
1. ~~NOT DEPLOYED to Coston2~~ → **RESOLVED**: deployed 2026-08-06 at `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939` with 5 FXRP collateral deposited.
2. No demo video (deployment now available; video pending recording)
3. FDC step is fixture-only (competitor AegisFlow claims "100+ nodes verify")
4. ~~No deployment artifacts~~ → **RESOLVED**: deploy + approve + deposit tx hashes captured (see README "Live Deployment").
5. No .env.example in frontend dir
6. gas audit: only top-3 findings applied; remaining 4 (storage packing, cached reads) pending

## Flare Primitive Contracts (Coston2, verified live 2026-08-05)
- FXRP: 0x0b6A3645c240605887a5532109323A3E12273dc7
- USDT0: 0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3 (18 decimals)
- FdcVerification: 0x906507E0B64bcD494Db73bd0459d1C667e14B933
- FdcHub: 0x48aC463d7975828989331F4De43341627b9c5f1D
- FdcRequestFeeConfigurations: 0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e
- Chain ID: 114, RPC: https://coston2-api.flare.network/ext/C/rpc

## Build Commands
- `forge test` — run all 159 tests across 13 suites
- `cd frontend && npm run build` — build frontend
- `cd fcc/credit-extension/extension && go run .` — start FCC handler (:8080, /health + /action)
