# CreditGate

**Private FXRP credit eligibility layer for Flare**

XRP holders deposit FXRP collateral on Flare, receive a confidential eligibility attestation via FCC (Flare Confidential Compute), draw a USDT0 loan, and repay on XRPL. Repayment is verified on-chain via FDC (Flare Data Connector) with a 32-byte MemoData commitment binding.

## How CreditGate Uses Flare

| Primitive | Role | Load-bearing? |
|-----------|------|---------------|
| **FAssets (FXRP)** | Collateral ERC-20 (6 decimals) | ✅ Yes — actual collateral |
| **FTSOv2** | XRP/USD price feed for collateral ratio | ✅ Yes — enforces 150% ratio |
| **FCC** | Private credit eligibility evaluation | ✅ Yes — gates loan drawdown |
| **FDC** | XRPPayment proof verification | ✅ Yes — gates collateral release |

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

## What Was Newly Built (Hackathon)

- `CreditGateVault.sol` — State machine, FXRP/USDT0 custody, collateral ratio enforcement
- `CreditGateInstructionSender.sol` + Go TEE handler — FCC CREDIT/EVALUATE eligibility evaluator (simulated TEE), per official Flare Compute Extension architecture
- XRPL address binding — borrower registers their XRPL r-address; FDC repayment proof must match (prevents repayment substitution)
- 32-byte XRPL MemoData commitment binding — Domain-separated, loan-specific
- FDC repayment proof verification — Status, amount, memo, receiver, and source checks
- Foundry test suite — **74 tests across 6 suites**: 60 unit + 4 FDC lifecycle fixture + 5 invariant/fuzz + 2 Go-TEE cross-language compatibility + 3 reentrancy attack (real malicious-token callback blocked by `ReentrancyGuard`)
- React lifecycle UI — Judge-facing demo interface

**Existing Flare primitives (not claimed as new):** FCC proxy, FDC verifier, FTSO feeds, FXRP token, FDC request fee configuration (`FdcRequestFeeConfigurations` at `0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e`, verified live via ContractRegistry on 2026-08-05).

## Evidence Directory

| File | What it proves |
|------|----------------|
| `test/CreditGateVault.t.sol` | 57 unit tests — all state transitions, error paths, reentrancy |
| `test/CreditGateVault.fdc-fixture.t.sol` | 4 FDC lifecycle tests — realistic XRPL proof verified by vault |
| `test/CreditGateVault.invariant.t.sol` | 5 invariant/fuzz tests — FXRP conservation, USDT0 solvency, state ordering |
| `test/CreditGateVault.go-tee-compat.t.sol` | 2 cross-language tests — Go TEE signature accepted by Solidity ecrecover |
| `evidence/tee-attestation.json` | Real attestation produced by the Go FCC handler (POST /action) |
| `planning/fdc-review/verdict.md` | FDC script review (PASS-WITH-NOTES, fee bug fixed) |
| `planning/frontend-review/verdict.md` | Frontend review (6 lifecycle UX gaps found and fixed) |
| `test/CreditGateVault.malicious-reentrancy.t.sol` | Real reentrancy attack: malicious FXRP token calls depositCollateral from transferFrom — blocked by ReentrancyGuard |
| `ARCHITECTURE.md` | EIP-191 payload layout, FDC proof verification flow, Flare primitive contracts, security fixes |

## Deployment

**Network:** Coston2 testnet (chain ID 114)

| Contract | Address |
|----------|---------|
| CreditGateVault | `<DEPLOYED_ADDRESS>` |
| FXRP | `0x0b6A3645c240605887a5532109323A3E12273dc7` |
| USDT0 | `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` |
| FdcVerification | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` |

**RPC:** `https://coston2-api.flare.network/ext/C/rpc`
**Explorer:** `https://coston2-explorer.flare.network`

## Evidence Modes

| Surface | Label | Status |
|---------|-------|--------|
| Coston2 vault/deposit/draw txs | `LIVE Coston2` | After deployment |
| FCC eligibility | `SIMULATED TEE` | Simulated path, same EIP-191 signature shape |
| XRPL payment | `LIVE XRPL TESTNET` | Live transaction captured |
| FDC proof | `LIVE FDC` or `FDC FIXTURE` | Depends on verifier API access |
| Mocks in Foundry | `TEST FIXTURE` | Never presented as deployed evidence |

## Quick Start

```bash
# Clone and install
git clone https://github.com/<org>/creditgate.git
cd creditgate
forge install

# Run tests (68 tests: unit + FDC fixture + invariant/fuzz + Go-TEE compat)
forge test

# Deploy to Coston2
cp .env.example .env
# Fill in PRIVATE_KEY, TEE_AUTHORITY, FTSO_V2_ADDRESS
forge script script/DeployCreditGate.s.sol --rpc-url coston2 --broadcast
```

### Frontend

```bash
cd frontend
npm install
# Set the deployed vault address
echo "NEXT_PUBLIC_VAULT_ADDRESS=<deployed-address>" > .env.local
npm run dev   # http://localhost:3000
# or production build:
npm run build && npm start
```

### FCC Credit Extension (Go TEE handler)

```bash
cd fcc/credit-extension/extension
# Set the signing key (same as TEE_AUTHORITY in .env)
export CREDITGATE_SIGNING_KEY=<your-private-key-hex>
go run .  # listens on :8080
# POST /action → returns EIP-191 eligibility attestation
```

## Roadmap

1. **Hackathon scope** — Simulated TEE + pre-captured FDC proof demo
2. **Production FCC** — Migrate to real TEE attestation with key governance
3. **Multi-collateral** — FBTC, FDOGE credit gates with asset-specific risk
4. **Adapter integration** — Gate access to existing lending markets (Morpho/Mystic)
5. **Institutional** — Compliance modules and lender policy engines

## License

MIT
