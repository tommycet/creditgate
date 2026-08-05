# CreditGate — Architecture

## System Overview

```
┌─────────────┐     1. Deposit FXRP      ┌──────────────────┐
│   Borrower   │ ──────────────────────→ │  CreditGateVault  │
│  (EVM wallet) │                         │   (Coston2)       │
└──────┬───────┘     2. Register XRPL     │                  │
       │            r-address hash         │  State Machine:  │
       │            ─────────────────→   │  IDLE→DEPOSITED  │
       │                                    │  →PENDING→      │
       │  3. Request Eligibility            │  ELIGIBLE→       │
       │            ─────────────────→   │  FUNDED→CLOSED   │
       │                                    └────────┬─────────┘
       │                                             │
       │  4. FCC evaluates (off-chain)              │ 5. Draw USDT0
       │                                             ▼
       │  ┌──────────────────┐                ┌──────────────┐
       │  │  FCC Go Handler   │                │  FTSOv2      │
       │  │  (TEE simulated)  │                │  XRP/USD     │
       │  │                  │                │  price feed  │
       │  │  POST /action    │                └──────────────┘
       │  │  → EIP-191 sig   │
       │  └────────┬─────────┘
       │           │ 6. Attestation (v,r,s + limit + expiry)
       │           ▼
       │  ┌──────────────────┐
       │  │  Vault verifies   │
       │  │  ecrecover == TEE │
       │  │  authority        │
       │  └──────────────────┘
       │
       │  7. Repay on XRPL (send drops + 32-byte memo)
       │            ───────────────────────→ XRPL Testnet
       │
       │  8. FDC verifies XRPL payment
       │            ←─────────────────────── FDC Verifier
       │                        │
       │                        ▼
       │  9. submitRepaymentProof(loanId, proof)
       │            ─────────────────→ Vault checks:
       │                                • verifyXRPPayment(proof) == true
       │                                • receivedAmount >= requiredRepaymentDrops
       │                                • receivingAddressHash == loan snapshot
       │                                • firstMemoData == loan.expectedCommitment
       │                                • proofConsumed[proofHash] == false
       │                        │
       │                        ▼
       │                         Collateral released → CLOSED
```

## EIP-191 Eligibility Attestation Payload

The cross-language compatibility between the Go FCC handler and the Solidity vault hinges on **byte-identical** payload construction. Both sides must produce the exact same `keccak256` hash.

### Payload Construction (Solidity + Go produce identical bytes)

```
Domain Separator:
  keccak256("CREDITGATE_ELIGIBILITY_V1")     ← 32 bytes

Payload Hash:
  keccak256(abi.encode(
      DOMAIN,                    // bytes32
      borrower,                  // address  → 20 bytes, left-padded to 32
      limit,                     // uint256  → the credit limit (6-decimals USDT0)
      expiry,                    // uint64   → block.timestamp deadline
      nonce,                     // uint32   → borrowerNonce at request time
      revocationVersion          // uint8    → borrowerRevocationVersion
  ))

EIP-191 Signed Message:
  keccak256(abi.encodePacked(
      "\x19Ethereum Signed Message:\n32",    // EIP-191 prefix
      payloadHash                            // 32 bytes
  ))

Signature:
  (v, r, s) = vm.sign(teePrivateKey, ethSignedHash)
  → v ∈ {27, 28}
  → s ≤ secp256k1n / 2     (M1 fix: malleability check)
```

### Cross-Language Proof

`test/CreditGateVault.go-tee-compat.t.sol` proves this: it hardcodes a real signature produced by the Go FCC handler (via `POST /action` to `localhost:8080`), feeds it to the Solidity vault's `submitEligibility`, and confirms the loan transitions to `ELIGIBLE`. A tampered limit (100e6 → 101e6) correctly reverts with `InvalidEligibilitySigner`.

## FDC Repayment Proof Verification

```
XRPL Payment (off-chain):
  borrower sends `requiredRepaymentDrops` XRP to the vault's XRPL address
  with `expectedCommitment` (32 bytes) as MemoData

FDC Attestation:
  1. Submit request: FdcHub.requestAttestation{value: fee}(abi.encode(request))
     - attestationType: bytes32("XRPPayment")
     - sourceId: bytes32("testXRP") for testnet
     - requestBody: { transactionId, proofOwner }
  2. Wait for voting round finalization (~180s on Coston2)
  3. Retrieve proof from DA layer
  4. Verify: FdcVerification.verifyXRPPayment(proof) → bool

Vault Checks (submitRepaymentProof):
  • verifyXRPPayment(proof) == true
  • resp.status == 1 (success)
  • resp.receivedAmount >= loan.requiredRepaymentDrops
  • resp.hasMemoData == true
  • resp.firstMemoData.length == 32
  • bytes32(resp.firstMemoData) == loan.expectedCommitment
  • resp.receivingAddressHash == loan.borrowerSourceAddressHash  ← L5 snapshot
  • proofConsumed[keccak256(abi.encode(proof))] == false         ← anti-replay
```

## Flare Primitives (load-bearing)

| Primitive | Contract (Coston2) | Role |
|-----------|-------------------|------|
| FAssets (FXRP) | `0x0b6A3645c240605887a5532109323A3E12273dc7` | Collateral ERC-20 (6 decimals) |
| FTSOv2 | `getFeedByIdInWei(XRP_USD_FEED_ID)` | XRP/USD price → 150% collateral ratio |
| FDC | `FdcVerification: 0x906507E0B64bcD494Db73bd0459d1C667e14B933` | XRPPayment proof verification |
| FCC | Go handler (`fcc/credit-extension/extension/main.go`) | Private credit eligibility → EIP-191 attestation |
| FdcRequestFeeConfigurations | `0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e` | Request fee for FDC attestation |

## FCC Credit Evaluation Model (Gap #4)

The Go FCC handler (`fcc/credit-extension/extension/handler/handler.go`) implements a real credit evaluation pipeline — not just a signature over a raw number:

```
POST /action  (JSON body from TEE proxy)
  {
    "opCommand": "EVALUATE",
    "borrower": "0xDE62..."
    "collateralAmount": "100000000",   // FXRP 6dp
    "requestedLoan": "100000000",     // USDT0 6dp
    "expiry": "1893456000",
    "nonce": "0",
    "revocationVersion": "0"
  }

Response (JSON):
  {
    "eligible": true,
    "limit": "100000000",
    "reason": "",
    "attestation": {
      "borrower": "0xDE62...",
      "limit": "100000000",
      "expiry": "1893456000",
      "nonce": "0",
      "revocationVersion": "0",
      "v": 27,
      "r": "d8174e...",
      "s": "200618..."
    }
  }
```

### Evaluation pipeline (handler.go:133-185)

1. **Input validation** — non-zero borrower, non-negative collateral/loan, parseable expiry/nonce
2. **Revocation check** — if `eligibilityRevoked[borrower]` is true, deny with `BORROWER_REVOKED`
3. **Collateral sufficiency** — mirrors vault's `drawLoan` math: `collateral * xrpUsdPrice / 1e18 * 10000 >= requested * collateralRatioBps`. If insufficient, deny with `INSUFFICIENT_COLLATERAL`
4. **Limit derivation** — `limit = min(requested, borrowerLimit)` where `borrowerLimit` is a per-borrower cap (in production, derived from private off-chain credit data inside the TEE)
5. **EIP-191 signing** — `keccak256(abi.encode(DOMAIN, borrower, limit, expiry, nonce, revocationVersion))` with the `\x19Ethereum Signed Message:\n32` prefix
6. The signature `(v, r, s)` is returned to the borrower, who submits it to `CreditGateVault.submitEligibility`

### Production vs simulated

In production (per the [FCC Private Key Extension pattern](https://dev.flare.network/fcc/overview)):
- The signing key is generated inside the TEE and never leaves the enclave
- Credit data (credit score, income, debt-to-income) is fetched by the TEE from private data sources
- The `limits` map is populated from the TEE's confidential computation, not hardcoded

In the hackathon demo (SIMULATED_TEE mode):
- The signing key is loaded from `CREDITGATE_SIGNING_KEY` env var (matches `TEE_AUTHORITY` in the vault)
- The XRP/USD price and collateral ratio are configurable via env vars
- The `limits` map is populated per-borrower at startup



## Security Fixes Applied (Audit-Verified)

| ID | Severity | Fix |
|----|----------|-----|
| M1 | MEDIUM | Signature s/v bounds check + recovered≠0 in submitEligibility |
| M2 | MEDIUM | Increment borrowerNonce in revokeEligibility (rotate outstanding attestations) |
| L1 | LOW | Re-check eligibilityExpiry in drawLoan (was only checked at submission) |
| L4 | LOW | recoverDefaultedCollateral — owner can recover seized FXRP |
| L5 | LOW | Snapshot borrowerSourceAddressHash at draw time (prevent re-binding attack) |
