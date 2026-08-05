# Frontend Review — 2026-08-05

## Verdict: FAIL (shippable to demo-ready in ~2–3 focused hours; contract-facing wiring is sound, lifecycle coverage is not)

Reviewed 7 files in `/root/flare-hackathon/creditgate/frontend` (Next.js 15 + wagmi v2 + RainbowKit) against the deployed Coston2 `CreditGateVault` lifecycle (deposit → register XRPL → request eligibility → submit attestation → draw → repay on XRPL → FDC proof → close). Contract facts cross-checked against `src/CreditGateVault.sol` and `src/CreditGateTypes.sol`.

**Bottom line:** The plumbing that exists is correct (ABI strings, 6-decimal formatting, chain config, Loan struct destructuring, state map all match the contract). What's missing is the middle of the demo: the UI cannot register an XRPL address, cannot show an eligibility result, cannot submit a repayment proof, and the "draw loan" button sends no value and no USDT0 allowance approval — so a judge walking in cold cannot complete the lifecycle, and the draw step would revert on-chain.

---

## What works

1. **ABI is complete and correct** — `src/lib/abi.ts` includes every function the UI calls **plus** the recently added `registerXRPLAddress(bytes32)` (abi.ts:20), `submitEligibility` with the full 8-field attestation tuple (abi.ts:23), `submitRepaymentProof` with the full FDC proof tuple (abi.ts:25), `liquidate` (abi.ts:26), and all events. Function signatures match the Solidity source verbatim. Note: `liquidate` and `submitEligibility` are in the ABI but never called by any page.
2. **6-decimal formatting is correct everywhere it appears** — `parseUnits(x, 6)` on deposit (app/page.tsx:46) and draw (app/page.tsx:65); `formatUnits(..., 6)` for FXRP collateral (app/page.tsx:212) and USDT0 loan (app/page.tsx:216). FXRP/USDT0 are 6-decimal ERC-20s; no 18-decimal bugs.
3. **Chain config is correct** — Coston2 `chainId: 114`, RPC `https://coston2-api.flare.network/ext/C/rpc`, explorer `https://coston2-explorer.flare.network` (contract.ts:3–5); wagmi chain overrides `flareTestnet` id to 114 and names it "Flare Coston2" (providers.tsx:20–36). Token addresses match Coston2 deployments (contract.ts:8–10).
4. **Loan struct destructuring matches the contract** — `[borrower, collateralAmount, loanAmount, requiredRepaymentDrops, deadline, eligibilityExpiry, eligibilityNonce, expectedCommitment, state]` (app/page.tsx:193) matches the 10-field `Loan` struct order in CreditGateTypes.sol:41–52 (index 8 = state; the UI reads `state` correctly — but see issue 4, the return-tuple field count differs).
5. **State enum map is correct** — `LOAN_STATES` 0–8 (contract.ts:14–24) matches `LoanState` in CreditGateTypes.sol:27 (IDLE→DEFAULTED). Colors for states 1/3/4/6 are styled (app/page.tsx:222–231); every other state falls to gray, which is fine but makes PENDING/DEFAULTED/REJECTED look identical.
6. **`getBorrowerLoanIds` per-wallet loan list** with a per-loan `LoanCard` read of `getLoan` (app/page.tsx:26–32, 184–189) is the right read pattern.
7. **Transparency dashboard** shows live vault status (`owner`, `paused`, `collateralRatioBps`, `nextLoanId`) with explorer deep links (transparency/page.tsx:11–33, 40–47), plus honest evidence-mode labeling (LIVE Coston2 / SIMULATED TEE / LIVE XRPL TESTNET / SIMULATED FDC FIXTURE — transparency/page.tsx:86–107). Good judge-facing honesty.

---

## What's missing / broken (with refs)

1. **`registerXRPLAddress` exists in the ABI but has no UI** — no input for the borrower's XRPL r-address, no keccak256(bytes(...)) hashing, no write hook. The contract *requires* the binding before draw (`registerXRPLAddress` reverts on zero hash, CreditGateVault.sol:128–131; drawLoan checks the binding). A judge following the landing page's "Repay on XRPL" story can never get there. This is the single biggest demo gap.
2. **No eligibility result surface at all** — the UI can call `requestEligibility` (app/page.tsx:50–57) but has no button/hook for `submitEligibility` (TEE/FCC side), so the loan can never leave `ELIGIBILITY_PENDING`(2) → `ELIGIBLE`(3) from the browser. `submitEligibility` is in the ABI (abi.ts:23) but uncalled. For a hackathon this is defensible if the FCC bot submits off-chain — but nothing in the UI explains that or polls for state change.
3. **`drawLoan` is called without `value` and without USDT0 approval** — `drawLoan` is `payable` (CreditGateVault.sol:264–266) and forwards `msg.value` to the FTSO price query; on Coston2 the fee is currently zero, so `value: 0` usually works *today*, but the call passes no `value` field at all (app/page.tsx:61–66) and there is **no `usdt0.approve(vault, amount)` step** anywhere. USDT0 is an ERC-20 — the draw will revert with an allowance error on first use. This is a guaranteed on-chain failure in front of a judge.
4. **`getLoan` return-tuple mismatch** — abi.ts:14 declares a 10-field tuple for `getLoan`, but the UI destructures only 9 values (app/page.tsx:193). viem returns all 10 fields; the destructure silently drops `borrowerSourceAddressHash` (index 9). Not a crash (field order is right), but the extra field is never surfaced — and a `borrowerSourceAddressHash` display would be exactly the judge-facing proof that the XRPL binding exists.
5. **No repayment path** — no hook for `submitRepaymentProof` (abi.ts:25, uncalled), no UI for the XRPL repayment amount (drops) or memo commitment, no FDC proof submission, no way to reach `CLOSED`(6) from the browser. The landing page promises "FDC verifies repayment, releases collateral" (page.tsx:47); the app page cannot demonstrate it. `liquidate` also uncalled.
6. **No USDT0/FXRP faucet or balance display** — no token balance reads, no "get test tokens" link, no USD value of collateral. On Coston2 a judge needs FXRP to deposit; the UI gives no guidance.
7. **`NEXT_PUBLIC_VAULT_ADDRESS` defaults to `0x000...0`** (contract.ts:7) — if the env var is unset, every read returns zeros/garbage and every write targets the null address. There's no `.env.example` in the frontend dir and no build-time guard. The vault is the *only* configured address that's env-driven; the other three are hardcoded. (Deploy script exists at `script/DeployCreditGate.s.sol`.)
8. **Landing page flow omits the XRPL-registration step** — "Deposit → FCC Evaluates → Draw → Repay" (page.tsx:43–47) skips "Register XRPL address," which the contract mandates. Marketing copy and contract behavior diverge.
9. **Minor TypeScript/UX nits**:
   - `state === 1` etc. compares a `number`/`bigint`-typed value against number literals (app/page.tsx:223–231) — compiles under `as const` ABI but is fragile; no `typeof` guard.
   - Loan card only shows withdraw for state 1 (app/page.tsx:238) — states 2/3/4/5 render no action buttons at all.
   - "Total Loans" counts `nextLoanId - 1` (transparency/page.tsx:70), which counts *created* slots, not active loans — fine but mislabeled.
   - No error display on any write hook (`writeContract` error is silently swallowed everywhere; wagmi returns it in the hook, it's never rendered) — a revert looks like a silent no-op to a judge.
   - No transaction hash → explorer link after any write; no `waitForTransactionReceipt`.
   - `collateralRatioBps` rendered as `Number(x)/100` % (transparency/page.tsx:64) — correct for bps→%, but a plain `Number()` on a bigint from a view returning `uint256` is a precision risk only at extreme values; fine here.
   - No loading/error states on any `useReadContract` (no `isLoading`, no `isError`).

---

## Recommended fixes (numbered, concrete)

1. **Add an XRPL registration panel (highest priority, ~45 min):** input for the r-address + "Register" button calling `registerXRPLAddress`, hashing client-side with `keccak256(stringToHex(addr))` from viem; then read `borrowerXRPLAddressHash(address)` (abi.ts:16) and show "✓ XRPL address bound: r…" on the loan card. This unlocks the demo's headline.
2. **Add USDT0 approval before draw (~15 min):** on the Loan panel, `useWriteContract` → `usdt0.approve(vault, parseUnits(loanAmount, 6))` (or a max allowance), gated on a read of `usdt0.allowance(address, vault)`; pass `value: 0` explicitly to `drawLoan` (keep `payable` signature in ABI).
3. **Render the eligibility status path (~30 min):** when state is 2 (`ELIGIBILITY_PENDING`), show "Waiting for FCC attestation…" with a refresh/poll (`refetchInterval`); when 3 (`ELIGIBLE`), show the limit (from the attestation/loan) and enable Draw. Optionally add an owner-only "Submit Eligibility" debug button calling `submitEligibility` with the tuple — great for the demo narrative.
4. **Fix the `getLoan` destructure** (5 min): add `borrowerSourceAddressHash` as the 10th element and display it (first 6 + last 4 hex) as judge-facing proof of the XRPL binding. Update abi.ts tuple to keep 10 fields (it's already correct — only the destructure needs the extra var).
5. **Add repayment UX (~45 min):** when state 4 (`FUNDED`), show `requiredRepaymentDrops` (XRP drops) and the memo commitment (`expectedCommitment`), a "Repay on XRPL" CTA explaining the XRPL-side payment, and a "Submit FDC proof" button calling `submitRepaymentProof` (JSON-paste the proof tuple or a fixture loader) → `CLOSED` + collateral released. This completes the lifecycle for the demo.
6. **Add token balance + faucet helper (~20 min):** read `fxrp.balanceOf(address)` / `usdt0.balanceOf(address)` on the app page with 6-decimal formatting; link to the Coston2 faucet (or the repo's mint script) when balance is 0.
7. **Guard the vault address (~10 min):** in `contract.ts` or providers, throw/console.error if `NEXT_PUBLIC_VAULT_ADDRESS` is unset or `0x000...0`; commit a `.env.example` with the deployed address.
8. **Surface errors + tx hashes (~20 min):** render `error?.shortMessage` under each action button and show the tx hash with an explorer link after each write (the explorer URL already exists in config).
9. **Copy fix (5 min):** add the "Register XRPL address" step to the landing page 4-step flow (page.tsx:43–47) to match the contract.

After fixes: `npm run build` + a live Coston2 walkthrough (deposit → register → request → submit eligibility → draw → repay-proof → close) is the acceptance test.

---

## Judge-facing evidence value

- **Good:** transparency page (live vault stats + explorer links + honest SIMULATED/LIVE labels), correct state enum rendering, correct 6-decimal math, correct Coston2 chain config, complete ABI.
- **Bad:** the interactive app currently proves only "deposit → withdraw." The credit story (TEE eligibility, XRPL repayment, FDC proof) is *described* on the landing/transparency pages but **not demonstrable** in the UI. A judge cannot complete the lifecycle without reading the contract source and calling `cast`/script, and the draw step would revert for lack of allowance. Fixes 1–5 above are exactly what turns this from "contract demo" into "product demo."
