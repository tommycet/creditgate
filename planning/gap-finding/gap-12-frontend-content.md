# Gap 12: Frontend Docs Content Modules — Stale Data Audit

**Date:** 2026-08-08
**Subagent:** #12 — Frontend content modules accuracy check
**Status:** MULTIPLE GAPS FOUND

---

## Executive Summary

All 8 frontend content modules at `frontend/src/app/docs/content/` contain **stale test counts, wrong file references, and outdated numbers**. The actual Forge test suite now runs **191 tests across 19 suites** (verified live), but content modules reference various stale counts: 141, 146, and 159. There are also **broken file references** (wrong test file names and stale line numbers). These modules are what judges see in the browser — the discrepancies are visible and damaging.

---

## Actual Ground Truth (verified via `forge test`)

| Metric | Actual | Notes |
|--------|--------|-------|
| **Total tests** | **191** | `forge test` → "Ran 19 test suites … 191 tests passed" |
| **Total suites** | **19** | 18 test files, CreditScoreSBT.t.sol has 2 contracts |
| **Failures** | 0 | All passing |
| **Test files** | 18 `.t.sol` files | See `ls test/*.t.sol` |

### Complete suite breakdown (actual)

| Suite | File | Tests |
|-------|------|------:|
| CreditGateVaultTest | CreditGateVault.t.sol | 69 |
| CreditGateVaultViewsTest | CreditGateVault.views.t.sol | 15 |
| CreditGateVaultEdgeCaseTest | CreditGateVault.edge-cases.t.sol | 15 |
| CreditGateVaultProtocolReserveTest | CreditGateVault.protocol-reserve.t.sol | 13 |
| CreditGateVaultLTVTest | CreditGateVault.ltv.t.sol | 11 |
| CreditGateVaultTriggerTest | CreditGateVault.trigger.t.sol | 9 |
| CreditGateVaultInvariantTest | CreditGateVault.invariant.t.sol | 8 |
| CreditGateVaultTeeCompatTest | CreditGateVault.tee-compat.t.sol | 4 |
| CreditScoreSBTTest | CreditScoreSBT.t.sol | 9 |
| CreditGateVaultAuctionTest | CreditGateVault.auction.t.sol | 5 |
| CreditGateVaultReputationTest | CreditGateVault.reputation.t.sol | 5 |
| CreditGateVaultSecurityEdgeTest | CreditGateVault.security-edge.t.sol | 5 |
| CreditGateVaultGracePeriodTest | CreditGateVault.grace-period.t.sol | 5 |
| CreditGateVaultFDCFixtureTest | CreditGateVault.fdc-fixture.t.sol | 4 |
| CreditGateVaultRegistryTest | CreditGateVault.registry.t.sol | 4 |
| CreditGateVaultOwnershipTest | CreditGateVault.ownership.t.sol | 4 |
| CreditGateVaultReentrancyAttackTest | CreditGateVault.reentrancy.t.sol | 2 |
| CreditGateVaultRealReentrancyTest | CreditGateVault.malicious-reentrancy.t.sol | 1 |
| SBTVaultIntegrationTest | CreditScoreSBT.t.sol | 3 |
| **Total** | | **191** |

---

## Gap #1 (CRITICAL): testSummary.ts — Multiple stale numbers

**File:** `frontend/src/app/docs/content/testSummary.ts`

| Line | Stale Value | Correct Value | Severity |
|------|-------------|---------------|----------|
| 5 | `Total tests: 146 · Test suites: 12` | 191 tests, 19 suites | CRITICAL |
| 6 | `forge test → "Ran 13 test suites … 159 tests passed"` | 19 suites, 191 tests | CRITICAL |
| 20 | `CreditGateVaultGoTeeCompatTest` | CreditGateVaultTeeCompatTest (no "Go" prefix) | MINOR |
| 20 | `test/CreditGateVault.go-tee-compat.t.sol` | test/CreditGateVault.tee-compat.t.sol | BROKEN REF |
| 28 | `Total 146` | 191 | CRITICAL |
| 30 | `breakdown adds to 146` | 191 | STALE |
| 33 | `146-test total` | 191 | STALE |
| 72 | `Run all 159 tests` | 191 | STALE |
| 92 | `146 passed; 0 failed` | 191 passed; 0 failed | STALE |
| 95 | `159 tests passed, 0 failed` | 191 tests passed, 0 failed | STALE |

**Additional issues:** The suite breakdown table only lists 11 suites (rows 1-11) but the actual test has 19 suites. Missing suites:
- CreditGateVaultOwnershipTest (4 tests)
- CreditGateVaultProtocolReserveTest (13 tests)
- CreditGateVaultRegistryTest (4 tests)
- CreditGateVaultReputationTest (5 tests)
- CreditGateVaultSecurityEdgeTest (5 tests)
- CreditGateVaultGracePeriodTest (5 tests)
- CreditScoreSBTTest (9 tests)
- SBTVaultIntegrationTest (3 tests)

---

## Gap #2 (CRITICAL): submission.ts — Multiple stale test counts

**File:** `frontend/src/app/docs/content/submission.ts`

| Line | Stale Value | Correct Value | Severity |
|------|-------------|---------------|----------|
| 71 | `159 tests across 13 suites` | 191 tests, 19 suites | CRITICAL |
| 74 | `test/CreditGateVault.go-tee-compat.t.sol` | test/CreditGateVault.tee-compat.t.sol | BROKEN REF |
| 97 | `146 across 13 suites` | 191 across 19 suites | CRITICAL |
| 128 | `146-test Foundry suite across 13 suites` | 191 tests, 19 suites | CRITICAL |
| 133 | `159 tests / 13 suites / 97.75% coverage` | 191 tests, 19 suites | CRITICAL |
| 148 | `159 tests / 13 suites / 0 failures` | 191 tests, 19 suites | CRITICAL |
| 152 | `# 159 tests, 13 suites, 0 failures` | 191 tests, 19 suites, 0 failures | CRITICAL |

**Note:** The "Key Numbers" table on line 97 also says "146 across 13 suites" — doubly stale (was 146→159→191).

---

## Gap #3 (MAJOR): architecture.ts — Stale count + broken file reference

**File:** `frontend/src/app/docs/content/architecture.ts`

| Line | Stale Value | Correct Value | Severity |
|------|-------------|---------------|----------|
| 170 | `13 suites / 159 tests` | 19 suites / 191 tests | MAJOR |
| 206 | `test/CreditGateVault.go-tee-compat.t.sol` | test/CreditGateVault.tee-compat.t.sol | BROKEN REF |

---

## Gap #4 (MAJOR): securityFixes.ts — Stale line number references

**File:** `frontend/src/app/docs/content/securityFixes.ts`

All test function name references are **correct** (functions exist), but **line numbers are stale** (off by 17-23 lines due to later code additions):

| Content Line | Referenced Location | Actual Line | Off By |
|------|-------------|---------------|--------|
| 40 | `CreditGateVault.t.sol:404` | 404 | ✅ Correct |
| 75 | `CreditGateVault.t.sol:772` | 789 | +17 lines |
| 77 | `CreditGateVault.t.sol:777` | 794 | +17 lines |
| 79 | `CreditGateVault.t.sol:469` | 469 | ✅ Correct |
| 105 | `CreditGateVault.t.sol:375` | 375 | ✅ Correct |
| 137 | `CreditGateVault.t.sol:608` | 625 | +17 lines |
| 171 | `CreditGateVault.t.sol:664` | 681 | +17 lines |
| 173 | `CreditGateVault.t.sol:679` | 696 | +17 lines |
| 175 | `CreditGateVault.t.sol:691` | 708 | +17 lines |
| 206 | `CreditGateVault.t.sol:1112` | 1135 | +23 lines |

Also stale:
| Line | Stale Value | Correct Value | Severity |
|------|-------------|---------------|----------|
| 11 | `141/141 passing, 11 suites` | 191/191 passing, 19 suites | MAJOR |
| 37 | `68/68 tests green` | Historical commit message (acceptable) | MINOR |
| 168 | `71/71 green` | Historical commit message (acceptable) | MINOR |
| 225 | `141/141 passing sweep (11 suites)` | 191/191, 19 suites | MAJOR |

**Note on `CreditGateVault.sol` line reference:**
- securityFixes.ts line 107 references `CreditGateVault.sol` lines 297-298 for the draw-time expiry re-check. Actual lines are 528-529. **Stale by 231 lines.**

---

## Gap #5 (MINOR): Broken file reference — go-tee-compat

Three content modules reference `test/CreditGateVault.go-tee-compat.t.sol` but the actual file is `test/CreditGateVault.tee-compat.t.sol`. The class name is also wrong: content says `CreditGateVaultGoTeeCompatTest` but actual is `CreditGateVaultTeeCompatTest`.

**Affected files:**
- testSummary.ts (line 20)
- submission.ts (line 74)
- architecture.ts (line 206)

---

## Gap #6 (MINOR): testSummary.ts coverage-report.txt reference

Line 53 references `coverage-report.txt` but this file does not exist at the repository root. The coverage numbers (97.75% lines, etc.) may still be accurate but the file reference is broken.

---

## Gap #7 (LOW): securityFixes.ts historical commit messages

Lines 37 and 168 reference historical commit messages "68/68 tests green" and "71/71 green" which were accurate at the time of those commits. These are **not stale** per se — they're quoting historical commit messages. However, the surrounding text (lines 11, 225) that summarizes current test status IS stale.

---

## Address Verification

All contract addresses in the content modules are **consistent and correct**:

| Address | Content Modules | Status |
|---------|----------------|--------|
| Vault: `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939` | submission.ts, liveDeployment.ts | ✅ Correct |
| FXRP: `0x0b6A3645c240605887a5532109323A3E12273dc7` | submission.ts, liveDeployment.ts | ✅ Correct |
| USDT0: `0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3` | submission.ts, liveDeployment.ts | ✅ Correct |
| FdcVerification: `0x906507E0B64bcD494Db73bd0459d1C667e14B933` | submission.ts, liveDeployment.ts, fdcAttestation.ts | ✅ Correct |
| FtsoV2: `0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d` | liveDeployment.ts | ✅ Correct |
| FdcHub: `0x48aC463d7975828989331F4De43341627b9c5f1D` | submission.ts, fdcAttestation.ts, fdcRealVerify.ts | ✅ Correct |

---

## Competitive Claims Check

The submission.ts competitive claim on line 23 says:
> "the only submission in Bounty 2 that binds a private eligibility check (FCC) to a public cross-chain repayment verification (FDC) in a single product flow"

This is the **mitigated/correct** framing (not the incorrect "only submission using all 4 Flare primitives" from the README). **No gap here** — the content module already uses the accurate claim.

---

## Summary of All Stale Numbers

| Module | Stale Count | Should Be | Occurrences |
|--------|-------------|-----------|-------------|
| testSummary.ts | 146 tests / 12 suites | 191 / 19 | 6 |
| testSummary.ts | 159 tests / 13 suites | 191 / 19 | 2 |
| submission.ts | 159 tests / 13 suites | 191 / 19 | 4 |
| submission.ts | 146 tests / 13 suites | 191 / 19 | 2 |
| architecture.ts | 159 tests / 13 suites | 191 / 19 | 1 |
| securityFixes.ts | 141/141 / 11 suites | 191/191 / 19 | 2 |
| **Total stale number references** | | | **17** |

| Module | Broken File Refs | Stale Line Numbers | Wrong Class Names |
|--------|------------------|--------------------|-------------------|
| testSummary.ts | 1 (go-tee-compat) | 0 | 1 (GoTeeCompat) |
| submission.ts | 1 (go-tee-compat) | 0 | 0 |
| architecture.ts | 1 (go-tee-compat) | 0 | 0 |
| securityFixes.ts | 0 | 8 (test lines) + 1 (sol line) | 0 |

---

## Recommended Fixes

1. **Regenerate all content modules** from updated evidence files (the modules say "Auto-generated — do not edit by hand" but the evidence files they were sourced from are also stale)
2. **Update testSummary.ts** with the current 191/19 suite breakdown (add 8 missing suites)
3. **Update submission.ts** Key Numbers table and evidence section with 191/19
4. **Update architecture.ts** line 170 with 19 suites / 191 tests
5. **Update securityFixes.ts** current-status lines (11, 225) with 191/19; fix line number references
6. **Fix all `go-tee-compat` references** to `tee-compat` across all 3 affected files
7. **Fix `CreditGateVaultGoTeeCompatTest`** → `CreditGateVaultTeeCompatTest` in testSummary.ts
8. **Fix `CreditGateVault.sol` line reference** in securityFixes.ts: 297-298 → 528-529
