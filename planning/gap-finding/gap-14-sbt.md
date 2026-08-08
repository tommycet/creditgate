# Gap Report #14: CreditScoreSBT

**Date:** 2026-08-08  
**Subagent:** #14 (gap-finding)

## Executive Summary

The CreditScoreSBT is **solidly implemented, tested, and deployed**. It is truly soulbound with no critical gaps. Minor documentation gaps exist.

## Detailed Findings

### 1. Soulbound Mechanism — ✅ PASS
- Overrides `ERC721._update()` (line 119-130 in `CreditScoreSBT.sol`)
- Blocks ALL transfers where both `from != address(0)` AND `to != address(0)`
- Only minting (`from == address(0)`) and burning (`to == address(0)`) permitted
- Both `transferFrom` and `safeTransferFrom` are covered since both reach `_update`
- Custom error `SoulboundTransferBlocked(from, to)` for clear revert messages

### 2. Access Control — ✅ PASS
- `mintOrUpdate()` checks `msg.sender != vault` → reverts with `NotVault(caller, vault)`
- `vault` is set once in constructor (`vault = msg.sender`) and is immutable
- Only the CreditGateVault can mint or update tokens
- No owner/upgradeable pattern — the vault linkage is permanent by design

### 3. tokenURI Metadata — ✅ PASS
- Returns `data:application/json;utf8,{...}` URI (on-chain, no external service needed)
- JSON includes: name, description, and attributes array with:
  - score, loansCompleted, loansDefaulted, totalBorrowed, totalRepaid, lastUpdated
- Reverts with "NonexistentToken" for unminted token IDs
- Uses `string.concat` to avoid stack-too-deep (no Base64 dependency)

### 4. Deployment on Coston2 — ✅ PASS (child contract)
- Vault deployed on Coston2 (chainId 114) via `DeployCreditGate.s.sol`
- Broadcast at: `broadcast/DeployCreditGate.s.sol/114/run-latest.json`
- Vault address: `0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939`
- SBT is deployed as child contract in Vault constructor (line 199): `creditScoreSBT = new CreditScoreSBT()`
- SBT address is NOT separately recorded in broadcast (only vault CREATE tx logged)
- **Minor gap:** SBT child contract address not explicitly logged in deployment output

### 5. Minting Path — "first repayment" — ✅ PASS
- `submitRepaymentProof()` (line 741-769) computes score and calls `creditScoreSBT.mintOrUpdate()`
- Score formula: base 50 + completed×10 − defaulted×25 + (repaid×20/borrowed), clamped [0,100]
- Idempotent: first call mints, subsequent calls update in place
- Also called from `liquidate()` (line 824) and `_startLiquidation()` (line 1427) — updates on default too
- **Verified:** README claim "minted on first loan repayment" matches code

### 6. Test Coverage — ✅ PASS (8 tests)
| Test | Coverage |
|------|----------|
| `test_sbt_mintsOnFirstRepayment` | First mint, token id 1, score=80 |
| `test_sbt_updatesOnSecondRepayment` | Update in place, score improves to 90 |
| `test_sbt_cannotBeTransferred` | transferFrom + safeTransferFrom both revert |
| `test_sbt_scoreReflectsHistory` | Default path: score=58 (2 completed, 1 defaulted) |
| `test_sbt_onlyVaultCanMint` | Borrower + third party both blocked |
| `test_sbt_getScore` | Pre-mint zeros, post-mint values, mapping cross-check |
| `test_sbt_tokenURI` | data URI prefix, JSON attributes, nonexistent revert |
| `test_sbt_tokenURI_revertsForUnminted` | Edge case: token id 1 before any mint |
| `test_sbt_metadata` | Name="CreditGate Credit Score", Symbol="CGSCORE" |

## Gaps Found

### Gap A: SBT Address Not Logged in Deployment Output (Low)
**Severity:** Low  
**Issue:** The deploy script logs vault address but does NOT log the SBT child contract address. For hackathon demo/explorer verification, judges need to look up the SBT address manually (read `vault.creditScoreSBT()` on-chain).  
**Fix:** Add `console.log("CreditScoreSBT:   ", address(vault.creditScoreSBT()));` to `DeployCreditGate.s.sol` after vault deployment.

### Gap B: No Public Burn Function (By Design — Not a Gap)
**Observation:** The `_update` guard allows burns (`to == address(0)`), but there is no public `burn()` function. This is intentional — SBTs should not be destroyed. The burn path exists only as a safeguard for the ERC721 pattern.

### Gap C: Score Formula Duplication (Low)
**Severity:** Low  
**Issue:** The score computation formula (50 + completed×10 − defaulted×25 + repaid×20/borrowed) is copy-pasted in three places: `submitRepaymentProof`, `liquidate`, and `_startLiquidation`.  
**Fix:** Extract to a `internal view _computeScore(address borrower) returns (uint256)` helper to reduce duplication.

## Conclusion

The CreditScoreSBT is **production-ready** with no critical or high-severity gaps. It is truly soulbound, properly access-controlled, well-tested (8 tests covering all paths), and deployed on Coston2 as a child of the vault. The minor gaps (logging, deduplication) are polish items, not blockers.
