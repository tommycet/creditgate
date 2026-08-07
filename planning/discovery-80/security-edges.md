# Security Edge Cases & Test Coverage Gaps

**Date:** 2026-08-07
**Scope:** CreditGateVault.sol (1173 lines), 11 test suites, 141 tests, 8 invariants
**Sources:** Contract audit, test suite review, OWASP Smart Contract Top 10:2026, DeFi lending incident research (2025-2026)

---

## 1. Coverage Gaps Found in Existing Tests

### 1.1 Interest Accounting — Only Partially Tested

| Gap | Risk | Details |
|-----|------|---------|
| Interest accrues past deadline | **HIGH** | No test validates what happens when a borrower repays (submitRepaymentProof) AFTER the loan deadline but BEFORE liquidation. The contract computes interest via `getInterestOwed()` which reads `block.timestamp` — at `elapsed >= loanDuration`, interest caps at `loanAmount * INTEREST_RATE_BPS * loanDuration / (10000 * SECONDS_PER_YEAR)`. But there's no test confirming repayment is still accepted past deadline (state is still FUNDED until liquidated). A borrower could repay at the last second to avoid liquidation while accruing maximum interest. |
| Interest rounding favors protocol | **MEDIUM** | Interest is computed with integer division (`/ (10000 * SECONDS_PER_YEAR)`). No test checks that a 1-wei-below-threshold repayment still passes (boundary rounding). If a borrower calculates repayment from `getTotalRepayment()` and sends exactly that amount, integer truncation could cause `InsufficientRepayment` due to rounding up in `interestDrops` conversion. |
| Interest on extremely small loans | **LOW** | No fuzz test for dust amounts (e.g., 1 wei loan). `interestUSDT0 = loanAmount * INTEREST_RATE_BPS * elapsed / (10000 * SECONDS_PER_YEAR)` could yield 0 interest for very small loans, which is correct behavior but untested. |

### 1.2 Auction Edge Cases — Under-tested

| Gap | Risk | Details |
|-----|------|---------|
| Bidder self-bidding (same address as highestBidder) | **HIGH** | `bidOnLiquidation` refunds the previous highest bidder before taking the new bid. If the same address calls it twice, the refund sends USDT0 back to the bidder, then `transferFrom` pulls it again. Net effect is correct (no loss), but this is untested and could interact with token fee-on-transfer. |
| Auction price drops to exactly 0 at AUCTION_DURATION | **MEDIUM** | `getAuctionPrice` returns 0 when `elapsed >= AUCTION_DURATION`. `finalizeAuction` requires `block.timestamp >= startTimestamp + AUCTION_DURATION`. At exactly `AUCTION_DURATION`, `getAuctionPrice` returns 0 but `bidOnLiquidation` rejects bids below `currentPrice` (0). No test covers this exact boundary. |
| Multiple rapid auctions on the same loan | **MEDIUM** | After `finalizeAuction` sets state to CLOSED, no test verifies that `startLiquidationAuction` reverts on a CLOSED loan (it should, via the `FUNDED` state check). The guard exists but is not explicitly tested for all terminal states. |
| Bidder front-running the auction start | **MEDIUM** | An attacker could see `startLiquidationAuction` in the mempool, compute the start price, and submit a bid in the same block. No test for MEV-style front-running of auction initiation. |

### 1.3 FDC Proof Handling — Critical Gaps

| Gap | Risk | Details |
|-----|------|---------|
| Proof reuse across different loans | **CRITICAL** | `proofConsumed[proofHash]` is keyed on `keccak256(abi.encode(proof))`. If borrower has two funded loans with identical repayment amounts/deadlines/memos (possible if drawn at same price), the commitment differs (includes loanId). But no test explicitly verifies that a proof for loan A cannot be used on loan B. |
| Negative receivedAmount in FDC proof | **HIGH** | `resp.receivedAmount` is `int256`. The check `uint256(int256(resp.receivedAmount))` casts signed to unsigned — if `receivedAmount` is negative, this wraps to a huge number that PASSES the check. No test for negative receivedAmount in FDC proofs. |
| FDC verification returns true but proof is malformed | **HIGH** | Mock always returns `fdc.setResult(true)`. No test for what happens when `verifyXRPPayment` returns true but `resp.status != 0` (payment failed on XRPL). The `PaymentFailed` error exists but is only tested implicitly. |
| Memo data length != 32 bytes | **MEDIUM** | `resp.firstMemoData.length != 32` reverts with `MemoDataWrongLength`. The test suite builds proofs with exactly 32-byte memos. No test for short (<32) or long (>32) memo data. |
| Borrower repays using someone else's proof | **MEDIUM** | `submitRepaymentProof` requires `msg.sender == borrower`. But what if borrower1 sees borrower2's XRPL transaction, constructs a proof, and submits it to close borrower2's loan? The receivingAddressHash check prevents this (must match loan's snapshot), but no test verifies this cross-borrower attack scenario. |

### 1.4 State Machine Edge Cases

| Gap | Risk | Details |
|-----|------|---------|
| IDLE → COLLATERAL_DEPOSITED → IDLE cycle | **MEDIUM** | `withdrawCollateral` sets state to IDLE and `collateralAmount = 0`. But `depositCollateral` creates a NEW loan (monotonic nextLoanId). No test verifies that a borrower can re-deposit after withdrawal in the same transaction (e.g., flash-deposit, check something, withdraw). |
| All 7 states in sequence | **LOW** | No single test walks through: IDLE → COLLATERAL_DEPOSITED → ELIGIBILITY_PENDING → ELIGIBLE → FUNDED → (AUCTION →) CLOSED/DEFAULTED → IDLE. The fixture test covers most transitions but skips AUCTION for the happy path. |
| Liquidate + recover + re-deposit | **LOW** | `recoverDefaultedCollateral` sets state to IDLE. No test confirms the borrower can then re-deposit into that same slot (they can't — `nextLoanId++` means new slot). This is correct behavior but untested. |

### 1.5 Owner/Admin Operations

| Gap | Risk | Details |
|-----|------|---------|
| Transfer ownership to zero address | **LOW** | `transferOwnership` has `require(newOwner != address(0))`. Tested in main suite. But what about `transferOwnership` to the vault itself? The vault would then be unable to call `recoverDefaultedCollateral` because `msg.sender != owner` would be `address(this) != address(this)` — wait, that's actually fine. Still, no test for this. |
| LTV change mid-loan lifecycle | **HIGH** | `updateLTV` changes LTV for new draws but "does not retroactively affect outstanding loans." No test verifies that an outstanding FUNDED loan is NOT affected by a subsequent LTV tightening. The draw-time check only runs at draw. But `getHealthFactor` uses the current collateral amount — LTV is not used in health factor calculation. This means a borrower could have a loan that would have been rejected at draw time if the current LTV applied. |
| Paused vault + emergency operations | **MEDIUM** | `withdrawCollateral`, `depositCollateral`, `drawLoan`, etc. all have `whenNotPaused`. But `liquidate`, `recoverDefaultedCollateral`, `bidOnLiquidation`, `finalizeAuction`, and `startLiquidationAuction` are NOT gated by `whenNotPaused`. This is intentional (liquidation must proceed even when paused), but no test verifies that liquidation/auction operations work while paused. |
| Nonce overflow at uint32 max | **LOW** | `borrowerNonce` is uint32. After 4,294,967,295 attestations, it can't increment. The code has a guard (`if (borrowerNonce[borrower] < type(uint32).max)`). No test for this boundary. |

---

## 2. Attack Vectors Requiring New Tests

### 2.1 Flash Loan Attacks on Collateral

**Risk: HIGH** | **Effort: Medium (2-3 tests)**

Flash loans could be used to:
1. **Inflate collateral value**: Borrow FXRP via flash loan, deposit as collateral, draw loan, repay flash loan — but FXRP is wrapped XRP, not an AMM-traded token, so spot manipulation is unlikely on Flare. However, if FXRP has secondary markets (DEX pools), price manipulation could affect the FTSO feed.
2. **Sandwich liquidations**: Flash loan to manipulate price → trigger liquidation → buy collateral cheap → return flash loan.

**Recommended tests:**
- `test_flashLoan_cannotInflateCollateralAndDraw` — Simulate a flash-loan-like deposit+draw in one transaction (verify no extra value extracted)
- `test_flashLoan_cannotSandwichLiquidation` — Simulate price manipulation around liquidation trigger

### 2.2 Oracle Manipulation (FTSO Price Feed)

**Risk: HIGH** | **Effort: Medium (3-4 tests)**

The contract reads FTSOv2 via `getFeedByIdInWei`. Current tests always use mock prices set to exact values. Missing:
- **Stale price + warp**: Set price at T, warp past staleness limit, verify drawLoan reverts
- **Zero price handling**: FTSO returns 0 — contract reverts with `FTSOPriceZero`, but no test verifies this for `startLiquidationAuction` (it does check, but untested)
- **Price manipulation within same block**: The FTSO feed is read at call time — can an attacker influence the FTSO read within a single transaction?

**Recommended tests:**
- `test_drawLoan_revertsOnStaleFTSOPrice` — Set price at T, warp T+301s, attempt draw
- `test_startLiquidationAuction_revertsOnZeroFTSOPrice` — Set price to 0, attempt auction
- `test_triggerLiquidation_handlesFTSOOutageGracefully` — Verify no-op when FTSO returns 0

### 2.3 Reentrancy Variants

**Risk: MEDIUM** | **Effort: Low (1-2 tests)**

Existing tests cover basic `nonReentrant` guard on `depositCollateral`. Missing:
- **Cross-function reentrancy**: Re-enter via `withdrawCollateral` during a `submitRepaymentProof` callback
- **Cross-contract reentrancy**: If FXRP token calls back during `safeTransfer`, could the borrower trigger `requestEligibility` on another loan?

**Recommended tests:**
- `test_reentrancy_withdrawDuringRepaymentCallback` — Malicious FXRP re-enters withdrawCollateral
- `test_reentrancy_crossLoanReentry` — Attempt to manipulate loan B during loan A's state transition

### 2.4 Front-Running Collateral Deposit/Eligibility

**Risk: MEDIUM** | **Effort: Low (1 test)**

An attacker could:
1. See `depositCollateral` in mempool → front-run with `revokeEligibility` (owner only)
2. See `requestEligibility` → front-run with `revokeEligibility` → borrower's attestation is now invalid
3. See `drawLoan` → front-run with price manipulation (if possible) to make collateral insufficient

**Recommended tests:**
- `test_revokeEligibility_frontRunBeforeRequest` — Owner revokes, then borrower requests (attestation should be stale)
- `test_revokeEligibility_frontRunBetweenRequestAndSubmit` — Owner revokes after request but before submit

### 2.5 Liquidation MEV

**Risk: HIGH** | **Effort: Medium (2-3 tests)**

The Dutch auction is designed to be MEV-resistant, but:
- **Auction sniping**: Bidding at the last second when price is lowest
- **Bid front-running**: Seeing a bid in mempool and outbidding by 1 wei
- **Auction initialization manipulation**: Starting the auction at a manipulated price (FTSO read)

**Recommended tests:**
- `test_auction_bidSniping_lastSecondBid` — Bid at t=AUCTION_DURATION-1
- `test_auction_bidFrontRunning` — Two bidders compete (second outbids by 1 wei)
- `test_auction_startPriceManipulation` — Manipulate FTSO price at auction start vs. loan origination

### 2.6 State Machine Edge Cases

**Risk: LOW** | **Effort: Low (1 test)**

- **Re-entrant state transitions**: Can `liquidate` be called twice on the same loan? (No — state check prevents it, but untested)
- **Simultaneous liquidation + repayment**: Borrower submits repayment proof while keeper triggers liquidation in same block

**Recommended tests:**
- `test_liquidate_cannotLiquidateSameLoanTwice` — Attempt double liquidation
- `test_repaymentAndLiquidation_racingConditions` — Simulate concurrent repayment proof + liquidation trigger

---

## 3. High-Risk Findings from Web Research Applied to CreditGate

### 3.1 OWASP SC04:2026 — Flash Loan-Facilitated Attacks

CreditGateVault uses FTSOv2 for price (not a DEX AMM), so standard flash-loan-then-swap manipulation doesn't directly apply. However:
- If FXRP has ANY DEX pool on Flare, an attacker could flash-borrow and dump FXRP to crash its spot price, potentially influencing FTSO feeds (FTSO aggregates from multiple sources, so single-DEX manipulation is unlikely but should be tested)
- The `checkAndTriggerLiquidation` permissionless trigger could be weaponized: flash-loan to crash price → trigger liquidation → bid cheap → profit

### 3.2 OWASP SC03:2026 — Price Oracle Manipulation

FTSO is Flare's decentralized oracle (similar to Chainlink). The contract has:
- `ftsoStalenessLimit` guard (5 minutes) ✅
- Zero-price guard ✅
- But NO price deviation check (e.g., price can change 50% between consecutive reads)
- No TWAP or multi-block averaging

**Recommendation:** Add a max-price-deviation check (e.g., reject if current price differs from previous price by >X%).

### 3.3 OWASP SC02:2026 — Business Logic Vulnerabilities

The most relevant finding: **LTV tightening does not retroactively affect outstanding loans**. This is documented in `updateLTV` comments, but:
- An attacker could borrow at 75% LTV, then the owner tightens to 60%, and the attacker's loan remains at 75% collateralization
- The loan could become undercollateralized faster than expected
- This is by design but should be explicitly documented as a known risk

### 3.4 Cross-Chain Bridge Risk (FDC)

The FDC proof verification is a cross-chain oracle. Key risks:
- **Proof replay across chains**: If the same XRPL transaction is provable on multiple Flare instances, could a proof be replayed?
- **Data availability**: If the DA layer goes down, proofs can't be submitted. No timeout/force-close mechanism exists.
- **Merkle proof manipulation**: The contract trusts `FdcVerification.verify()` — if the verifier contract is compromised, all proofs pass.

---

## 4. Recommended New Test Cases (Priority Order)

| # | Test | Risk | Effort | Priority |
|---|------|------|--------|----------|
| 1 | Negative `receivedAmount` in FDC proof wraps to huge value, bypassing repayment check | CRITICAL | Low | **P0** |
| 2 | Proof for loan A cannot close loan B (cross-loan proof replay) | CRITICAL | Low | **P0** |
| 3 | Interest accrues past deadline — borrower repays at last second | HIGH | Low | **P0** |
| 4 | LTV tightening does NOT affect outstanding funded loans | HIGH | Low | **P1** |
| 5 | Bidder self-bidding (same address calls bidOnLiquidation twice) | HIGH | Low | **P1** |
| 6 | Paused vault allows liquidation/auction operations | MEDIUM | Low | **P1** |
| 7 | Stale FTSO price reverts drawLoan | MEDIUM | Low | **P2** |
| 8 | Auction boundary: getAuctionPrice returns 0 at AUCTION_DURATION | MEDIUM | Low | **P2** |
| 9 | Memo data != 32 bytes reverts | MEDIUM | Low | **P2** |
| 10 | FDC proof with status != 0 reverts with PaymentFailed | MEDIUM | Low | **P2** |
| 11 | Flash-loan-style deposit+draw extraction (no profit possible) | MEDIUM | Medium | **P2** |
| 12 | Interest rounding boundary (1-wei-below-threshold repayment) | MEDIUM | Low | **P2** |
| 13 | Double liquidation of same loan reverts | LOW | Low | **P3** |
| 14 | Nonce overflow at uint32.max boundary | LOW | Low | **P3** |
| 15 | Borrower repays with someone else's proof (cross-borrower attack) | LOW | Medium | **P3** |

---

## 5. Summary of Current Coverage

| Area | Tests | Coverage | Gap |
|------|-------|----------|-----|
| Core flow (deposit→eligibility→draw→repay→close) | ~40 | ✅ Strong | Interest past deadline |
| Reentrancy | 3 (real + malicious) | ✅ Good | Cross-function/cross-contract |
| Edge cases | 13 | ✅ Good | Negative FDC amounts |
| Invariants | 8 | ✅ Good | Interest rounding, LTV retroactivity |
| Auction | 5 | ⚠️ Moderate | Self-bidding, front-running, boundaries |
| Liquidation trigger | 9 | ✅ Good | FTSO outage during trigger |
| LTV | 7 | ✅ Good | Retroactive tightening |
| Views | 12 | ✅ Good | Interest boundary math |
| FDC/repayment | 5 (fixture) | ⚠️ Moderate | Cross-loan proof, negative amounts |
| Admin operations | ~10 | ⚠️ Moderate | Pause + liquidation, nonce overflow |
| Flash loan attacks | 0 | ❌ Missing | All scenarios |
| Oracle manipulation | 0 | ❌ Missing | Stale price, zero price for auction |
| MEV/front-running | 0 | ❌ Missing | Auction sniping, bid front-running |

---

## 6. Key Action Items

1. **Immediate (P0):** Add test for negative `receivedAmount` in FDC proof — this is a potential fund-loss vulnerability where a negative int256 casts to a huge uint256
2. **Immediate (P0):** Add cross-loan proof replay test — verify proof for loan A cannot close loan B
3. **Before hackathon submission:** Add 3-5 flash loan / oracle manipulation tests to demonstrate defense-in-depth
4. **Nice-to-have:** Add MEV front-running tests for the Dutch auction to show the auction design is robust
5. **Documentation:** Document that LTV tightening is non-retroactive and that past-deadline repayment is possible (design decision, not a bug)
