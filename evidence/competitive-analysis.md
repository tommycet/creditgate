# Competitive Analysis — CreditGate — Flare Summer Signal (Bounty 2: Confidential Compute Apps)

**Date:** 2026-08-05 · **Source:** `planning/competitive-positioning/verdict.md` (DoraHacks BUIDL extractions + web_search `site:dorahacks.io/buidl`)

---

## Competitor comparison table

| Dimension | **CreditGate** (ours) | **AegisFlow** | **FlareShield AI** | **Axi** |
|---|---|---|---|---|
| **DoraHacks BUIDL** | (in submission) | 47176 | (~Aug 3) | 47185 |
| **One-liner** | Confidential credit vault: collateralized USDT0 loans against FXRP, eligibility attested in a TEE then verifiably repaid cross-chain via FDC. | Private, enforced sanctions screening for XRP on Flare — TEE-secured, verified by 100+ nodes, ERC-3643 compliant. | Confidential AI asset management & yield engine on Flare. Autonomous privacy-preserving yield optimization. | Intent-based architecture + NOX encryption + batch execution. Confidential intent-based dark pool. |
| **FAssets / FXRP** | ✅ Load-bearing (FXRP collateral) | ✅ (XRP gating) | ❌ | ❌ |
| **FTSOv2** | ✅ Load-bearing (XRP/USD feed drives collateral ratio) | ❌ (not mentioned) | ✅ (author FTSO specialist) | ❌ |
| **FCC / TEE** | ✅ Load-bearing (Go FCC handler, EIP-191 eligibility attestation) | ✅ (FCC) | ✅ (FCC/TEE implied) | ⚠️ TEE but **NOX Protocol / Intel SGX**, NOT Flare FCC |
| **FDC** | ✅ Load-bearing (cross-chain XRPL repayment verification) | ✅ (100+ providers verify verdict) | ❌ | ❌ |
| **# Flare primitives (load-bearing)** | **4 of 4** | 2 of 4 (FCC + FDC) | 1–2 of 4 (FCC + FTSO, no FDC) | 0 of 4 (non-Flare TEE) |
| **Cross-stack proof** | Go EIP-191 sig accepted by Solidity `ecrecover` (verified by 2 cross-lang tests) | Not surfaced | Not surfaced | Not surfaced |
| **Tests** | **91 tests, 7 suites, 0 failures, 97.75% line coverage** | No test claims on public BUIDL | Prose BUIDL, no tests | Not surfaced |
| **Threat to CreditGate** | — | **HIGH** — direct Bounty 2 overlap, sharper institutional narrative (ERC-3643) | **MEDIUM** — different problem (yield), AI framing rides the hackathon's "AI" tag | **LOW-MED** — neighboring-TEE but not Flare FCC |

---

## CreditGate's defensible advantages

1. **Only submission using all 4 Flare primitives.** FAssets + FTSOv2 + FCC + FDC are each ✅ load-bearing. AegisFlow uses FCC+FDC (no FTSO). FlareShield AI uses FCC+FTSO (no FDC, no cross-chain asset). Axi uses a non-Flare TEE. On the official "Flare integration quality" criterion this is a top-of-class claim — CreditGate is the only discovered submission binding FCC (private eligibility) to FDC (public cross-chain verification) in a single product flow.

2. **Cross-language engineering evidence.** The 2 Go-TEE cross-compatibility tests prove the Go FCC handler's EIP-191 signature is accepted by Solidity `ecrecover` (`test/CreditGateVault.go-tee-compat.t.sol`). No competitor publishes anything comparable — the most directly inspectable answer to the "architecture credible and understandable" half of Technical execution.

3. **Test depth.** 91 tests across 7 suites (62 unit + 4 FDC fixture + 5 invariant/fuzz @ 256 runs each + 2 Go-TEE compat + 1 real malicious-token reentrancy + 2 reentrancy/FTSO edge + 15 edge cases), 97.75% line coverage on `CreditGateVault.sol`, 100% function coverage. Neither AegisFlow nor FlareShield AI surface any test claims — our test volume is the deepest **verifiable** engineering evidence among named competitors and is reconstructible by any judge via `forge test`.

4. **Cross-chain repayment-substitution defense.** Per-loan XRPL address snapshot + 32-byte domain-separated MemoData commitment binding is a concrete security primitive no competitor describes — rewards the "Evidence of new work" criterion.

---

## Known gaps vs competitors

1. **AegisFlow's narrative is sharper** (3-paragraph user-pain story; ERC-3643 compliance anchor).
2. **FDC is a fixture, not live** — AegisFlow claims "verified by 100+ nodes"; our fixture-only step is the most exposed primitive-vs-competitor gap.
3. **Deployed address placeholder** — README still shows `<DEPLOYED_ADDRESS>` (even field with AegisFlow, but unproven is where a deploy tips the score).

---

## Reproduce

The test counts and coverage above are reconstructible by any judge:

```bash
cd /root/flare-hackathon/creditgate
forge test                  # 91 tests, 7 suites, 0 failures
forge test --summary        # per-suite breakdown
forge coverage              # 97.75% lines / 100% functions on CreditGateVault.sol
```

See `evidence/test-summary.md` for the full per-suite breakdown and `planning/competitive-positioning/verdict.md` for the methodology behind the competitor BUIDL extractions.
