# Gap 07: FDC Integration — Real or Mocked?

## Verdict: Partially real, partially mocked. The submit stage is live; the retrieve stage is broken on Coston2 testnet.

---

## 1. What's real on-chain (judges CAN verify)

| Artifact | Evidence | Verifiable? |
|----------|----------|-------------|
| Real XRPL testnet payment | TX `0xb9f346a3…4720`, ledger 19689886, `tesSUCCESS`, 1M drops | ✅ [XRPL livenet explorer](https://livenet.xrpl.org/transactions/0xb9f346a3f25581fbb561842bf5d3c5c91b9909cf00d13dec7e7939b5c6347420) |
| FDC attestation submitted on Coston2 | TX `0x7fd6c89d…4a42`, block 33712406, status=1 | ✅ `cast receipt` against Coston2 RPC |
| Voting round finalized | Round `1417946` — `isFinalized(200, 1417946) = true` | ✅ On-chain read via `IRelay` |
| Evidence JSON | `evidence/xrpl/real-payment.json` — real XRPL tx hash, sender/receiver addresses, amount | ✅ Cross-referenced against XRPL explorer |
| FDC verifier contract live | `0x906507E0B64bcD494Db73bd0459d1C667e14B933` with code | ✅ Coston2 explorer, ContractRegistry verified |

**Bottom line:** The "submit attestation to FdcHub" step is provably live. The XRPL payment is real. The round was finalized on-chain. This is not fabricated.

---

## 2. What's mocked (tests do NOT prove end-to-end FDC)

### The FDC fixture test uses `MockFdcVerification`

File: `test/CreditGateVault.fdc-fixture.t.sol`

```solidity
MockFdcVerification public fdc;  // ← simple mock
// ...
fdc.setResult(true);             // ← hardcoded return value
```

`MockFdcVerification.sol`:
```solidity
contract MockFdcVerification is IXRPPaymentVerification {
    bool private _result;
    function setResult(bool result_) external { _result = result_; }
    function verifyXRPPayment(...) external view returns (bool) {
        return _result;  // ← returns whatever was set
    }
}
```

This is a **test double** — it always returns `true` when configured. The tests prove:
- ✅ The vault's `submitRepaymentProof` logic works (checks status, amount, memo, address hash, anti-replay)
- ✅ The `IXRPPayment.Proof` struct encoding is correct
- ❌ **NOT** that a real FDC attestation can be retrieved and verified end-to-end

The test suite description (line 19 of the test) says: *"This uses the same MockFdcVerification pattern as unit tests but with realistic XRPL-style values"* — honest, but the test suite table (line 378) says *"Realistic XRPL-payment proof verified end-to-end via MockFdcVerification"* which is misleading. It's verified via a mock, not end-to-end.

---

## 3. The honest documentation

The README documents this limitation in the "FDC Integration" section:

> **Step 3: Proof Retrieval — Coston2 DA Layer limitation ⚠️**
> 
> Voting round `1417946` is finalized on-chain (`isFinalized(200, 1417946) = true`). However, the DA Layer API (`ctn2-data-availability.flare.network`) returns HTTP 400: `{"error":"attestation request not found"}` for all rounds — the FDC attestation providers on Coston2 did not index the `testXRP` source attestation in their DA Layer.
> 
> **This is a Coston2 testnet infrastructure limitation, not a bug in CreditGate's code.**

This is **honest and correctly framed** — it's not buried in a footnote, it's in its own subsection. The README labels this as "INFRA-LIMITED" in the evidence modes table.

---

## 4. The critical gap: "submitted" vs "proved end-to-end"

| Stage | Status | What judges can verify |
|-------|--------|----------------------|
| 1. XRPL payment sent | ✅ Real | TX hash on XRPL livenet explorer |
| 2. Attestation submitted to FdcHub | ✅ Real | Coston2 TX, status=1, AttestationRequest event |
| 3. Voting round finalized | ✅ Real | `isFinalized()` on-chain read |
| 4. Proof retrieved from DA Layer | ❌ **Blocked** | HTTP 400 from DA Layer API |
| 5. `verifyXRPPayment(proof)` called on FdcVerification | ❌ **Never happened** | Cannot call without proof bytes |
| 6. Vault `submitRepaymentProof` processes real proof | ❌ **Never happened** | Only tested with mock |

**The gap is steps 4–6.** The vault's on-chain FDC verification path (`submitRepaymentProof → FdcVerification.verifyXRPPayment`) has never been exercised with a real proof on Coston2. It's been tested only with mock data.

---

## 5. What the test suite actually proves about FDC

The 4 FDC fixture tests prove:
1. **Vault logic is correct** — given a valid proof, the vault correctly checks status, amount, memo, address hash, and anti-replay
2. **Proof struct encoding matches** — the `IXRPPayment.Proof` struct the vault expects matches the Flare interface
3. **Loan lifecycle works** — deposit → eligibility → draw → FDC proof → close → collateral release

What they do **NOT** prove:
1. That a real FDC proof can be retrieved from the DA Layer on Coston2
2. That `FdcVerification.verifyXRPPayment()` accepts a real proof
3. That the full cross-chain flow works end-to-end on live infrastructure

---

## 6. Can judges verify this on-chain?

**Yes, partially:**
- ✅ The XRPL payment is real and verifiable on XRPL livenet
- ✅ The FDC attestation submission is real and verifiable on Coston2
- ✅ The voting round finalization is real and verifiable on-chain
- ❌ The proof retrieval step is broken (DA Layer doesn't index testXRP)
- ❌ The end-to-end `verifyXRPPayment → vault submission` has never run on-chain with a real proof

**A judge could:**
1. Open the XRPL explorer link and confirm the payment exists
2. Open the Coston2 explorer link and confirm the attestation was submitted
3. Call `isFinalized(200, 1417946)` and confirm it returns true
4. Try to retrieve the proof and hit the same HTTP 400 error
5. Run `forge test` and see 191 tests pass (including 4 FDC fixture tests with mocks)

**A judge could NOT:**
1. Retrieve a real proof from the DA Layer
2. Call `FdcVerification.verifyXRPPayment()` with a real proof
3. See `submitRepaymentProof` work with real FDC data on Coston2

---

## 7. Risk assessment

| Risk | Severity | Mitigation in README |
|------|----------|---------------------|
| FDC proof retrieval broken on Coston2 | **HIGH** | Honestly documented as "INFRA-LIMITED" |
| Tests use mock FDC, not real proofs | **MEDIUM** | Test file says "MockFdcVerification" in name |
| Jury might expect live FDC verification | **MEDIUM** | README says "fixture proof, live verifier ABI" |
| No on-chain proof of end-to-end FDC flow | **MEDIUM** | Attestation submit IS live; only retrieval is blocked |

---

## 8. Recommendations

1. **No code change needed** — the limitation is infrastructure, not code. The honest documentation is the right call.
2. **Consider adding a testnet replay note** — if Coston2 DA Layer indexing is ever fixed, the team could re-run the full flow and capture a live proof.
3. **The "fixture proof, live verifier ABI" framing is accurate** — the tests use mock data but verify against the real Flare interface types. This is a reasonable test strategy when the infrastructure is broken.
4. **The submit stage IS live proof** — judges can verify the attestation was submitted, the round was finalized, and the XRPL payment exists. That's meaningful evidence even without the retrieval step.
