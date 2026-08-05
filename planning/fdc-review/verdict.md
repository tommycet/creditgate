# FDC Script Review — 2026-08-05

Files reviewed:
- `script/fdcExample/Base.s.sol` (64 lines)
- `script/fdcExample/XRPPayment.s.sol` (70 lines)
- `lib/flare-foundry-periphery-package/src/coston2/IXRPPayment.sol` (129 lines, Flare's own interface)
- Cross-checked: `IFdcHub.sol`, `IFdcVerification.sol`, `ContractRegistry.sol` (same package), `src/CreditGateVault.sol:333-383`, `foundry.toml:10-11`

## Verdict: PASS-WITH-NOTES

The two scripts correctly encode the FDC request format and address the right contracts with the right interfaces, and the proof shape they target is exactly what `CreditGateVault.submitRepaymentProof()` consumes. They are NOT, however, the official 5-stage Foundry flow — they are a compact single-contract demonstration that stops after submission and only *documents* (via `console.log`) the retrieve/verify stages. End-to-end runnability against Coston2 requires the off-chain pieces the official guide provides (verifier API, DA-layer proof fetch, `data/` file handoff) which these scripts do not implement.

## What works

1. **Correct `attestationType` encoding** — `bytes32("XRPPayment")` (Base.s.sol:27) is the UTF8-hex of the attestation type name, left-zero-padded to 32 bytes, exactly per the official spec. (Official guide example for "Payment": `0x4164647265737356616c696469747900...00`.)
2. **Correct `sourceId` handling** — `bytes32("testXRP")` for testnet / `bytes32("XRP")` for mainnet (Base.s.sol:29-31, selected at :52). "testXRP" is the XRPL test chain ID used in the official guide (sourceName `"testXRP"`).
3. **Correct request body** — `IXRPPayment.RequestBody{transactionId, proofOwner}` matches the package interface exactly (Base.s.sol:45-48 vs IXRPPayment.sol:82-85). Note: XRPPayment's body has no `inUtxo`/`utxo` fields — those belong to the generic `Payment` type used in the official guide's demo; XRPPayment is the correct type for a native-XRP payment.
4. **Correct submission call** — `fdcHub.requestAttestation{value: 0}(abi.encode(request))` (Base.s.sol:58) matches `IFdcHub.requestAttestation(bytes) payable` (IFdcHub.sol:32).
5. **Coston2 addresses are correct** — `FDC_HUB = 0x48aC463d7975828989331F4De43341627b9c5f1D` (Base.s.sol:23) and `FDC_VERIFICATION = 0x906507E0B64bcD494Db73bd0459d1C667e14B933` (XRPPayment.s.sol:21) match the Flare FDC guide's Coston2 deployments and the package's `ContractRegistry` lookup names (`getFdcHub`/`getFdcVerification`, ContractRegistry.sol:538-562). Hard-coding is safe here because these registries return exactly these addresses.
6. **Verification entry point is right** — `verifyProof` calls `IFdcVerification.verifyXRPPayment(proof)` (XRPPayment.s.sol:51-53), the correct FDC API for this attestation type.
7. **Proof shape matches the vault** — `IXRPPayment.Proof` (`merkleProof[] + Response`) is the same struct consumed by `CreditGateVault.submitRepaymentProof` (CreditGateVault.sol:333, 350). A proof fetched per the official retrieve stage would decode straight into it.

## What's missing

1. **No request-fee handling** — official flow reads `FdcRequestFeeConfigurations.getRequestFee(abiEncodedRequest)` and sends `{value: requestFee}`. Base.s.sol:58 sends `value: 0`; a fee is currently required on Coston2, so the submission tx will revert.
2. **No verifier prepare stage** — the official flow POSTs the request JSON to `https://fdc-verifiers-testnet.flare.network/verifier/xrp/Payment/prepareRequest` with `X-API-KEY` to get the validated, ABI-encoded request. This script builds the ABI encoding directly (fine) but never validates it off-chain and needs `--ffi`/surl to do so.
3. **No retrieve stage** — the proof must be fetched from the DA layer (`https://coston2-da-layer.flare.network/api/v1/fdc/proof-by-request-round-raw` with `{votingRoundId, requestBytes}`) after the voting round finalizes (≤180s). XRPPayment.s.sol:36-41 only *prints* the endpoint — nothing calls it.
4. **No voting-round capture** — `IFdcHub.requestAttestation` doesn't return the round; the official flow reads `FlareSystemsManager.getCurrentVotingEpochId()` and persists it to `data/`. Without it, the DA-layer fetch has nothing to query on.
5. **No file-based handoff** — the official flow persists request/proof/round to `data/*.txt` between stages. Here everything is in-memory; `run()` ends at the submit (XRPPayment.s.sol:33) and `verifyProof` requires a hand-supplied `calldata` proof, so a judge must paste ABI-encoded proof bytes manually.
6. **`run()` never calls the verify stage** — the 5-stage flow is a fragment: submit is executed, wait/retrieve are only logged (XRPPayment.s.sol:36-46), and `verifyProof` is a separate function the caller must invoke by hand.
7. **`messageIntegrityCode` is zero** (Base.s.sol:53) — accepted by FDC but weakens the request and is flagged in the official docs; the official flow derives it from the prepared request.

## Recommended fixes (numbered, concrete)

1. **Pay the request fee**: in `_requestXRPPaymentAttestation`, read `IFdcRequestFeeConfigurations(ContractRegistry.getFdcRequestFeeConfigurations())` and pass `{value: fee}` (via `ContractRegistry` from the periphery package, or hard-code the Coston2 `FdcRequestFeeConfigurations` address).
2. **Add a Prepare stage** that mirrors the official guide: POST the request JSON (`attestationType`/`sourceId`/`requestBody` as UTF8-hex strings) to the verifier at `https://fdc-verifiers-testnet.flare.network/verifier/xrp/Payment/prepareRequest` with `X-API-KEY`, and decode `abiEncodedRequest` instead of building the encoding manually.
3. **Capture and persist the voting round** after submission: read `IFlareSystemsManager.getCurrentVotingEpochId()` and write `data/XRPPayment_votingRoundId.txt` alongside the ABI-encoded request (`Base.writeToFile`).
4. **Add a Retrieve stage** that waits (the guide uses `vm.sleep` up to ~180s) then POSTs `{votingRoundId, requestBytes}` to the DA layer and decodes `ParsableProof{attestationType, proofs, responseHex}` into `IXRPPayment.Proof`, saving it to `data/XRPPayment_proof.txt`.
5. **Wire `run()` end-to-end**: submit → wait → retrieve → `fdcVerification.verifyXRPPayment(proof)` in one script, so a judge runs a single `forge script` command with `--broadcast --ffi` and sees the verified proof (this is what makes the official demo judge-runnable).
6. **Set `messageIntegrityCode`** from the prepared request's expected response (or document why it stays zero).
7. **Demonstrate the vault path**: add an `Interact` stage that calls `CreditGateVault.submitRepaymentProof(loanId, proof)` with the fetched proof so the judge sees loan closure, not just a `bool proved`.

## Judge-facing evidence value

- **Strong:** correct `bytes32` encodings, correct Coston2 addresses, correct interface usage — a Flare judge will see the FDC request format is right, and the proof struct is byte-compatible with the vault's `submitRepaymentProof`.
- **Weak:** as-is, a judge cannot run this end-to-end. `requestAttestation{value: 0}` will revert on the fee, and the proof-fetch (the actual hard part of FDC) is console text, not code. The live demo must be the **test suite** (`test/CreditGateVault.fdc-fixture.t.sol`, which drives the vault with a real FDC proof) or a fixed script implementing fixes 1-5.
- **Bottom line for judges:** the scripts prove *understanding* of the FDC flow and correct integration of the periphery package; they do not yet prove an end-to-end Coston2 run. Fix 1 (fee) + a working Retrieve stage is the minimum for a live demo.
