# CreditGate — Program Summary for Improvement Subagents

## Project
CreditGate: Private FXRP credit eligibility layer on Flare. Target: Flare Summer Signal hackathon (DoraHacks, Bounty 2: Confidential Compute Apps, $6K, deadline Aug 14 2026).

## Architecture
Borrower deposits FXRP collateral on Flare Coston2 → FCC Go handler evaluates credit privately and signs EIP-191 attestation → Borrower draws USDT0 loan (FTSO-priced) → Borrower repays on XRPL → FDC verifies repayment proof on-chain → Collateral released.

## File Roles
- `src/CreditGateVault.sol` — Main vault (state machine, collateral, loans, FDC verification)
- `src/CreditGateTypes.sol` — Types, errors, events, constants
- `src/mocks/` — MockERC20, MockFtsoV2, MockFdcVerification
- `test/CreditGateVault.t.sol` — 60 unit tests
- `test/CreditGateVault.fdc-fixture.t.sol` — 4 FDC lifecycle tests
- `test/CreditGateVault.invariant.t.sol` — 5 invariant/fuzz tests
- `test/CreditGateVault.go-tee-compat.t.sol` — 2 cross-language EIP-191 tests
- `test/CreditGateVault.malicious-reentrancy.t.sol` — 3 reentrancy attack tests
- `script/DeployCreditGate.s.sol` — Deployment script
- `script/fdcExample/` — FDC request/verify scripts
- `fcc/credit-extension/extension/` — Go FCC handler (credit evaluation + signing)
- `frontend/` — Next.js + wagmi + RainbowKit frontend
- `README.md` — Project overview
- `ARCHITECTURE.md` — EIP-191 payload, FDC flow, Flare primitive addresses
- `DEMO.md` — 90-second demo script

## Current State (76 tests, 6 suites, 0 failures)
- 60 unit + 4 FDC fixture + 5 invariant/fuzz + 2 Go-TEE compat + 3 reentrancy + 2 solvency/FTSO-edge
- Frontend builds (6 routes prerendered)
- Security audit: PASS-WITH-NOTES (all fixes applied: M1/M2/L1/L2/L4/L5)
- Gas audit completed (subagent 7 verdict written)
- 6 planning verdicts: fdc-review, frontend-review, security-audit, judge-sim, competitive-positioning, gas-audit
- Deploy address: NOT YET DEPLOYED (faucet address 0x5a3969F3767Cde96D662A94cAa79779073F80A0c pending funding)

## Known Gaps (from judge sim 7.4/10 + competitive positioning)
1. NOT DEPLOYED to Coston2 (highest impact — +0.6-0.8 swing)
2. No demo video (needs deployment)
3. FDC step is fixture-only (competitor AegisFlow claims "100+ nodes verify")
4. Frontend missing: submitRepaymentProof UI, submitEligibility UI, liquidate UI
5. No deployment artifacts (broadcast files, verified contract on explorer)
6. No .env.example in frontend dir
7. gas audit findings not yet applied (storage packing, cached reads)

## Flare Primitive Contracts (Coston2, verified live 2026-08-05)
- FXRP: 0x0b6A3645c240605887a5532109323A3E12273dc7
- USDT0: 0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3
- FdcVerification: 0x906507E0B64bcD494Db73bd0459d1C667e14B933
- FdcHub: 0x48aC463d7975828989331F4De43341627b9c5f1D
- FdcRequestFeeConfigurations: 0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e
- Chain ID: 114, RPC: https://coston2-api.flare.network/ext/C/rpc

## Build Commands
- `forge test` — run all 76 tests
- `cd frontend && npm run build` — build frontend
- `cd fcc/credit-extension/extension && go run .` — start FCC handler (:8080)
