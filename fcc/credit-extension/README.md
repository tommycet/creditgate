# CreditGate FCC Extension — README

This directory contains the CreditGate **Flare Compute Extension (FCE)** — the confidential credit evaluator.

## Architecture (per official FCC docs)

```
Borrower → CreditGateVault.depositCollateral()
   ↓
Borrower → CreditGateInstructionSender.evaluateCredit()   (on-chain)
   ↓  TeeExtensionRegistry.sendInstructions()
Data providers relay instruction
   ↓
ext-proxy queues it → TEE node delivers to extension
   ↓
extension POST /action  (Go handler — THIS directory)
   ↓  private credit evaluation
TEE signs EIP-191 eligibility attestation
   ↓  result served via proxy
Borrower polls proxy → gets attestation
   ↓
Borrower → CreditGateVault.submitEligibility(attestation)
   ↓  vault verifies TEE authority signature
Loan → ELIGIBLE → draw USDT0
```

## Components

| Path | Purpose |
|------|---------|
| `contracts/CreditGateInstructionSender.sol` | On-chain entry point (OP_TYPE `CREDIT`, OP_COMMAND `EVALUATE`/`REGISTER_XRPL`) |
| `extension/main.go` | HTTP server running inside the TEE (`/action`, `/state`, `/info`) |
| `extension/handler/handler.go` | Credit evaluation logic + EIP-191 attestation signing |

## Mode

**SIMULATED_TEE** — for the hackathon demo, the signing key is provided via the
`CREDITGATE_SIGNING_KEY` env var (must match the vault's `TEE_AUTHORITY` address).
The contract code and EIP-191 payload shape are identical to production.

## Deploying the full FCC stack (Coston2)

Follow the official scaffold: `https://github.com/flare-foundation/fce-extension-scaffold`

```bash
git clone https://github.com/flare-foundation/fce-extension-scaffold
# Copy the handler/ and contracts/ from this directory
# Set SIMULATED_TEE=true, LOCAL_MODE=false, NORMAL_PROXY_URL=...
./scripts/start-services.sh --chain coston2
./scripts/post-build.sh
./scripts/test.sh
```

## Local test (without TEE)

```bash
go run ./extension  # needs CREDITGATE_SIGNING_KEY
curl -X POST localhost:8080/action -d '{
  "opCommand": "EVALUATE",
  "borrower": "0x...",
  "collateralAmount": "100000000",
  "requestedLoan": "100000000",
  "expiry": "1760000000",
  "nonce": "0",
  "revocationVersion": "0"
}'
```
