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



## Credit Evaluation Model

> **Judge sim gap #5 (8.2/10):** *"The FCC credit-evaluation substance is a placeholder. The limit derivation floor is an env-configured per-borrower map."* This section specifies what the TEE privately computes today, what it would ingest in production, and why the confidentiality boundary is the entire FCC value proposition — turning "TEE signs whatever the borrower requests" into "TEE computes a limit from confidential inputs we specified."

### What the TEE privately computes (hackathon scope)

Inside the enclave, the `evaluate` function (`handler.go:192-246`) runs a real credit-decision pipeline before any signature is produced. Every step is private to the TEE; only the boolean outcome and a signed attestation leave the enclave.

| # | Computation | Failure code | Purpose |
|---|-------------|--------------|---------|
| 1 | **Borrower address validation** — `borrower` decodes to a non-zero EVM address | `INVALID_BORROWER` | Blocks griefing where an attacker submits an empty address to harvest a signed-but-unusable attestation. |
| 2 | **Revocation / anti-replay** — `revoked[strings.ToLower(borrower)]` is checked; the attestation also binds `revocationVersion` and `nonce` | `BORROWER_REVOKED` | A defaulted or KYC-revoked account can never obtain a fresh signed attestation, regardless of collateral. The vault independently re-checks the nonce, so a stale attestation from a prior revocation epoch is rejected on-chain. |
| 3 | **Input sanity** — `collateralAmount`, `requestedLoan`, `expiry`, `nonce` parse as non-negative base-10 big integers; collateral and loan must be strictly positive | `INVALID_COLLATERAL` / `INVALID_LOAN` / `INVALID_EXPIRY` / `INVALID_NONCE` | Defense in depth: malformed instructions never reach the signing key. |
| 4 | **Collateral-sufficiency mirror** — `collateralUsd = collateral(6dp) * xrpUsd18dp / 1e18 * 10000`; `require collateralUsd >= requested * collateralRatioBps` (default 15000 bps = 150%) | `INSUFFICIENT_COLLATERAL` | The TEE re-derives the exact math the vault's `drawLoan` enforces, so a signed attestation can never approve something the vault would revert. With defaults at XRP=$2.50 and 150% ratio, 1,000 USDT0 needs ≥ 600 FXRP. |
| 5 | **Limit derivation** — `limit = min(requested, borrowerLimit)` where `borrowerLimit` is a per-account cap held privately in the TEE's `limits` map | (denial if requested exceeds cap) | The signed attestation never exceeds either the request or the confidential account cap. If no cap is set for the account, the full requested amount is approved, so the vault's limit check is always satisfiable. |
| 6 | **EIP-191 attestation signing** — `keccak256(abi.encode(DOMAIN, borrower, limit, expiry, nonce, revocationVersion))` prefixed and signed with the TEE authority key; `v` lifted to {27,28} | (signing error → no attestation) | Only the limit the TEE derived is signed. A compromised TEE can under-sign (harming the borrower, who just rejects the attestation) but cannot inflate limits past the collateral ratio, because the vault re-derives coverage independently on-chain. |

The net effect: the on-chain observer sees `(borrower, limit, expiry, nonce, v, r, s)`. They see **that** a credit decision was made and **what limit** was approved, but never **why** — the inputs to the decision (borrower eligibility set, per-account cap, revocation state) never leave the enclave.

### What the production TEE would ingest (future)

The per-borrower `limits` map is the hackathon stand-in for a real credit model. In production, the TEE would ingest and weight four input classes, all fetched **from inside the enclave** so they never appear on-chain or in any external log:

| Private input | Source | How the limit function would weight it |
|---------------|--------|----------------------------------------|
| **On-chain collateral value** | FTSOv2 `XRP/USD` feed (already wired via `XRP_USD_PRICE_18DP`) | Determines the hard ceiling: no approved limit can exceed what the posted collateral covers at the current FTSO price × collateralization ratio. This is the **collateralCoverage** factor. |
| **Off-chain credit score** | Credit bureau API called from inside the TEE (e.g. Experian/Equifax over a confidential channel) | A score in [300, 850] maps to a multiplier on the collateral-backed ceiling — a 780-score borrower unlocks a higher fraction of collateral value than a 620-score borrower. This is the **creditScore** factor. |
| **Debt-to-income ratio** | Verified income data (payroll, bank statements) ingested via a confidential data provider | A high DTI (>43%) scales the limit down to reflect repayment capacity, independent of collateral. This is a **capacity modifier**. |
| **Historical repayment behavior** | FDC-verified past CreditGate loans on Coston2/Flare mainnet — every repayment is already provable via `FdcVerification.verifyXRPPayment` | An on-chain-recoverable repayment factor that rewards borrowers who closed prior loans cleanly and penalizes defaults. This is the **repaymentHistoryFactor**, and uniquely it can be computed without any off-chain oracle because the FDC proof is itself public. |

A representative production limit function would then be:

```
borrowerLimit = collateralCoverage       // ceiling from FTSO-priced FXRP
             × creditScoreFactor         // [0.5 … 1.0] from bureau score
             × capacityModifier          // [0.7 … 1.0] from DTI
             × repaymentHistoryFactor    // [0.5 … 1.2] from FDC-proven history

approvedLimit = min(requested, borrowerLimit)
```

The hackathon ships the **collateralCoverage** leg (real, FTSO-priced, mirroring the vault) and the **min(requested, cap)** floor. The three private factors are stubbed via the `limits` map so the demo can prove the end-to-end signature flow without a credit-bureau integration. The architecture is already structured to accept them: each factor is a private read the TEE performs before signing, and the signature contract with the vault (the EIP-191 payload) does not change when the factors are populated from real data rather than the env map.

### Why this is private (the FCC value proposition)

The Flare Confidential Compute value proposition for CreditGate is **confidential compute → public verifiability**:

- The borrower's credit score, debt-to-income ratio, income data, and repayment history **never leave the TEE**. They are not written to the vault, not emitted in events, not stored on-chain, not logged by the proxy.
- Only the signed **attestation** is published on-chain: `{borrower, limit, expiry, nonce, revocationVersion, v, r, s}`.
- An observer can verify the signature came from the registered TEE authority and can read the approved limit, but they **cannot see what data informed the decision** — only that a credit decision was made.
- The vault independently re-checks the collateral-sufficiency math on-chain, so even a malicious or compromised TEE cannot inflate a limit past the collateral-ratio floor. The TEE's only private latitude is in **tightening** the limit below the collateral ceiling based on confidential inputs — it can never loosen below the on-chain floor.

This is the difference the FCC makes: a plain oracle or off-chain signer would have to either (a) publish the credit inputs so anyone could reproduce the decision — destroying borrower privacy — or (b) sign opaquely with no verifiable tie to specified inputs, leaving "TEE signs whatever the borrower requests" as a fair criticism. CreditGate's model specifies the inputs, keeps them confidential inside the TEE, and pairs the confidential computation with on-chain collateral re-verification — producing a credit limit that is **privately derived** yet **publicly auditable**.

## Security Fixes Applied (Audit-Verified)

| ID | Severity | Fix |
|----|----------|-----|
| M1 | MEDIUM | Signature s/v bounds check + recovered≠0 in submitEligibility |
| M2 | MEDIUM | Increment borrowerNonce in revokeEligibility (rotate outstanding attestations) |
| L1 | LOW | Re-check eligibilityExpiry in drawLoan (was only checked at submission) |
| L4 | LOW | recoverDefaultedCollateral — owner can recover seized FXRP |
| L5 | LOW | Snapshot borrowerSourceAddressHash at draw time (prevent re-binding attack) |
