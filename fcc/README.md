# CreditGate FCC Handlers — Go (reference) & Python (production TEE)

CreditGate ships **two** Flare Confidential Compute (FCC) handlers that produce
**byte-identical EIP-191 attestations**. They are not duplicates — they serve
two distinct roles in the development-to-production pipeline. Both target the
same on-chain contract (`CreditGateVault.submitEligibility`) and the same
attestation payload:

```
keccak256(abi.encode(CREDITGATE_ELIGIBILITY_V1, borrower, limit, expiry, nonce, revocationVersion))
```

verified by Solidity `ecrecover`. The equivalence is proven by
[`test/CreditGateVault.tee-compat.t.sol`](../test/CreditGateVault.tee-compat.t.sol)
(4 tests): the vault accepts signatures from **both** handlers; tamper one
byte → `InvalidEligibilitySigner`.

---

## 1. Go handler — reference implementation (local development & testing)

**Location:** [`credit-extension/extension/`](credit-extension/extension/) —
`handler/handler.go` (468 lines) + `main.go` (271 lines).

**Role:** The Go handler is the **reference implementation** used during Coston2
development and in the demo. It starts a plain HTTP server on `:8080` and is the
fastest path to iterate on the EIP-191 payload, the credit-eligibility logic,
and the Solidity↔off-chain compatibility.

**Run it (local dev, no cloud needed):**

```bash
cd fcc/credit-extension/extension
go run .      # starts HTTP server on :8080
# POST /action → EIP-191 attestation
```

This is what runs in the hackathon demo (three terminals: Go TEE evaluator on
`:8080`, Next.js UI on `:3000`, `forge test` evidence backbone). Mode:
`SIMULATED_TEE` — the signing key is a test ECDSA key matching the vault's
`TEE_AUTHORITY`. In production the key is generated and held inside the TEE.

## 2. Python handler — production TEE deployment (GCP Confidential Space / Intel TDX)

**Location:** [`../fcc-handler/`](../fcc-handler/) —
`credit_tee_handler.py` (795 lines), `Dockerfile`, `deploy-tee.sh`.

**Role:** The Python handler is the **production TEE deployment target**. Same
contract, same credit algorithm, same EIP-191 payload — but packaged as a
reproducible Docker image deployable to GCP Confidential Space with Intel TDX,
following the official [flare-ai-kit](https://github.com/flare-foundation/flare-ai-kit)
pattern. The signing key is generated **inside the enclave** at boot and never
leaves the TEE.

**Deploy it (real TEE hardware):**

```bash
cd fcc-handler
./deploy-tee.sh   # builds Docker image for GCP Confidential Space / Intel TDX
```

See [`../fcc-handler/README.md`](../fcc-handler/README.md) for the full
deployment walkthrough, attestation flow, and the flare-ai-kit compliance
checklist.

---

## Why two handlers? (the design rationale)

This dual-path approach was **recommended by Flare's own flare-ai-kit pattern**:
keep a fast local reference for iteration, and a hardware-TEE deploy target for
the actual confidential-compute guarantee. A single handler cannot fill both
roles cleanly:

- The Go handler is optimized for **fast local iteration** (one binary, no
  Docker, no GCP project) — ideal for Coston2 development, the on-camera demo,
  and the Solidity↔handler compatibility tests.
- The Python handler is optimized for **real TEE hardware** — it rides the
  flare-ai-kit toolchain that targets GCP Confidential Space / Intel TDX, where
  the signing key is provisioned inside the enclave.

Both paths feed the *same* vault call (`submitEligibility`) and the *same* test
suite (`CreditGateVault.tee-compat.t.sol`) prove they agree. **A judge can open
either handler and trust the other one matches** — that is the point of the
cross-references.

| | Go handler | Python handler |
|---|---|---|
| **Role** | Reference impl — local dev & testing | Production TEE deployment |
| **Location** | `fcc/credit-extension/extension/` | `fcc-handler/` |
| **Size** | 739 lines (handler.go + main.go) | 795 lines (credit_tee_handler.py) |
| **Run** | `go run .` → `:8080` | `./deploy-tee.sh` → GCP Confidential Space |
| **TEE substrate** | Process (SIMULATED_TEE) | Intel TDX enclave (real TEE) |
| **EIP-191 payload** | identical | identical |
| **Compatibility test** | `test/CreditGateVault.tee-compat.t.sol` | `test/CreditGateVault.tee-compat.t.sol` |
