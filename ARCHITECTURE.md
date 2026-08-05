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

## Security Fixes Applied (Audit-Verified)

| ID | Severity | Fix |
|----|----------|-----|
| M1 | MEDIUM | Signature s/v bounds check + recovered≠0 in submitEligibility |
| M2 | MEDIUM | Increment borrowerNonce in revokeEligibility (rotate outstanding attestations) |
| L1 | LOW | Re-check eligibilityExpiry in drawLoan (was only checked at submission) |
| L4 | LOW | recoverDefaultedCollateral — owner can recover seized FXRP |
| L5 | LOW | Snapshot borrowerSourceAddressHash at draw time (prevent re-binding attack) |
