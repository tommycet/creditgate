# CreditGate — Demo Script

## Overview

This demo shows the complete CreditGate lifecycle on Coston2 testnet:
1. Borrower deposits FXRP collateral
2. TEE evaluates eligibility and signs attestation
3. Borrower draws a USDT0 loan against collateral
4. Borrower repays on XRPL
5. FDC verifies the repayment proof
6. Collateral is released

## Demo Flow (90 seconds)

### Step 1: Deposit Collateral (10s)
- Navigate to `/app`
- Connect Flare wallet (MetaMask, Coston2 network)
- Enter 100 FXRP as collateral
- Click "Deposit"
- Transaction confirmed on Coston2

### Step 2: Request Eligibility (5s)
- Click "Request Eligibility"
- FCC extension evaluates creditworthiness
- EIP-191 attestation signed (simulated TEE)

### Step 3: Submit Eligibility (5s)
- Click "Submit Attestation"
- Vault verifies TEE signature
- Loan transitions to ELIGIBLE

### Step 4: Draw Loan (10s)
- Enter 100 USDT0 (within 150% collateral ratio)
- Click "Draw Loan"
- FTSOv2 reads live XRP/USD price
- Collateral ratio checked
- USDT0 disbursed to borrower

### Step 5: Repay on XRPL (30s)
- Switch to XRPL testnet wallet
- Send 40 XRP drops to vault address
- Include 32-byte commitment as MemoData
- Transaction confirmed on XRPL

### Step 6: Verify Repayment (15s)
- Click "Submit Repayment Proof"
- FDC fetches XRPL payment proof
- `verifyXRPPayment()` checks status, amount, memo
- Collateral released back to borrower
- Loan transitions to CLOSED

### Step 7: Transparency View (10s)
- Navigate to `/transparency`
- Show: loan history, FTSO prices, FDC proofs
- All evidence on-chain and verifiable

## Evidence Labels in Demo

| Step | Evidence Mode |
|------|---------------|
| Deposit/Draw | `LIVE Coston2` — real on-chain tx |
| Eligibility | `SIMULATED TEE` — same EIP-191 shape as production |
| Repayment | `LIVE XRPL TESTNET` — real XRPL tx |
| FDC Proof | `SIMULATED FDC FIXTURE` — pre-captured proof verified locally |

## Key Selling Points for Judges

1. **Four Flare primitives, all load-bearing** — FCC gates eligibility, FDC gates release, FTSO enforces ratio, FXRP is collateral
2. **Two rejection paths visible** — stale/revoked eligibility + memo mismatch
3. **Real on-chain state transitions** — every step emits events on Coston2
4. **Clear separation** — platform primitives vs new CreditGate code is documented

## Recording Notes

- Use screen recording at 1080p
- Show terminal for transaction hashes
- Narrate each step with the Flare primitive being used
- Total video: 90 seconds max
- Target: <8MB for Discord upload
