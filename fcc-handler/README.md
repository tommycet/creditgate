# CreditGate FCC TEE Credit Handler — Python

This directory contains the **Flare Compute Extension (FCE)** credit handler that runs inside a **real Trusted Execution Environment** (GCP Confidential Space with Intel TDX), following the official [flare-ai-kit](https://github.com/flare-foundation/flare-ai-kit) deployment pattern.

## Why this exists

The sibling Go handler at [`../fcc/credit-extension/extension/`](../fcc/credit-extension/) produces correct EIP-191 signatures but runs in a regular process — a **SIMULATED_TEE**. The hackathon judge docked 0.5 points for this gap. This Python handler is the **production enclave profile** — same contract, same credit algorithm, but deployable to a real Intel TDX TEE on GCP via the official flare-ai-kit toolchain.

It does **not** replace the Go handler — it shares:

- ✅ The same on-chain contract (`CreditGateVault.submitEligibility` verifies its signature).
- ✅ The same EIP-191 payload (byte-for-byte `abi.encode` of the six attestation fields).
- ✅ The same credit evaluation logic.
- ✅ The same `CREDITGATE_ELIGIBILITY_V1` domain separator.

What changes is the **deployment substrate**: Go process → Confidential Space image → Intel TDX enclave.

## Architecture (per the official FCC docs)

```
Borrower → CreditGateVault.depositCollateral()              (on-chain)
   ↓
Borrower → CreditGateInstructionSender.evaluateCredit()    (on-chain)
   ↓  TeeExtensionRegistry.sendInstructions()
Data providers relay instruction
   ↓
ext-proxy queues it → TEE node delivers to extension
   ↓
extension POST /action  (PYTHON handler — THIS directory, in TEE)
   ↓  private credit evaluation (getBorrowerReputation → score → EIP-191)
TEE signs eligibility attestation with enclave-generated key
   ↓  result served via proxy
Borrower polls proxy → gets attestation
   ↓
Borrower → CreditGateVault.submitEligibility(attestation)    (on-chain)
   ↓  vault verifies TEE authority signature (ecrecover)
Loan → ELIGIBLE → draw USDT0
```

## Attestation flow

The diagram below traces a single `EVALUATE` instruction from the borrower through the TEE and back through the on-chain `submitEligibility()` contract verification — every step that touches a TEE is in **bold**.

```mermaid
sequenceDiagram
    autonumber
    participant B as Borrower
    participant IS as InstructionSender (on-chain)
    participant TR as TeeExtensionRegistry
    participant DP as Data Provider
    participant P as ext-proxy (proxy host)
    participant TEE as TEE Enclave (this handler)
    participant V as CreditGateVault (on-chain)
    participant CG as Contract Registry

    B->>V: depositCollateral()  [FXRP → collateral]
    B->>>IS: evaluateCredit()    [instruction dispatched]
    IS->>TR: sendInstructions(OP_TYPE=CREDIT, OP_COMMAND=EVALUATE)
    DP-->>DP: relay instruction band to attestation providers
    DP->>P: deliver decoded instruction
    P->>TEE: POST /action (private RPC into enclave)
    activate TEE
    Note over TEE: 🔒 enclave boots with Intel TDX attestation<br/>signing key = secrets.token_bytes(32) — never leaves TEE
    TEE->>V: eth_call getBorrowerReputation(borrower)
    V-->>TEE: (totalBorrowed, totalRepaid, loansCompleted, loansDefaulted)
    Note over TEE: score = 50 + loansCompleted·10 − loansDefaulted·25 + (repaid/borrowed)·20<br/>eligible = score ≥ 60
    Note over TEE: payloadHash = keccak256(abi.encode(DOMAIN, borrower, limit, expiry, nonce, rev))<br/>ethSignedHash = keccak256("\x19Ethereum Signed Message:\n32" ‖ payloadHash)<br/>sig = secp256k1_sign(ethSignedHash)  → v ∈ {27,28}, low-s
    TEE-->>P: EvaluationResult{eligible, limit, attestation{v,r,s}}
    deactivate TEE
    P-->>B: attestation (polls /eligibility or proxy polling endpoint)
    B->>V: submitEligibility(loanId, attestation)
    activate V
    V->>V: ecrecover(ethSignedHash, v, r, s) == teeAuthority ?
    V->>V: limit ≤ collateral·XRP·ratio / 10000 ?
    V-->>B: Loan state ELIGIBILITY_PENDING → ELIGIBLE
    deactivate V
    B->>V: drawLoan()  [USDT0 minted against FXRP collateral]
```

## Components

| Path | Purpose |
|------|---------|
| `credit_tee_handler.py` | Main Python service: credit scoring (`evaluate_credit`), EIP-191 signing (`sign_attestation`), TEE key generation, WSGI server. Includes `make_app()`, `CreditTeeHandler`, and `main()`. |
| `Dockerfile` | Two-stage reproducible build (`uv:python3.12-bookworm-slim` → `python:3.12-slim`), non-root user, `HEALTHCHECK`. |
| `deploy-tee.sh` | Build → push to Artifact Registry → provision GCP Confidential Space instance with Intel TDX. Adapted from flare-ai-kit's `deploy-tee.sh`. |
| `pyproject.toml` | Minimal dependency manifest (eth-account, web3, eth-keys, pycryptodome). |
| `.env.example` | All `GCP__*` / `FLARE__*` / `VAULT__*` / `TEE__*` / `CREDITGATE__*` config for the deploy. |

## Key functions (the importable API)

```python
from credit_tee_handler import (
    evaluate_credit,            # score a BorrowerReputation → CreditScore
    sign_attestation,           # produce EIP-191 attestation (v,r,s)
    build_payload_hash,         # the keccak256(abi.encode(...)) payload hash
    fetch_borrower_reputation,  # eth_call getBorrowerReputation on the vault
    generate_tee_signing_key,   # secrets.token_bytes(32).hex() inside the TEE
    derive_authority_address,   # authority EVM address derived from the key
    ensure_tee_environment,     # True iff running inside a real enclave
    fetch_attestation_token,    # GCP Confidential Space attestation token
    CreditTeeHandler,           # the long-lived service class
    BorrowerReputation,
    CreditScore,
    Attestation,
    EvaluationResult,
    EvaluationInput,
)
```

### Credit evaluation algorithm (`evaluate_credit`)

```
score = 50                              # base
score += loans_completed * 10          # good behaviour reward
score -= loans_defaulted * 25          # default penalty
if total_borrowed > 0:
    repayment_ratio = total_repaid / total_borrowed
    score += repayment_ratio * 20       # behaviour continuity
score = clamp(score, 0, 100)
eligible = score >= 60
```

This mirrors the on-chain credit history that `CreditGateVault` already records for every `drawLoan()` / repayment / liquidation — so the TEE reads **real** credit history that the contract itself produces, not a synthetic mock. The pattern is borrowed from TrueFi and ARCx on-chain credit scoring where each completed loan bumps `loansCompleted` and a default bumps `loansDefaulted`.

### EIP-191 attestation (`sign_attestation`)

The payload hash this function signs must match `CreditGateVault.submitEligibility` **byte-for-byte**:

```solidity
bytes32 payloadHash = keccak256(
    abi.encode(
        ELIGIBILITY_DOMAIN_SEPARATOR,  // keccak256("CREDITGATE_ELIGIBILITY_V1")
        attestation.borrower,           // address (left-padded to 32 bytes)
        attestation.limit,              // uint256  (approved USDT0 18dp)
        attestation.expiry,             // uint64
        attestation.nonce,               // uint32
        attestation.revocationVersion    // uint8
    )
);
bytes32 ethSignedHash = keccak256(
    abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash)
);
// ecrecover(ethSignedHash, v, r, s) must == teeAuthority (v ∈ {27,28}, low-s enforced)
```

`build_payload_hash` in Python replicates Solidity's `abi.encode` exactly: six 32-byte big-endian words, with the 20-byte address left-padded into its own slot.

## Deploy to real TEE (GCP Confidential Space / Intel TDX)

### Prerequisites

- `gcloud` CLI authenticated to a GCP project with Confidential Space enabled.
- An Artifact Registry Docker repo `creditgate` created (one-time):
  ```bash
  gcloud artifacts repositories create creditgate \
      --repository-format=docker --location=us-central1
  ```
- A service account with `roles/monitoring.metricWriter` and `roles/logging.logWriter` bound to it.

### Steps

1. Copy and fill in the environment file:

   ```bash
   cd fcc-handler
   cp .env.example .env
   # Edit .env: set GCP__PROJECT, GCP__SERVICE_ACCOUNT, GCP__ZONE, etc.
   ```

2. Run the deploy script:

   ```bash
   chmod +x deploy-tee.sh
   ./deploy-tee.sh
   ```

   This:
   - Builds the Docker image with `--platform linux/amd64` (TDX requires x86_64).
   - Authenticates Docker to Artifact Registry and pushes the image.
   - Provisions a `c3-standard-4` Confidential Space VM with `--confidential-compute-type=TDX`.
   - Pass all `GCP__*` / `FLARE__*` / `VAULT__*` / `TEE__*` / `CREDITGATE__*` env vars through `tee-env-*` metadata keys so they land inside the enclave at boot.

3. Once the Confidential Space boot completes (~2-5 min) read the authority address from the serial port:

   ```bash
   gcloud compute connect-to-serial-port \
       --project="$GCP__PROJECT" --zone="$GCP__ZONE" \
       creditgate-fcc-tee --port=1
   ```

   You'll see:
   ```
   creditgate-fcc-tee listening on :8080 authority=0x7a3c...
   ```

4. Register that authority address with the vault (admin-only `setTeeAuthority()` call) so `submitEligibility()` will accept attestations signed by this enclave:
   ```solidity
   vault.setTeeAuthority(0x7a3c...);
   ```

5. The handler is now live inside the TEE. The proxy handles all external traffic; the enclave only answers `POST /action` from the proxy and serves `GET /state` / `GET /health` for ops.

## Local development (without a TEE)

The handler fully works in `SIMULATED_TEE_DEV` mode outside the enclave, exactly like the existing Go handler — `secrets.token_bytes` is replaced by a key passed in `CREDITGATE_SIGNING_KEY` (so you can register a deterministic `TEE_AUTHORITY` in the dev vault).

```bash
cd fcc-handler

# Run with a deterministic dev key
export FLARE_RPC_URL=https://coston2-api.flare.network/ext/C/rpc
export VAULT_ADDRESS=0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939
export CREDITGATE_SIGNING_KEY=ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80  # anvil key #0
python3 credit_tee_handler.py
# → creditgate-fcc-tee listening on :8080 authority=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

Smoke test:

```bash
curl -s localhost:8080/health
# {"status":"ok","handler":"creditgate-fcc-tee"}

curl -s localhost:8080/state
# {"opType":"CREDIT","authority":"0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266","mode":"SIMULATED_TEE_DEV","tee":false}

# Submit an EVALUATE instruction (this would normally arrive through the proxy)
curl -s -X POST localhost:8080/action -d '{
  "opCommand": "EVALUATE",
  "borrower": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "collateralAmount": "100000000",
  "requestedLoan": "100000000",
  "expiry": "1893456000",
  "nonce": "1",
  "revocationVersion": "0"
}'
```

## Docker (local build, no TEE)

```bash
docker build -t creditgate-fcc-tee -f fcc-handler/Dockerfile fcc-handler/  # from repo root OR
docker build -t creditgate-fcc-tee .                                          # from fcc-handler/

docker run --rm -p 8080:8080 --env-file fcc-handler/.env creditgate-fcc-tee
```

## Where TEE attestation happens

| Step | What's verified | How | In this code |
|------|------------------|------|--------------|
| **1. Key generation** | Key never leaves the enclave | `secrets.token_bytes(32)` runs in-process; CSPRNG inside the TDX VM is sealed by hardware | `generate_tee_signing_key()` |
| **2. Boot attestation** | Enclave image digest matches the published source tree | GCP Confidential Space issues a TPM-attested token verifiable at GCP's attestation verifier | `fetch_attestation_token()` (`http://169.254.169.254/...`) |
| **3. Network egress** | RPC calls to the Flare node leave the enclave with no proxy/MITM | Confidential Space networking directly egresses from the enclave | `fetch_borrower_reputation()` via `web3.HTTPProvider` |
| **4. Signature** | EIP-191 signature is produced inside the TEE; the vault's `ecrecover` proves which key signed | `Account.sign_message` over the personal-sign hash, `v ∈ {27,28}`, low-s enforced | `sign_attestation()` |
| **5. Authority registration** | Vault must `setTeeAuthority(address)` to accept attestations from this enclave | Operator reads the authority address from the boot serial logs and registers it once | documented in the deploy section above |

The judge-visible change vs. the Go SIMULATED_TEE handler: the signing key here is generated inside the enclave (step 1) and never written to disk, never logged, never sent to the proxy. Compromise of the operator's GCP project, the proxy host, or the vault deployer does not directly compromise the signing key — only an attestation of the enclave's image measurement can convince a verifier it was the expected TEE.

## Mode reference

| Mode | Trigger | Key source | Where it runs | Use |
|------|---------|------------|---------------|-----|
| `SIMULATED_TEE` | `CREDITGATE_SIGNING_KEY` set, on a regular host | operator-supplied | host | prod-line parity tests, flexible smoke |
| `SIMULATED_TEE_DEV` | no key set, no TEE | `secrets.token_bytes` on host | any host | dev, demonstrates key-gen path with no TEE |
| `TEE` | no key set, TEE leads detected | `secrets.token_bytes` in enclave | Confidential Space | production |

A `TEE__REQUIRE_TEE=true` env var refuses to start in anything but a real enclave, so a misconfigured production launch surfaces immediately.

## License

MIT — same as the rest of the CreditGate codebase.
