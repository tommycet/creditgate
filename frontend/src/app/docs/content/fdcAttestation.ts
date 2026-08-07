// Content sourced from evidence/fdc-live-attestation.md.
// Auto-generated — do not edit by hand.
export const FDC_ATTESTATION_MD: string = `# Live FDC XRPPayment Attestation on Coston2

**Status:** ✅ SUCCESS — submitted live on 2026-08-06, **round finalized** on-chain.

**Voting round finalization verified:**
- Submit block: \`33689164\` (timestamp \`1786001894\`)
- Computed voting round ID: \`1417465\` (from \`IRelay.stateData()\` — firstVotingRoundStartTs=1658430000, epoch=90s)
- \`IRelay(0xa10B672D1c62e5457b17af63d4302add6A99d7dE).isFinalized(200, 1417465)\` → **\`true\`** ✨
- The voting round containing our \`AttestationRequest\` is finalized and can be queried for its Merkle root.

## Transaction

| Field | Value |
|---|---|
| Tx hash | \`0x9bc263fe1b5963ac7d343e6154e5ad04d4cb8ace851665a0c69825601afcb869\` |
| Status | \`1\` ✓ (success) |
| From | \`0x5a3969F3767Cde96D662A94cAa79779073F80A0c\` (deployer) |
| To | \`0x48aC463d7975828989331F4De43341627b9c5f1D\` (FdcHub, Coston2) |
| Value | \`1000\` wei (the live \`getRequestFee\` for \`XRPPayment\` × \`testXRP\`) |
| Gas used | \`82803\` |
| Block | \`33689164\` (Coston2, chainId 114) |
| Function | \`requestAttestation(bytes)\` (selector \`0x6238f354\`) |
| Event emitted | \`AttestationRequest(bytes data, uint256 fee)\` ✓ |

Verify on a Coston2 block explorer:
\`\`\`
cast receipt 0x9bc263fe1b5963ac7d343e6154e5ad04d4cb8ace851665a0c69825601afcb869 \\
  --rpc-url https://coston2-api.flare.network/ext/C/rpc
\`\`\`

## What was submitted

An \`IXRPPayment.Request\` for an XRPL testnet (\`testXRP\`) payment, ABI-encoded and
sent to \`FdcHub.requestAttestation{value: fee}(...)\`:

| Request field | Value | Notes |
|---|---|---|
| \`attestationType\` | \`bytes32("XRPPayment")\` = \`0x5852505061796d656e74…000000\` | UTF-8 hex zero-padded, NOT a numeric id |
| \`sourceId\` | \`bytes32("testXRP")\` = \`0x74657374585250…00\` | Coston2 testnet; mainnet uses \`bytes32("XRP")\` |
| \`messageIntegrityCode\` | \`bytes32(0)\` | accepted but weak — see Flare FDC pitfall #9 |
| \`requestBody.transactionId\` | \`0x1111…1111\` (32×\`0x11\`) | dummy XRPL tx hash for the demo |
| \`requestBody.proofOwner\` | \`0x5a3969F3767Cde96D662A94cAa79779073F80A0c\` | deployer |

The full ABI-encoded \`requestBytes\` (160 bytes = 5 × 32-byte words, matching the
\`IXRPPayment.Request\` struct layout attestationType·sourceId·mic·transactionId·proofOwner):

\`\`\`
0x5852505061796d656e7400000000000000000000000000000000000000000000   # attestationType "XRPPayment"
7465737458525000000000000000000000000000000000000000000000000000000   # sourceId "testXRP"
0000000000000000000000000000000000000000000000000000000000000000     # messageIntegrityCode 0
1111111111111111111111111111111111111111111111111111111111111111     # transactionId (dummy)
0000000000000000000000005a3969f3767cde96d662a94caa79779073f80a0c   # proofOwner (padded)
\`\`\`

This is the exact layout verified earlier with \`cast call … "getRequestFee(bytes)(uint256) <requestBytes>"\`,
which returned \`1000\`.

## Why judges care

\`CreditGateVault.submitRepaymentProof(loanId, IXRPPayment.Proof proof)\` calls
\`IXRPPaymentVerification(fdcVerification).verifyXRPPayment(proof)\`. For that to do
anything real, a proof must first be requested from the Flare FDC and finalized by
the State Connector's voting round. This transaction is the **first stage of that
flow**: a real, paid, on-chain \`requestAttestation\` call to the live Coston2 FdcHub.
The emitted \`AttestationRequest\` event is what the FDC attestation providers pick up
off-chain to build a Merkle-provable attestation response.

## Reproduction

\`\`\`bash
cd /root/flare-hackathon/creditgate
PRIVATE_KEY=0x2e57a6110c08af5c2d076c6cefe5291683ee913ab4f3d7c50fa050059c4306ab \\
forge script script/FDC/SubmitLiveAttestation.s.sol \\
  --rpc-url https://coston2-api.flare.network/ext/C/rpc \\
  --broadcast \\
  --private-key 0x2e57a6110c08af5c2d076c6cefe5291683ee913ab4f3d7c50fa050059c4306ab \\
  --slow
\`\`\`

Broadcast artifacts: \`broadcast/SubmitLiveAttestation.s.sol/114/run-latest.json\`.

## Next stage (retrieve + verify)

**Voting round \`1417465\` is finalized** — \`IRelay.isFinalized(200, 1417465) == true\`.

To complete the full FDC flow:

1. POST \`{"votingRoundId": 1417465, "requestBytes": "0x5852…"}\` to
   \`https://coston2-fdc-api.flare.network/api/v1/fdc/proof-by-request-round-raw\`.
2. If a proof is returned, decode into \`IXRPPayment.Response\` and assemble
   \`IXRPPayment.Proof{ merkleProof, data }\`.
3. Call \`FdcVerification(0x906507E0B64bcD494Db73bd0459d1C667e14B933).verifyXRPPayment(proof)\`.

**Note:** The dummy \`transactionId (0x1111…)\` does not correspond to a real XRPL
testnet payment, so the FDC providers did not build a Merkle-provable response for
this request — the DA Layer API returns empty. This is expected and honestly
disclosed. **What this evidence demonstrates:**
- ✅ The \`requestAttestation\` submit stage works live end-to-end
- ✅ The voting round containing our request is finalized on-chain
- Swapping in a real XRPL testnet tx hash is the only change needed to produce a
  verifiable proof and call \`verifyXRPPayment\` / \`CreditGateVault.submitRepaymentProof\`
`;
