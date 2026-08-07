# Frontend UX Research — CreditGate

**Date:** 2026-08-07  
**Author:** Hermes subagent (discovery-82)  
**Scope:** DeFi lending dashboard UX improvements for CreditGate (Flare Summer Signal hackathon)  
**Status:** Research findings only — no code changes

---

## Current State Audit

### Stack
| Layer | Version | Notes |
|-------|---------|-------|
| Next.js | 15.x | App Router, no `loading.tsx` / `error.tsx` |
| React | 19.x | — |
| wagmi | 2.14 | `useReadContract`, `useWriteContract`, `useWaitForTransactionReceipt` |
| viem | 2.21 | — |
| RainbowKit | 2.2 | Only MetaMask configured; no theming |
| Tailwind | 3.4 | No `tailwind.config.js` found (zero config) |
| React Query | 5.x | — |

### What Exists
- **Landing page** (`/`): Hero, 4-step flow, Why CreditGate, Flare primitives, security badges
- **App page** (`/app`): Deposit, XRPL binding, loan draw, FCC attestation, repay flow, loan cards
- **Transparency page** (`/transparency`): Vault status, reserves, primitives, test badges, architecture
- **Docs** (`/docs/*`): 7 pages with sidebar navigation
- **Health factor badge** (S49): Traffic-light HF display on loan cards (green/yellow/red)
- **Dutch auction panel** (S49): Countdown timer, bid UI, finalize button

### What's Missing (Summary)
| Gap | Severity | Effort |
|-----|----------|--------|
| No `loading.tsx` / `error.tsx` / `not-found.tsx` | High | ⭐ |
| All pages are `"use client"` (no Server Components) | Medium | ⭐⭐ |
| No skeleton loading for contract reads | High | ⭐⭐ |
| Custom toast (manual `useState`) vs toast library | Medium | ⭐ |
| RainbowKit only lists MetaMask | Low | ⭐ |
| No RainbowKit theming/custom ConnectButton | Low | ⭐ |
| No loan health visualizer (gauge/progress) | High | ⭐⭐ |
| No collateral ratio bar/visualizer | High | ⭐⭐ |
| No transaction history / activity feed | Medium | ⭐⭐⭐ |
| No "Max" button on deposit/loan inputs | Low | ⭐ |
| Docs layout not mobile-responsive | Medium | ⭐ |
| No favicon / OG images | Low | ⭐ |
| No dark/light mode toggle (always dark) | Low | ⭐ |
| No `next/image` usage anywhere | Low | ⭐ |

---

## 1. DeFi Lending Dashboard UX Best Practices

### Research Findings

From industry research (Aave, Compound, DeFi Saver, Morpho dashboards):

**Critical DeFi UX elements that CreditGate lacks:**

| Element | Description | Priority | Effort |
|---------|-------------|----------|--------|
| **Loan Health Gauge** | Visual gauge (semicircular progress) showing health factor vs liquidation threshold. Aave shows `1.69` as a number; better UX uses a colored arc/gauge. | HIGH | ⭐⭐ |
| **Collateral Ratio Bar** | Horizontal bar showing current ratio vs required minimum (e.g., 150%). The "buffer" between current and liquidation is more intuitive than raw numbers. Alpaca calls this "Kill Buffer". | HIGH | ⭐⭐ |
| **Position Summary Card** | At-a-glance card showing total deposited, total borrowed, net value. Compound 3 does this well. | MEDIUM | ⭐⭐ |
| **Interest Rate Display** | Current borrow/supply APY. Not applicable to CreditGate (fixed-terms) but could show time-until-deadline instead. | LOW | — |
| **Timeline / Lifecycle** | Visual stepper showing: Deposit → Pending Eligibility → Eligible → Funded → Repayment Due → Closed. CreditGate has the state labels but no visual stepper. | HIGH | ⭐⭐ |
| **Warning Thresholds** | Proactive alerts when HF drops below 1.2 (approaching liquidation zone). DeFi Saver "Notify" feature. | MEDIUM | ⭐⭐ |

**Quick UX wins (trivial effort):**

1. **"Max" button** on deposit/loan amount inputs — fill with wallet balance. ~20 lines of code.
2. **Token icon + color** next to "FXRP" and "USDT0" labels — visual differentiation. Small SVGs or emoji.
3. **Deadline countdown** on active loans — already has `deadline` field, just needs a `<Countdown />` component.
4. **Copy address** button next to truncated vault/owner addresses (clipboard API).
5. **Explorer links** on every address shown (already exists on transparency page, add to loan cards).

### Top 5 Recommendations (Ranked)

1. **Loan Health Visualizer** — Replace text-only `HealthFactorBadge` with a semicircular gauge or colored progress bar. Show buffer to liquidation. This is the single highest-impact UX improvement. Effort: ⭐⭐
2. **Collateral Ratio Progress Bar** — Horizontal bar: `Current: 175% | Required: 150%` with fill color. Green when safe, yellow approaching threshold, red near liquidation. Effort: ⭐
3. **Lifecycle Stepper** — Visual progress stepper (Deposit → Eligibility → Funded → Repay → Closed) on each loan card. Replaces plain text state badges. Effort: ⭐⭐
4. **Skeleton Loading States** — Add `loading.tsx` per route + skeleton placeholders for all contract-read-backed UI sections. Critical for perceived performance. Effort: ⭐
5. **Toast Notifications** — Replace custom `useState`-based toasts with `react-hot-toast`. Adds toast.promise() for transaction lifecycle (pending → confirmed → failed). Effort: ⭐

---

## 2. wagmi v2 Hooks Patterns

### Current Usage Analysis

CreditGate uses wagmi v2 correctly in many places:
- `useReadContract` with `query: { enabled: !!address }` — proper conditional fetching ✅
- `useWriteContract` — separated per operation ✅
- `useWaitForTransactionReceipt` — tracking confirmations ✅
- `useSwitchChain` — network mismatch detection ✅

### Missing wagmi v2 Patterns

| Pattern | What It Does | Current Gap | Effort |
|---------|-------------|-------------|--------|
| `useSimulateContract` | Pre-flight simulation before write. Shows "This tx will fail" before wallet pop-up. | No simulation; user gets wallet rejection for failed txs. | ⭐⭐ |
| `useReadContracts` (batch) | Batch multiple reads into one RPC call. | `getBorrowerLoanIds` then loop `getLoan` per ID — N+1 problem. | ⭐⭐ |
| `useWatchContractEvent` | Real-time event listening for loan state changes. | No live updates; user must refresh. | ⭐⭐⭐ |
| `useBlockNumber` | Track chain head for freshness indicators. | No block number display; stale data is invisible. | ⭐ |
| `useToken` | Standard token metadata (symbol, decimals, name). | Hardcoded `formatUnits(x, 6)` and `formatUnits(x, 18)` instead of reading decimals. | ⭐ |
| `query: { refetchInterval }` | Already used for health factor (15s). Extend to loan list. | Loan cards only fetch once on mount. | ⭐ |

### Recommended wagmi Improvements

**Quick wins:**
1. **Batch loan reads** — Replace per-loan `getLoan` calls with `useReadContracts`:
   ```ts
   // Before: N calls (one per loan)
   borrowerLoanIds.map(id => useReadContract({ functionName: "getLoan", args: [id] }))
   // After: 1 batched call
   useReadContracts({
     contracts: borrowerLoanIds.map(id => ({ abi, address, functionName: "getLoan", args: [id] }))
   })
   ```
   Effort: ⭐⭐

2. **Add `refetchInterval: 30000`** to loan list reads — auto-refresh loan states without manual refresh. Effort: ⭐

3. **Add `useSimulateContract`** before `drawLoan`, `submitEligibility`, `bidOnLiquidation`. Shows simulation error before wallet popup. Effort: ⭐⭐

**Medium effort:**
4. **`useWatchContractEvent`** for `CollateralDeposited`, `LoanFunded`, `LoanClosed` events — live-update loan list. Effort: ⭐⭐⭐
5. **`useBlockNumber`** with block explorer link — shows chain freshness. Effort: ⭐

---

## 3. RainbowKit Customization

### Current State
- Only MetaMask configured (`metaMaskWallet` in `connectorsForWallets`)
- No theming applied (uses RainbowKit defaults)
- No `customTheme`, no `customWalletList` grouping
- No `ConnectButton` customization

### RainbowKit UX Improvements

| Improvement | Description | Effort |
|-------------|-------------|--------|
| **Add more wallets** | Add `walletConnectWallet`, `injectedWallet` as fallback. Users without MetaMask see nothing useful. | ⭐ |
| **Custom theme with brand colors** | Use `lightTheme()` or `darkTheme()` + accent color matching CreditGate's blue-purple gradient. | ⭐ |
| **Compact modal size** | Use `<RainbowKitProvider modalSize="compact">` for less screen takeover on mobile. | ⭐ |
| **Show chain badge** | Display current chain name next to address — reminds users they're on Coston2. | ⭐ |
| **Custom `appInfo`** | Set `appName: "CreditGate"` and `learnMoreUrl` to docs page. Currently uses demo projectId. | ⭐ |

### Recommended Provider Config Changes

```tsx
// providers.tsx improvements:
const connectors = connectorsForWallets(
  [
    {
      groupName: "Recommended",
      wallets: [metaMaskWallet, walletConnectWallet],
    },
  ],
  {
    appName: "CreditGate",
    projectId: process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID || "creditgate-demo",
  }
);

// Theme (optional — quick visual polish):
const theme = darkTheme({
  accentColor: '#6366f1',  // indigo-500 to match brand
  accentColorForeground: 'white',
  borderRadius: 'medium',
  fontStack: 'system',
});
```
Effort: ⭐ (10-15 minutes)

---

## 4. Next.js App Router Patterns (2025)

### Current State
- Uses App Router (`src/app/`) ✅
- **No** `loading.tsx`, `error.tsx`, or `not-found.tsx` anywhere ❌
- Every page is `"use client"` — zero Server Component usage ❌
- No streaming / Suspense boundaries
- No `next/image` usage
- No `generateMetadata` per page (only root layout has metadata)
- No API routes or Server Actions

### Critical Missing Patterns

| Pattern | Impact | Effort |
|---------|--------|--------|
| **`loading.tsx` per route** | Shows skeleton on navigation. Currently blank white flash. | ⭐ |
| **`error.tsx` per route** | Graceful error boundaries. Currently shows Next.js default error. | ⭐ |
| **`not-found.tsx`** | Custom 404 page. Currently default Next.js 404. | ⭐ |
| **Route-level metadata** | `generateMetadata()` per page for SEO (OG images, per-page titles). | ⭐ |
| **`next/image`** | Optimized images. Currently zero images used. | ⭐ |
| **Streaming with Suspense** | Show static content immediately while dynamic parts load. | ⭐⭐ |
| **`loading.tsx` skeleton design** | Skeleton that matches actual layout shape. | ⭐⭐ |

### Recommended Implementation

**Immediate (5 minutes each):**
1. Create `src/app/loading.tsx` — global loading skeleton
2. Create `src/app/error.tsx` — "use client" error boundary with retry
3. Create `src/app/not-found.tsx` — custom 404
4. Create `src/app/app/loading.tsx` — app-specific skeleton
5. Create `src/app/transparency/loading.tsx` — transparency skeleton

**Skeleton Design Pattern:**
```tsx
// src/app/app/loading.tsx
export default function AppLoading() {
  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <div className="container mx-auto px-4 py-8">
        <div className="flex justify-between items-center mb-8">
          <div className="h-8 w-48 bg-gray-800 rounded animate-pulse" />
          <div className="h-10 w-36 bg-gray-800 rounded animate-pulse" />
        </div>
        {/* Skeleton for balance cards, action panels, loan cards */}
        <div className="max-w-4xl mx-auto space-y-4">
          {[1, 2, 3].map(i => (
            <div key={i} className="h-32 bg-gray-900 rounded-lg border border-gray-700 animate-pulse" />
          ))}
        </div>
      </div>
    </main>
  );
}
```

**Streaming Optimization:**
Move `Providers` wrapping and read heavy data-fetching into Server Components where possible. The landing page (`/`) has no wallet interaction — it could be a pure Server Component. The docs pages could use Server Components with `react-server` for faster initial paint.

---

## 5. DeFi Portfolio Tracker UX

### Research from Top Protocols

| Protocol | UX Pattern | CreditGate Equivalent |
|----------|------------|----------------------|
| **Aave** | Health Factor gauge (semicircular), position summary card, "What if?" simulator | `HealthFactorBadge` exists but is text-only |
| **Compound 3** | Portfolio overview with total collateral value, borrow limit, utilization bar | No portfolio summary |
| **DeFi Saver** | Recipe Creator, Loan Shifter, Notify alerts, automation triggers | No equivalent tools |
| **Morpho** | Grid-based dashboard, modular cards, live stats | Similar card layout, no grid |
| **Alpaca** | "Kill Buffer" visualization — inverted progress bar showing distance to liquidation | No equivalent |
| **De.Fi** | Multi-chain portfolio tracker, security scoring | N/A (CreditGate is single-chain) |

### Missing Dashboard Elements

**HIGH PRIORITY (Hackathon Impact):**

1. **Collateral Ratio Visualizer**
   - Horizontal bar: `Current: 175% ████████████░░ Required: 150%`
   - Color: Green (>170%), Yellow (150-170%), Red (<150%)
   - Add "Buffer: 25%" label
   - Effort: ⭐

2. **Position Summary Card**
   ```
   ┌─────────────────────────────────┐
   │  Total Deposited: 500.00 FXRP   │
   │  Total Borrowed:  420.00 USDT0  │
   │  Net Position:    +$80.00 USD   │
   │  Active Loans:    2              │
   │  Deadline Nearest: 3d 14h       │
   └─────────────────────────────────┘
   ```
   Effort: ⭐⭐

3. **Loan Lifecycle Stepper**
   ```
   ● Deposit  →  ● Eligibility  →  ● Funded  →  ○ Repay  →  ○ Closed
                    [current]
   ```
   Color-coded: completed (green), current (blue pulse), pending (gray)
   Effort: ⭐⭐

4. **Deadline Countdown**
   - Live countdown timer on active loans (FUNDED state)
   - Warning color when < 24h remaining
   - Already has `deadline` field in loan struct
   - Effort: ⭐

**MEDIUM PRIORITY:**

5. **Transaction Activity Feed**
   - List recent contract events for the connected wallet
   - "You deposited 100 FXRP" / "Loan #3 funded with 420 USDT0"
   - Uses `useWatchContractEvent` or polling
   - Effort: ⭐⭐⭐

6. **USD Value Estimates**
   - Show USD values next to token amounts using FTSO price feed
   - "500 FXRP (~$1,050)" — requires reading XRP/USD from FTSO
   - Effort: ⭐⭐

7. **Warning System**
   - Persistent banner when any loan's HF < 1.2
   - Countdown warning when deadline < 48h
   - Effort: ⭐⭐

**LOW PRIORITY (Post-Hackathon):**

8. Multi-loan comparison table
9. Export loan history (CSV)
10. Dark/light mode toggle
11. Language localization

---

## 6. Loading States, Error Handling, Toast Notifications

### Current State

| Aspect | Current Implementation | Issue |
|--------|----------------------|-------|
| **Page loading** | None — blank screen during navigation | No `loading.tsx` |
| **Contract reads** | `undefined` while loading | No skeleton/spinner |
| **Transaction pending** | Manual `isConfirming` banner | Works but ad-hoc |
| **Transaction success** | Manual `useState` toast with 8s timeout | No dismiss, no queue, no animation |
| **Transaction error** | Manual banner with `txError.message` | Raw error text shown to user |
| **Network mismatch** | Custom banner with switch button | Good, could use RainbowKit |
| **Form validation** | Client-side FCC JSON validation | Good |

### Recommended Improvements

#### Toast System (High Impact, Low Effort)

Replace manual `useState`-based toasts with `react-hot-toast`:

```bash
pnpm add react-hot-toast
```

```tsx
// In layout.tsx — add once:
import { Toaster } from 'react-hot-toast';
<Toaster position="top-right" toastOptions={{
  style: { background: '#1f2937', color: '#f9fafb', border: '1px solid #374151' },
}} />
```

```tsx
// In app/page.tsx — replace manual toast:
import toast from 'react-hot-toast';

// Before: manual useState + useEffect + setTimeout
// After: one line
toast.success('Transaction confirmed!', { duration: 5000 });

// For transaction lifecycle:
const txPromise = writeContractAsync({ ... });
toast.promise(txPromise, {
  loading: 'Transaction pending...',
  success: 'Transaction confirmed!',
  error: 'Transaction failed',
});
```

**Benefits:**
- Animated entry/exit
- Stacks multiple toasts
- Pause on hover
- Dismissible
- Promise API for tx lifecycle

Effort: ⭐ (30 minutes)

#### Skeleton Loading States

**Pattern for contract-read sections:**

```tsx
function BalanceCard({ balance, isLoading }: { balance: string; isLoading: boolean }) {
  if (isLoading) {
    return (
      <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 animate-pulse">
        <div className="h-3 w-20 bg-gray-700 rounded mb-2" />
        <div className="h-6 w-28 bg-gray-700 rounded" />
      </div>
    );
  }
  return (/* actual content */);
}
```

**Places to add skeletons:**
1. Balance cards (`fxrpBalance`, `usdt0Balance`)
2. Loan cards (while `getLoan` is fetching)
3. Vault status on transparency page
4. Health factor badge (while loading)

Effort: ⭐⭐ (1-2 hours)

#### Error Handling Improvements

| Current | Improved | Effort |
|---------|----------|--------|
| Raw `error.message` displayed | Parse common errors into friendly messages: "Insufficient funds", "Transaction rejected by user", "Network error — try again" | ⭐ |
| Single `txError` state for all operations | Track errors per-operation with clear/reset | ⭐ |
| No retry mechanism | Add "Retry" button on error banners | ⭐ |
| No error boundary | `error.tsx` per route | ⭐ |

**Friendly error parsing:**
```tsx
function friendlyError(error: Error): string {
  const msg = error.message.toLowerCase();
  if (msg.includes('user rejected') || msg.includes('user denied')) return 'Transaction cancelled by user.';
  if (msg.includes('insufficient funds')) return 'Insufficient C2FLR for gas. Top up your wallet.';
  if (msg.includes('network') || msg.includes('timeout')) return 'Network error — please try again.';
  if (msg.includes('already known')) return 'Transaction already pending — check your wallet.';
  return 'Something went wrong. Check console for details.';
}
```

---

## 7. Mobile Responsiveness Gaps

### Current State

| Component | Mobile Status | Issue |
|-----------|--------------|-------|
| Landing page | ✅ `flex-col md:flex-row` | Works |
| App page grid | ✅ `grid-cols-1 md:grid-cols-2` | Works |
| Balance cards | ⚠️ `grid-cols-2` | Cramped on small screens, no stacking |
| Docs layout | ❌ Fixed `w-56` sidebar | Sidebar takes 224px, content squeezes |
| XRPL binding panel | ⚠️ `md:col-span-2` | Stacks ok but button wraps awkwardly |
| Loan cards | ⚠️ `flex justify-between` | Text overflows on narrow screens |
| Auction panel | ⚠️ `grid-cols-2` | Cramped on mobile |
| All inputs | ⚠️ No `inputMode`, no `autoComplete` | Keyboard UX on mobile |

### Quick Mobile Fixes

| Fix | Description | Effort |
|-----|-------------|--------|
| **Docs: collapsible sidebar** | Add hamburger menu for docs nav on mobile | ⭐⭐ |
| **Balance cards: stack on mobile** | `grid-cols-1 sm:grid-cols-2` | ⭐ |
| **Loan card: stack on mobile** | `flex-col sm:flex-row` for header | ⭐ |
| **XRPL input: full width on mobile** | Already works but button could stack | ⭐ |
| **Touch-friendly buttons** | Min 44px tap target height on all buttons | ⭐ |
| **Number inputs: `inputMode="decimal"`** | Shows numeric keyboard on mobile | ⭐ |
| **Scale font down on mobile** | `text-5xl sm:text-3xl` for hero title | ⭐ |

---

## 8. Implementation Priority Matrix

### Phase 1 — Quick Wins (1-2 hours, hackathon polish)

| # | Task | Effort | Impact |
|---|------|--------|--------|
| 1 | Add `react-hot-toast` + `<Toaster />` | ⭐ | HIGH |
| 2 | Create `loading.tsx` for all routes | ⭐ | HIGH |
| 3 | Create `error.tsx` for all routes | ⭐ | MEDIUM |
| 4 | Create `not-found.tsx` | ⭐ | LOW |
| 5 | RainbowKit: add WalletConnect wallet + theme | ⭐ | MEDIUM |
| 6 | "Max" button on deposit/loan inputs | ⭐ | HIGH |
| 7 | Friendly error message parsing | ⭐ | MEDIUM |
| 8 | Add `refetchInterval: 30000` to loan reads | ⭐ | MEDIUM |
| 9 | Deadline countdown on active loans | ⭐ | HIGH |
| 10 | Skeleton loading for balance/loan cards | ⭐⭐ | HIGH |

### Phase 2 — Core UX (4-6 hours, competitive differentiation)

| # | Task | Effort | Impact |
|---|------|--------|--------|
| 11 | Loan health gauge (semicircular progress) | ⭐⭐ | HIGH |
| 12 | Collateral ratio progress bar | ⭐ | HIGH |
| 13 | Loan lifecycle stepper component | ⭐⭐ | HIGH |
| 14 | Position summary card | ⭐⭐ | MEDIUM |
| 15 | Batch `useReadContracts` for loan reads | ⭐⭐ | MEDIUM |
| 16 | Mobile docs sidebar (hamburger) | ⭐⭐ | MEDIUM |
| 17 | Route-level `generateMetadata` | ⭐ | LOW |

### Phase 3 — Advanced (post-hackathon, production polish)

| # | Task | Effort | Impact |
|---|------|--------|--------|
| 18 | `useSimulateContract` pre-flight | ⭐⭐ | HIGH |
| 19 | `useWatchContractEvent` live updates | ⭐⭐⭐ | MEDIUM |
| 20 | Transaction activity feed | ⭐⭐⭐ | MEDIUM |
| 21 | USD value estimates via FTSO | ⭐⭐ | MEDIUM |
| 22 | Warning system (HF < 1.2, deadline < 48h) | ⭐⭐ | HIGH |
| 23 | Server Components where possible | ⭐⭐⭐ | MEDIUM |
| 24 | `next/image` for any visual assets | ⭐ | LOW |

---

## 9. Recommended File Changes (No Code, Just Locations)

| File | Change |
|------|--------|
| `src/app/layout.tsx` | Add `<Toaster />`, favicon, OG metadata |
| `src/app/loading.tsx` | **NEW** — global loading skeleton |
| `src/app/error.tsx` | **NEW** — global error boundary |
| `src/app/not-found.tsx` | **NEW** — custom 404 |
| `src/app/app/page.tsx` | Toast integration, "Max" buttons, friendly errors, skeletons, health gauge, lifecycle stepper, deadline countdown |
| `src/app/transparency/page.tsx` | Skeleton loading, generateMetadata |
| `src/app/transparency/loading.tsx` | **NEW** — transparency skeleton |
| `src/app/app/loading.tsx` | **NEW** — app skeleton |
| `src/app/providers.tsx` | RainbowKit theme, add WalletConnect wallet |
| `src/app/docs/DocsLayout.tsx` | Mobile responsive sidebar (hamburger) |
| `src/components/HealthGauge.tsx` | **NEW** — semicircular health factor gauge |
| `src/components/CollateralBar.tsx` | **NEW** — collateral ratio progress bar |
| `src/components/LifecycleStepper.tsx` | **NEW** — loan state progress stepper |
| `src/components/Countdown.tsx` | **NEW** — deadline countdown timer |
| `src/components/SkeletonCard.tsx` | **NEW** — reusable skeleton placeholder |
| `src/lib/errors.ts` | **NEW** — error message parsing utility |
| `tailwind.config.js` | **NEW** — extend theme with brand colors |
| `package.json` | Add `react-hot-toast` |

---

## 10. Competitive Positioning (Hackathon Judging)

CreditGate's frontend is **functional but developer-oriented**. For hackathon judging, the top 3 improvements that would stand out:

1. **Loan Health Gauge** — Judges immediately see "this is a real DeFi dashboard" when they see a visual health indicator, not just text badges.
2. **Toast Notifications** — Smooth transaction lifecycle feedback (pending → confirmed → error) makes the demo feel polished and professional.
3. **Skeleton Loading** — Eliminates blank screens during navigation, making the app feel fast even on slow RPC.

These three improvements together would take ~3-4 hours and dramatically change the perceived quality of the frontend.

---

*End of research. No code changes made.*
