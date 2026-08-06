# CreditGate Frontend — Full-Prism Security & UX Audit

**Auditor:** Hermes Agent (automated deep-prism review)  
**Date:** 2026-08-06  
**Scope:** All Next.js frontend pages, config, providers, and ABI definitions  
**Files analyzed:**
- `frontend/src/app/page.tsx` (landing page)
- `frontend/src/app/app/page.tsx` (main app — 564 lines)
- `frontend/src/app/transparency/page.tsx` (transparency dashboard)
- `frontend/src/app/providers.tsx` (wagmi/RainbowKit setup)
- `frontend/src/app/layout.tsx` (root layout)
- `frontend/src/config/contract.ts` (contract addresses/config)
- `frontend/src/lib/abi.ts` (ABI definitions)
- `frontend/package.json` (dependencies)

**Verdict:** 30 findings total — 5 High, 12 Medium, 13 Low

---

## Critical / High Severity

### S1 — Zero-Address Vault Fallback Wastes Gas & Misleads Users
| Field | Value |
|---|---|
| **ID** | S1 |
| **Severity** | High |
| **Category** | Security / Data Integrity |
| **File** | `src/config/contract.ts` lines 2–7 |
| **Description** | When `NEXT_PUBLIC_VAULT_ADDRESS` env var is unset, the vault address defaults to `0x0000…0000`. All contract reads target the zero address (returning garbage), and writes will send transactions to the zero address — wasting gas and potentially losing funds. The only safeguard is a `console.warn` invisible to end users. |
| **Impact** | Users can unknowingly interact with a non-existent contract. Deposit/withdraw/draw calls will either revert (gas lost) or silently fail. |
| **Fix** | Add a hard guard: if `vaultAddr === ZERO_ADDRESS`, render a full-screen "Configuration Error" banner instead of the app. Export a boolean `isConfigured` flag and check it in every page before rendering contract UI. |

---

### S2 — No Client-Side Validation of FCC Attestation JSON
| Field | Value |
|---|---|
| **ID** | S2 |
| **Severity** | High |
| **Category** | Security / Input Validation |
| **File** | `src/app/app/page.tsx` lines 126–151 |
| **Description** | User-pasted FCC JSON is `JSON.parse`d and fields are passed directly to `submitEligibility`. No validation that: `borrower` is a valid checksummed address, `limit`/`expiry`/`nonce` are valid integers, `v` ∈ {27,28}, `r`/`s` are valid 32-byte hex. On failure, the catch block only does `console.error` — user gets zero feedback. |
| **Impact** | Malformed or adversarial attestation data could be sent on-chain, wasting gas on reverts. Users receive no indication their input was invalid. |
| **Fix** | Add explicit field validation before the contract call: validate address format, numeric ranges, signature component lengths. Display a red inline error message if validation fails. Consider a textarea with JSON syntax highlighting. |

---

### S3 — USDT0 Allowance Read Uses Vault ABI Instead of ERC20 ABI
| Field | Value |
|---|---|
| **ID** | S3 |
| **Severity** | High |
| **Category** | Web3 Correctness |
| **File** | `src/app/app/page.tsx` lines 67–73 |
| **Description** | `useReadContract` for USDT0's `allowance()` passes `CREDIT_GATE_ABI` (the vault ABI). The function selector `0xdd62ed3e` for `allowance(address,address)` happens to match standard ERC20, so it works by coincidence. If the vault ABI ever changes or the selector collides, this breaks silently. The ABI mismatch also makes the codebase misleading to auditors and developers. |
| **Impact** | Brittle — works today but breaks if ABI is modified. Misleading for code review. |
| **Fix** | Create a separate `ERC20_ABI` with just `balanceOf`, `allowance`, `approve`, and use it for all ERC20 token reads. This is the correct wagmi v2 pattern. |

---

### S4 — No Transaction Confirmation Tracking
| Field | Value |
|---|---|
| **ID** | S4 |
| **Severity** | High |
| **Category** | Web3 Correctness / UX |
| **File** | `src/app/app/page.tsx` — all `useWriteContract` hooks |
| **Description** | After any write operation (`depositCollateral`, `drawLoan`, etc.), the app uses `isPending` to show a spinner but never calls `useWaitForTransactionReceipt` to detect when the tx is mined. No success notification is shown. After the tx is submitted, `isPending` returns false, and the UI reverts to the idle state — the user has no confirmation it succeeded. |
| **Impact** | Users don't know if their transaction was included in a block. No success toast. No automatic data refresh after confirmation. |
| **Fix** | Add `useWaitForTransactionReceipt` for each write hook. On success, show a toast notification, refetch all relevant queries (`balances`, `loans`, `allowance`), and clear input fields. |

---

### S5 — Inconsistent Hardcoded Test Counts Between Pages
| Field | Value |
|---|---|
| **ID** | S5 |
| **Severity** | High |
| **Category** | Data Integrity / Trust |
| **File** | `src/app/page.tsx` line 23 vs `src/app/transparency/page.tsx` line 145 |
| **Description** | Landing page shows "91/91 tests passing" while the transparency dashboard shows "76/76 tests passing". Both are hardcoded static strings that contradict each other. This destroys user trust — if basic stats are wrong, what else is inaccurate? |
| **Impact** | Erodes credibility. Judges/users who check both pages will notice the discrepancy and question the project's rigor. |
| **Fix** | Use a single source of truth (config constant or API endpoint). Update both pages to show the same number. Better: fetch test results from CI and display dynamically. |

---

## Medium Severity

### E1 — FCC JSON Parse Error Silently Consumed
| Field | Value |
|---|---|
| **ID** | E1 |
| **Severity** | Medium |
| **Category** | Error Handling |
| **File** | `src/app/app/page.tsx` lines 148–150 |
| **Description** | `catch (e) { console.error("Invalid FCC JSON:", e); }` — parse errors and `BigInt` conversion errors are swallowed. User sees nothing. |
| **Fix** | Display an inline error message: "Invalid attestation JSON — check format and try again." Show the specific error detail in a collapsible section. |

---

### E2 — No RPC Failure Handling on Read Hooks
| Field | Value |
|---|---|
| **ID** | E2 |
| **Severity** | Medium |
| **Category** | Error Handling |
| **File** | `src/app/app/page.tsx` and `src/app/transparency/page.tsx` — all `useReadContract` hooks |
| **Description** | If the Coston2 RPC endpoint is unreachable, all read hooks fail silently. `data` is `undefined`, and the UI shows `0`/`""`/default values with no error indication. Users think they have zero balance or no loans. |
| **Fix** | Destructure `error` from each `useReadContract` and display a warning banner when reads fail: "Unable to fetch on-chain data. Check your network connection." |

---

### E3 — Raw Revert Reasons Shown to Users
| Field | Value |
|---|---|
| **ID** | E3 |
| **Severity** | Medium |
| **Category** | Error Handling / UX |
| **File** | `src/app/app/page.tsx` lines 192–199 |
| **Description** | `txError?.message` displays raw Solidity revert strings or wallet error messages. Examples: "execution reverted: EligibilityExpired()", "User rejected the request." These are meaningless to non-technical users. |
| **Fix** | Parse known error patterns and map them to friendly messages: "The eligibility attestation has expired — request a new one." "Transaction was rejected in your wallet." "Insufficient gas for this transaction." |

---

### E4 — No Error Boundary
| Field | Value |
|---|---|
| **ID** | E4 |
| **Severity** | Medium |
| **Category** | Error Handling |
| **File** | `src/app/layout.tsx` |
| **Description** | No React error boundary wraps the app. If any component throws (e.g., BigInt conversion of invalid data, unexpected contract return shape), the entire page crashes to a white screen with no recovery. |
| **Fix** | Add a top-level `ErrorBoundary` component in `layout.tsx` that catches render errors and shows a "Something went wrong" fallback with a retry button. |

---

### U1 — No Success Notifications After Transactions
| Field | Value |
|---|---|
| **ID** | U1 |
| **Severity** | Medium |
| **Category** | UX |
| **File** | `src/app/app/page.tsx` — all write operations |
| **Description** | After a successful deposit, withdrawal, loan draw, etc., there is no toast, banner, or visual confirmation. The user's only indication is the loading spinner stopping. |
| **Fix** | Add a toast notification library (e.g., `sonner` or `react-hot-toast`). On tx confirmation, show: "✓ 100 FXRP deposited successfully." Include the tx hash as a link to the explorer. |

---

### U2 — No Skeleton/Loading States on Page Load
| Field | Value |
|---|---|
| **ID** | U2 |
| **Severity** | Medium |
| **Category** | UX |
| **File** | `src/app/app/page.tsx` and `src/app/transparency/page.tsx` |
| **Description** | Initial page render shows empty/default state (zero balances, "No loans found") until RPC calls complete. There's no loading indicator for the initial data fetch, making the app feel broken on slow connections. |
| **Fix** | Add skeleton placeholders for balance displays and loan cards. Use `isLoading` from `useReadContract` to conditionally render skeletons vs. real data. |

---

### U3 — No Back Navigation from App Page
| Field | Value |
|---|---|
| **ID** | U3 |
| **Severity** | Medium |
| **Category** | UX |
| **File** | `src/app/app/page.tsx` lines 186–189 |
| **Description** | The header shows "CreditGate Vault" and a `ConnectButton` but no link back to the landing page. Users must use the browser back button. |
| **Fix** | Add a home/back link or breadcrumb in the header: "← CreditGate" linking to `/`. |

---

### U4 — Liquidate Button Shown for All FUNDED Loans
| Field | Value |
|---|---|
| **ID** | U4 |
| **Severity** | Medium |
| **Category** | UX / Correctness |
| **File** | `src/app/app/page.tsx` lines 543–555 |
| **Description** | The "Liquidate (deadline passed)" button is displayed for every loan in state 4 (FUNDED), regardless of whether the deadline has actually passed. Users may click it prematurely, and if the contract reverts (deadline not passed), they lose gas. |
| **Fix** | Compare `deadline` against `Date.now() / 1000` to only show the liquidate button when `deadline < currentTimestamp`. Display the deadline as a human-readable countdown. |

---

### U5 — Shared `selectedLoanId` Between Draw and Submit Panels
| Field | Value |
|---|---|
| **ID** | U5 |
| **Severity** | Medium |
| **Category** | UX |
| **File** | `src/app/app/page.tsx` line 14, used at lines 306, 325, 332, 381, 387 |
| **Description** | A single `selectedLoanId` state variable is shared between the "Draw USDT0 Loan" and "Submit FCC Attestation" panels. Entering a loan ID in one panel changes it in the other, causing confusion. |
| **Fix** | Split into separate state: `drawLoanId` and `attestationLoanId`. Or use separate component instances. |

---

### P1 — QueryClient Has Default staleTime (Excessive RPC Calls)
| Field | Value |
|---|---|
| **ID** | P1 |
| **Severity** | Medium |
| **Category** | Performance |
| **File** | `src/app/providers.tsx` line 10 |
| **Description** | `new QueryClient()` uses default staleTime of 0ms. Every component mount, focus, and navigation triggers fresh RPC calls. On a public RPC endpoint with rate limits, this can cause throttling or 429 errors. |
| **Fix** | Configure with sensible defaults: `{ defaultOptions: { queries: { staleTime: 30_000, refetchOnWindowFocus: false } } }`. Use explicit `refetch()` after state-changing operations. |

---

### D1 — FXRP Decimals Hardcoded to 6
| Field | Value |
|---|---|
| **ID** | D1 |
| **Severity** | Medium |
| **Category** | Data Integrity |
| **File** | `src/app/app/page.tsx` lines 101, 237, 482 |
| **Description** | `parseUnits(amount, 6)` and `formatUnits(value, 6)` assume FXRP has 6 decimals. If the actual token has different decimals (e.g., 18), all amounts are off by 10^12. This is never read from the contract or config. |
| **Fix** | Define decimals in `contract.ts` config: `fxrpDecimals: 6, usdt0Decimals: 18`. Better: read from contract via `decimals()` function call. |

---

### D2 — No Locale-Aware Number Formatting
| Field | Value |
|---|---|
| **ID** | D2 |
| **Severity** | Medium |
| **Category** | Data Integrity / UX |
| **File** | `src/app/app/page.tsx` — all `formatUnits` display calls |
| **Description** | `formatUnits()` returns raw decimal strings (e.g., "1000000000000000000000") with no thousand separators or locale formatting. Large amounts are completely unreadable. |
| **Fix** | Wrap `formatUnits` results in `Number(value).toLocaleString(undefined, { maximumFractionDigits: 4 })` or use a utility like `viem`'s `formatUnits` + `Intl.NumberFormat`. |

---

## Low Severity

### A1 — Missing `<label htmlFor>` Binding
| Field | Value |
|---|---|
| **ID** | A1 |
| **Severity** | Low |
| **Category** | Accessibility |
| **File** | `src/app/app/page.tsx` lines 250–258, 304–321 |
| **Description** | `<label>` elements use `className` for styling but lack `htmlFor` attributes. Clicking a label doesn't focus the corresponding input. Screen readers can't associate labels with inputs. |
| **Fix** | Add `id` to each input and `htmlFor` to each label: `<label htmlFor="deposit-amount">` + `<input id="deposit-amount">`. |

---

### A2 — Error Banner Missing ARIA Role
| Field | Value |
|---|---|
| **ID** | A2 |
| **Severity** | Low |
| **Category** | Accessibility |
| **File** | `src/app/app/page.tsx` lines 192–199 |
| **Description** | The transaction error banner isn't announced to screen readers. No `role="alert"` or `aria-live="assertive"`. |
| **Fix** | Add `role="alert"` and `aria-live="assertive"` to the error banner div. |

---

### A3 — No Visible Focus Indicators Beyond Browser Defaults
| Field | Value |
|---|---|
| **ID** | A3 |
| **Severity** | Low |
| **Category** | Accessibility |
| **File** | All pages |
| **Description** | Tailwind classes don't include `focus-visible:ring-2` or similar focus indicator styles on buttons and inputs. Keyboard-only users can't see which element is focused. |
| **Fix** | Add `focus-visible:ring-2 focus-visible:ring-blue-500 focus-visible:ring-offset-2 focus-visible:ring-offset-gray-950` to all interactive elements. |

---

### A4 — No Skip-to-Content Link
| Field | Value |
|---|---|
| **ID** | A4 |
| **Severity** | Low |
| **Category** | Accessibility |
| **File** | `src/app/layout.tsx` |
| **Description** | No skip navigation link for keyboard users to bypass the header. |
| **Fix** | Add a visually-hidden skip link: `<a href="#main-content" className="sr-only focus:not-sr-only">Skip to content</a>`. |

---

### U6 — No Focus Management After TX Error
| Field | Value |
|---|---|
| **ID** | U6 |
| **Severity** | Low |
| **Category** | UX / Accessibility |
| **File** | `src/app/app/page.tsx` lines 192–199 |
| **Description** | When a transaction error appears, focus isn't moved to the error banner. Screen reader users may not notice the error. |
| **Fix** | Use a `ref` on the error banner and call `.focus()` when it appears. Or use `aria-live` region. |

---

### U7 — No Input Validation for Negative Values
| Field | Value |
|---|---|
| **ID** | U7 |
| **Severity** | Low |
| **Category** | UX |
| **File** | `src/app/app/page.tsx` lines 251–258, 314–320 |
| **Description** | `type="number"` inputs don't prevent negative values. While `parseUnits` may revert for negatives, the UX allows typing them. |
| **Fix** | Add `min="0"` attribute and validate in the onChange handler: `if (Number(e.target.value) < 0) return`. |

---

### U8 — USDT0 Allowance Display Shows Raw BigInt
| Field | Value |
|---|---|
| **ID** | U8 |
| **Severity** | Low |
| **Category** | UX |
| **File** | `src/app/app/page.tsx` line 343, 357 |
| **Description** | `formatUnits(usdt0Allowance, 18)` displays values like "100000000000000000000" for 100 USDT0 approved. Not human-readable. |
| **Fix** | Format with locale-aware display and limit decimal places. Show "100.00 USDT0 approved" instead of the raw value. |

---

### D3 — Loan Deadlines and Expiry Not Displayed
| Field | Value |
|---|---|
| **ID** | D3 |
| **Severity** | Low |
| **Category** | Data Integrity / UX |
| **File** | `src/app/app/page.tsx` lines 449–450 |
| **Description** | `deadline` and `eligibilityExpiry` are read from the contract but never shown in the UI. Users have no way to know when their loan deadline is or when their eligibility expires. |
| **Fix** | Display as human-readable dates: `new Date(Number(deadline) * 1000).toLocaleString()`. Add countdown for active deadlines. |

---

### D4 — Total Loans Count Off-by-One When Zero Loans
| Field | Value |
|---|---|
| **ID** | D4 |
| **Severity** | Low |
| **Category** | Data Integrity |
| **File** | `src/app/transparency/page.tsx` line 88 |
| **Description** | `(Number(nextLoanId) - 1)` displays "-1" when `nextLoanId` is 0 (no loans yet). |
| **Fix** | Use `Math.max(0, Number(nextLoanId) - 1).toString()`. |

---

### D5 — Collateral Ratio Rounding Loses Precision
| Field | Value |
|---|---|
| **ID** | D5 |
| **Severity** | Low |
| **Category** | Data Integrity |
| **File** | `src/app/transparency/page.tsx` line 82 |
| **Description** | `(Number(collateralRatio) / 100).toFixed(0)` rounds to nearest integer. A ratio of 15050 bps shows "151%" instead of "150.5%". |
| **Fix** | Use `.toFixed(1)` or show the exact bps value: "15050 bps (150.5%)". |

---

### P2 — No Code Splitting / Dynamic Imports
| Field | Value |
|---|---|
| **ID** | P2 |
| **Severity** | Low |
| **Category** | Performance |
| **File** | `src/app/app/page.tsx` |
| **Description** | The entire app page with all hooks, state, and the `LoanCard` sub-component is in a single file. No lazy loading or dynamic imports. The landing page also imports RainbowKit's `ConnectButton` eagerly. |
| **Fix** | Consider `dynamic(() => import('./LoanCard'), { ssr: false })` for components that only render client-side. Use Next.js `dynamic` for heavy third-party components. |

---

### P3 — No React.memo on LoanCard
| Field | Value |
|---|---|
| **ID** | P3 |
| **Severity** | Low |
| **Category** | Performance |
| **File** | `src/app/app/page.tsx` line 417 |
| **Description** | `LoanCard` is not wrapped in `React.memo`. Each parent re-render re-renders all loan cards, even if their data hasn't changed. With many loans, this causes unnecessary RPC refetches. |
| **Fix** | Wrap in `React.memo` or use `memo(LoanCard)`. Ensure the `loanId` prop is stable (it is — it's a `bigint`). |

---

### P4 — Unused Dependencies Increase Bundle Size
| Field | Value |
|---|---|
| **ID** | P4 |
| **Severity** | Low |
| **Category** | Performance / Supply Chain |
| **File** | `package.json` lines 14–15 |
| **Description** | `@x402/evm` and `@x402/svm` are listed as dependencies but never imported in any frontend file. They increase `node_modules` size and attack surface. |
| **Fix** | Remove unused dependencies: `npm uninstall @x402/evm @x402/svm`. If needed later, add them back. |

---

### R1 — FCC JSON Input Overflow on Mobile
| Field | Value |
|---|---|
| **ID** | R1 |
| **Severity** | Low |
| **Category** | Responsive Design |
| **File** | `src/app/app/page.tsx` lines 372–377 |
| **Description** | The FCC JSON input has `text-xs font-mono` with a very long placeholder text. On narrow viewports, the placeholder overflows or is truncated, making it hard to understand the expected format. |
| **Fix** | Use a `<textarea>` with `rows={4}` instead of an `<input>`. Add `overflow-x-auto` or use a code block with proper wrapping. |

---

### R2 — Architecture Diagram Requires Horizontal Scroll on Mobile
| Field | Value |
|---|---|
| **ID** | R2 |
| **Severity** | Low |
| **Category** | Responsive Design |
| **File** | `src/app/transparency/page.tsx` lines 202–209 |
| **Description** | The ASCII architecture diagram in `<pre>` with `overflow-x-auto` requires horizontal scrolling on mobile. The diagram is a single long line that doesn't wrap. |
| **Fix** | Consider a responsive SVG diagram or restructure the ASCII art to wrap on smaller screens. Or add `text-xs` to the `<pre>` element. |

---

### D6 — "Repay XRP drops" Label is Confusing
| Field | Value |
|---|---|
| **ID** | D6 |
| **Severity** | Low |
| **Category** | Data Integrity / UX |
| **File** | `src/app/app/page.tsx` line 491 |
| **Description** | `formatUnits(requiredRepaymentDrops, 6)` with label "XRP (drops)" — the value is displayed in drops (6 decimal places), but most users think in whole XRP. Showing "1000000 drops" instead of "1 XRP" is confusing. |
| **Fix** | Display in both formats: "1.00 XRP (1,000,000 drops)" or just show XRP with the drops value in a tooltip. |

---

### S6 — No `role="alert"` on Network Mismatch Banner
| Field | Value |
|---|---|
| **ID** | S6 |
| **Severity** | Low |
| **Category** | Accessibility / Security |
| **File** | `src/app/app/page.tsx` lines 202–220 |
| **Description** | The network mismatch warning isn't announced to assistive technology. Screen reader users won't know they're on the wrong chain. |
| **Fix** | Add `role="alert"` and `aria-live="assertive"` to the warning div. |

---

## Summary Statistics

| Severity | Count |
|---|---|
| **High** | 5 |
| **Medium** | 12 |
| **Low** | 13 |
| **Total** | 30 |

### Category Breakdown

| Category | Findings |
|---|---|
| Security | 3 (S1, S2, S3) |
| Web3 Correctness | 1 (S4) |
| Error Handling | 4 (E1–E4) |
| UX | 8 (U1–U8) |
| Accessibility | 4 (A1–A4) |
| Performance | 4 (P1–P4) |
| Responsive | 2 (R1–R2) |
| Data Integrity | 7 (D1–D6, S5, S6) |

### Positive Observations (Things Done Well)

1. **No XSS vectors** — No `dangerouslySetInnerHTML` usage anywhere. All dynamic content is safely rendered as text nodes via JSX interpolation.
2. **Chain ID validation present** — The `wrongNetwork` check with `useSwitchChain` is correct wagmi v2 usage.
3. **Wagmi v2 hooks used correctly** — `useReadContract`, `useWriteContract`, `useAccount`, `useChainId` are all proper v2 API.
4. **External links have `rel="noopener noreferrer"`** — The explorer links are properly secured against tab-nabbing.
5. **Graceful disconnected state** — The app shows a clear "connect your wallet" message when not connected.
6. **ABI uses human-readable format** — Clean and maintainable.
7. **RainbowKit properly configured** — Provider hierarchy is correct (WagmiProvider → QueryClientProvider → RainbowKitProvider).

---

## Priority Remediation Order

1. **S1** — Zero-address guard (5 min fix, prevents fund loss)
2. **S5** — Fix inconsistent test counts (2 min fix, trust issue)
3. **S4** — Add `useWaitForTransactionReceipt` (30 min, critical UX)
4. **S2** — FCC JSON validation (20 min, prevents wasted gas)
5. **S3** — Separate ERC20 ABI (15 min, code hygiene)
6. **E1–E4** — Error handling improvements (2 hours)
7. **U1–U5** — UX improvements (3 hours)
8. **D1–D6** — Data integrity fixes (1 hour)
9. **A1–A4** — Accessibility fixes (1 hour)
10. **P1–P4, R1–R2** — Performance & responsive (1 hour)

**Estimated total remediation: ~8–9 hours of focused work.**
