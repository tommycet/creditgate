# Gap #9 — Roadmap Credibility, Team Section, Licensing

**Checked:** README.md (full 870 lines)  
**Judging criterion:** "Clarity and future potential — Does the project have a credible path beyond the hackathon?"

---

## Roadmap Assessment (lines 846-854)

The roadmap contains 7 ordered items:

1. ✅ **Hackathon scope** — honestly marked as shipped (two FCC paths, FDC demo, Coston2 deploy)
2. **Production FCC** — migrate to real TEE with key governance (rotation, revocation, multi-authority)
3. **AI credit scoring** — FCC handler ingests off-chain AI credit model in the TEE
4. **ERC-3643 compliance** — institutional compliance modules for regulated asset issuance
5. **Multi-collateral** — FBTC, FDOGE credit gates
6. **Adapter integration** — gate access to Morpho / Mystic lending markets
7. **Institutional** — lender policy engines and compliance reporting

### Strengths
- **Concrete naming**: Items 3-6 reference specific standards (ERC-3643), assets (FBTC/FDOGE), and protocols (Morpho/Mystic) — not vague hand-waves
- **Sequenced logically**: production TEE → AI scoring → compliance → multi-collateral → adapters → institutional. Each step builds on the previous
- **Honest hackathon boundary**: Item 1 explicitly labels what's done; the rest is clearly future work
- **AI framing is tasteful**: Item 3 specifically notes "aligned with hackathon's AI tag *without* bolting AI into the contract layer" — a mature product-design distinction
- **Judge-sim-v5 and v7 verdicts both confirm roadmap credibility** (internal planning docs corroborate)

### Gaps Found

| # | Gap | Severity | Detail |
|---|-----|----------|--------|
| 1 | **No timelines or milestones** | MEDIUM | All 7 items are listed without any target dates, quarter markers, or "within X months" estimates. A judge cannot tell if production FCC is 1 month or 2 years away. No milestones like "Q4 2026: production TEE on mainnet" or "6 months: ERC-3643 prototype." |
| 2 | **No testnet→mainnet migration path described** | MEDIUM | The project is deployed on Coston2 testnet. The roadmap jumps from "hackathon scope" to "production FCC" without explaining the intermediate step: testnet validation → security audit → mainnet deployment → user onboarding. The mainnet path is a critical missing link for "credible path beyond hackathon." |
| 3 | **No scaling plan for single-developer team** | LOW-MEDIUM | Roadmap items 4-7 (ERC-3643, multi-collateral, Morpho adapters, institutional) are substantial features requiring domain expertise (compliance, multi-chain, DeFi integrations). A single developer cannot deliver all of these. The roadmap doesn't acknowledge this constraint or propose how to scale (grant funding, team hires, partnerships). |
| 4 | **AI credit scoring has no approach detail** | LOW | Item 3 says "FCC handler ingests an off-chain AI credit-scoring model" but doesn't specify: what model? How is the model deployed inside the TEE? What's the inference latency? Is it a simple score lookup or an LLM? The credit evaluation model is documented in the README (lines 219-243) but the roadmap item itself is sparse. |

---

## Team Section Assessment (lines 840-843)

The team section reads:

> **Single developer** — architecture, Solidity (CreditGateVault.sol, CreditGateTypes.sol, mocks, CreditScoreSBT), the Go FCC credit-evaluation handler + EIP-191 signer, the Python TEE handler, the Next.js + wagmi + RainbowKit frontend, the Foundry test suite (191 tests / 19 suites / 97.75% coverage), deployment scripts, and six planning review verdicts.

### Strengths
- **Honest**: explicitly discloses it's a single developer
- **Credible breadth**: the list of what was built (Solidity, Go, Python, Next.js, Foundry tests, deployment scripts, planning docs) is impressive for one person and verifiable in the repo

### Gaps Found

| # | Gap | Severity | Detail |
|---|-----|----------|--------|
| 5 | **No developer identity or credentials** | MEDIUM | The team section doesn't name the developer, provide a GitHub handle, link to past work, or describe relevant experience. Judges want to know *who* built this and *whether they can deliver the roadmap*. The README links to `https://github.com/tommycet/creditgate` but the section itself has no personal identity. |
| 6 | **No mention of advisors, contributors, or collaborators** | LOW | Even if it's a solo project, mentioning any advisors, reviewers, or community contributors would strengthen the "can they deliver" signal. The planning docs reference multiple review rounds (security-audit, gas-audit, frontend-review, judge-sims, competitive-positioning, fdc-review) — the people behind those reviews are not credited. |

---

## License Assessment (lines 868-870)

```
## License
MIT
```

### Result: ✅ PASS
- MIT license is stated in the README
- Hackathon requirement (MIT) is met
- No LICENSE file exists at repo root (minor — the README declaration is sufficient for submission)

---

## Summary of All Gaps

| Severity | Count | Items |
|----------|-------|-------|
| MEDIUM | 3 | No timelines (#1), no testnet→mainnet path (#2), no developer identity (#5) |
| LOW-MEDIUM | 1 | No scaling plan for solo developer (#3) |
| LOW | 2 | AI credit scoring sparse on approach (#4), no advisor credits (#6) |

## Priority Recommendations

1. **Add timelines to roadmap** — Even rough ones: "Production FCC: Q4 2026", "Mainnet: Q1 2027" dramatically increase credibility
2. **Add a testnet→mainnet migration step** — Between items 1 and 2, describe: security audit → mainnet deployment → pilot users
3. **Add developer identity** — Name + GitHub profile + relevant experience (even one line: "Solidity dev with X years, former Y") makes the solo-developer disclosure feel like a strength, not a weakness
