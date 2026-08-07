"use client";

import { useState, useEffect } from "react";
import { useReadContract } from "wagmi";
import { formatUnits } from "viem";
import { CREDIT_GATE_CONFIG, isCreditScoreSbtConfigured } from "@/config/contract";
import { CREDIT_SCORE_SBT_ABI } from "@/lib/abi";

/**
 * CreditScoreSBTBadge — circular SVG credit-score ring with a soulbound
 * indicator and a score-breakdown table. Added by subagent #103 for the
 * transparency page so a judge can look up any borrower's on-chain credit
 * passport at a glance.
 *
 * Source contract: `src/CreditScoreSBT.sol` — soulbound (non-transferable
 * ERC721) deployed by CreditGateVault's constructor. The badge reads
 * `getScore(address)`, which returns all-zero fields if the borrower has not
 * yet repaid their first loan (no SBT minted) and reverts if the SBT contract
 * itself is not configured (deployed). We handle both cases gracefully:
 *
 *   - `isCreditScoreSbtConfigured === false` → "Not yet deployed on Coston2"
 *     empty state. The SBT was added to the source after the live vault
 *     deployment, so until a redeploy the on-chain address is unknown.
 *   - Borrower has no SBT (addressToTokenId == 0, all-zero tuple) → "No SBT
 *     minted — earn it by closing your first loan via FDC repayment."
 *
 * Color coding mirrors the spec (0–39 red, 40–69 yellow, 70–100 green). The
 * SVG progress ring is built from a circular path with a stroke-dasharray that
 * fills proportionally to `score / 100`. We animate the fill with CSS so it
 * smoothly transitions between scores rather than snapping when a new loan
 * closes.
 *
 * Soulbound indicator shows a locked padlock and "Non-transferable" — derived
 * from the contract's `_update` hook that reverts every move between two live
 * addresses (only mint / burn allowed).
 */
interface CreditScoreSBTBadgeProps {
  /** Borrower whose on-chain SBT credit score to render. */
  address: `0x${string}`;
}

// Score thresholds — must agree with the spec and the contract's 0-100 range.
const SCORE_MIN = 0;
const SCORE_MAX = 100;

// Visual constants for the circular SVG progress ring.
const RING_RADIUS = 70;
const RING_CIRCUMFERENCE = 2 * Math.PI * RING_RADIUS; // ≈ 439.82
const RING_VIEWBOX = 200; // viewBox is 200×200, centre at (100, 100)

/**
 * Bucket a 0-100 score into its color zone.
 *   0–39  → red    (#ef4444)  poor credit
 *   40–69 → yellow (#eab308)  fair credit
 *   70-100→ green  (#22c55e)  good credit
 * Strings are returned as raw hex so we can pass them straight to SVG `stroke`
 * without Tailwind class indirection (SVG attributes can't react to Tailwind
 * JIT classes the same way DOM className can).
 */
function scoreToColor(score: number): string {
  if (score >= 70) return "#22c55e"; // green
  if (score >= 40) return "#eab308"; // yellow
  return "#ef4444"; // red
}

/**
 * Short human label for the score band. Surfaced under the ring so the
 * numeric value carries an implicit semantic ("Good / Fair / Poor").
 */
function scoreLabel(score: number): string {
  if (score >= 70) return "Good";
  if (score >= 40) return "Fair";
  return "Poor";
}

export function CreditScoreSBTBadge({ address }: CreditScoreSBTBadgeProps) {
  const sbtAddress = CREDIT_GATE_CONFIG.contracts.creditScoreSBT as `0x${string}`;

  // ── Single read: getScore(address) returns the 6-tuple. ──────────────
  // We enable the query only when the SBT contract is configured (non-zero
  // address). The `as const` ABI keeps the return shape typed, so `data`
  // comes back as `[score, loansCompleted, loansDefaulted, totalBorrowed,
  // totalRepaid, lastUpdated] | undefined`.
  const { data, isError, isLoading } = useReadContract({
    address: sbtAddress,
    abi: CREDIT_SCORE_SBT_ABI,
    functionName: "getScore",
    args: [address],
    query: { enabled: isCreditScoreSbtConfigured && !!address },
  });

  // Destructure defensively — viem returns a tuple; undefined means loading
  // or a not-yet-broadcast query (e.g. SBT unconfigured).
  const score = data ? Number((data as readonly unknown[])[0]) : 0;
  const loansCompleted = data ? Number((data as readonly unknown[])[1]) : 0;
  const loansDefaulted = data ? Number((data as readonly unknown[])[2]) : 0;
  const totalBorrowedRaw = data ? ((data as readonly unknown[])[3] as bigint) : 0n;
  const totalRepaidRaw = data ? ((data as readonly unknown[])[4] as bigint) : 0n;
  const lastUpdatedRaw = data ? Number((data as readonly unknown[])[5]) : 0;

  // "Has SBT" — the contract returns (0,0,0,0,0,0) for borrowers with no
  // SBT. We can't distinguish "no SBT" from "real score 0 + never borrowed"
  // purely from getScore, so we treat lastUpdated == 0 as the "never minted"
  // sentinel — lastUpdated is only zero if mintOrUpdate was never called
  // (block.timestamp is always ≥ 1 on live chains). This is also exactly how
  // the contract's own ZeroAddress branch returns (see line 149 of the .sol).
  const hasSBT = isCreditScoreSbtConfigured && !isError && lastUpdatedRaw > 0;

  // Animate the ring fill fraction. We keep this separate from the raw score
  // so the color flips instantly when a new score comes in, while the ring
  // animates from its old fill height to the new one over ~700ms.
  const targetFraction = hasSBT
    ? Math.min(1, Math.max(0, (score - SCORE_MIN) / (SCORE_MAX - SCORE_MIN)))
    : 0;
  const [animatedFraction, setAnimatedFraction] = useState(0);
  useEffect(() => {
    setAnimatedFraction(targetFraction);
  }, [targetFraction]);

  const strokeColor = hasSBT ? scoreToColor(score) : "#6b7280"; // gray-500
  const ringFilled = RING_CIRCUMFERENCE * animatedFraction;
  const ringOffset = RING_CIRCUMFERENCE - ringFilled;

  // ── Empty states ─────────────────────────────────────────────────────
  if (!isCreditScoreSbtConfigured) {
    return <NotYetDeployedNotice />;
  }
  if (isLoading) {
    return <LoadingState />;
  }
  if (isError) {
    // Rare: getScore reverts. Should only happen if the env-supplied SBT
    // address points at a non-SBT contract. Surface it honestly.
    return <ErrorState />;
  }
  if (!hasSBT) {
    return <NoSBTState address={address} />;
  }

  // ── Happy path — render the ring + breakdown + soulbound pill. ────────
  return (
    <>
      {/* Soulbound pill — pinned to the right of the ring/breakdown grid so
          judges always see the non-transferable indicator regardless of
          scroll position. */}
      <div className="flex justify-end mb-4">
        <SoulboundPill />
      </div>
      <div className="grid grid-cols-1 md:grid-cols-2 gap-8 items-center">
        {/* Circular SVG score ring */}
        <div className="flex flex-col items-center justify-center">
          <svg
            viewBox={`0 0 ${RING_VIEWBOX} ${RING_VIEWBOX}`}
            className="w-full max-w-[240px]"
            role="img"
            aria-label={`Credit score ${score} of 100, ${scoreLabel(score)}`}
          >
            {/* Background track */}
            <circle
              cx={100}
              cy={100}
              r={RING_RADIUS}
              fill="none"
              stroke="#374151"
              strokeWidth={14}
            />
            {/* Filled portion — rotates -90° so the fill starts at 12 o'clock */}
            <circle
              cx={100}
              cy={100}
              r={RING_RADIUS}
              fill="none"
              stroke={strokeColor}
              strokeWidth={14}
              strokeLinecap="round"
              strokeDasharray={RING_CIRCUMFERENCE}
              strokeDashoffset={ringOffset}
              transform="rotate(-90 100 100)"
              style={{
                transition:
                  "stroke-dashoffset 700ms ease-out, stroke 300ms ease",
              }}
            />
            {/* Score number centred in the ring */}
            <text
              x={100}
              y={94}
              textAnchor="middle"
              fill="currentColor"
              className={`text-white text-5xl`}
              style={{ fontWeight: 700, fontSize: "44px" }}
            >
              {score}
            </text>
            <text
              x={100}
              y={120}
              textAnchor="middle"
              fill={strokeColor}
              style={{ fontSize: "14px", fontWeight: 600 }}
            >
              {scoreLabel(score)}
            </text>
            <text
              x={100}
              y={138}
              textAnchor="middle"
              fill="#9ca3af"
              style={{ fontSize: "11px", letterSpacing: "0.08em" }}
            >
              / 100
            </text>
          </svg>
          <div className="mt-2 text-xs text-gray-400 uppercase tracking-wide">
            Credit Score
          </div>
          <div className="mt-1 flex items-center gap-1.5 text-xs text-gray-300">
            <LockIcon className="w-3.5 h-3.5" />
            <span className="font-semibold">Soulbound</span>
            <span className="text-gray-500">· Non-transferable</span>
          </div>
        </div>

        {/* Score breakdown table */}
        <div>
          <h3 className="text-sm font-semibold text-gray-300 uppercase tracking-wide mb-3">
            Score Breakdown
          </h3>
          <div className="overflow-hidden rounded-lg border border-gray-700">
            <table className="w-full text-sm">
              <tbody className="divide-y divide-gray-800">
                <BreakdownRow label="Loans Completed" value={loansCompleted.toString()} good />
                <BreakdownRow
                  label="Loans Defaulted"
                  value={loansDefaulted.toString()}
                  bad={loansDefaulted > 0}
                />
                <BreakdownRow
                  label="Total Borrowed"
                  value={`${formatUnits(totalBorrowedRaw, 18)} USDT0`}
                />
                <BreakdownRow
                  label="Total Repaid"
                  value={`${formatUnits(totalRepaidRaw, 18)} USDT0`}
                />
                <BreakdownRow
                  label="Last Updated"
                  value={
                    lastUpdatedRaw > 0
                      ? new Date(lastUpdatedRaw * 1000).toLocaleString()
                      : "—"
                  }
                />
              </tbody>
            </table>
          </div>

          {/* Repayment ratio — quick at-a-glance credit signal */}
          <div className="mt-3 text-xs text-gray-400">
            Repayment ratio:{" "}
            <strong className="text-white">
              {totalBorrowedRaw > 0n
                ? `${(
                    (Number(totalRepaidRaw) / Number(totalBorrowedRaw)) *
                    100
                  ).toFixed(1)}%`
                : "—"}
            </strong>
          </div>
        </div>
      </div>
    </>
  );
}

// ════════════════════ Sub-components ════════════════════

function SoulboundPill() {
  return (
    <div
      className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-gray-800 border border-gray-700 text-xs font-semibold text-gray-200"
      title="This SBT is non-transferable. The contract's _update hook reverts every transfer between live addresses; only mint (from=0) and burn (to=0) are permitted."
    >
      <LockIcon className="w-3 h-3" />
      <span>Non-transferable</span>
    </div>
  );
}

function BreakdownRow({
  label,
  value,
  good,
  bad,
}: {
  label: string;
  value: string;
  good?: boolean;
  bad?: boolean;
}) {
  const valueColor = good
    ? "text-green-400"
    : bad
    ? "text-red-400"
    : "text-white";
  return (
    <tr>
      <td className="px-3 py-2 text-gray-400 bg-gray-950/40">{label}</td>
      <td className={`px-3 py-2 text-right font-semibold ${valueColor}`}>
        {value}
      </td>
    </tr>
  );
}

function LockIcon({ className }: { className?: string }) {
  // Inline SVG padlock — kept tiny and self-contained so the component never
  // reaches for an icon library dependency.
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      className={className}
      aria-hidden="true"
    >
      <path
        fillRule="evenodd"
        d="M10 1a4 4 0 0 0-4 4v2H5a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-1V5a4 4 0 0 0-4-4Zm2 6V5a2 2 0 1 0-4 0v2h4Z"
        clipRule="evenodd"
      />
    </svg>
  );
}

// ────────────────────── Empty states ──────────────────────

function NotYetDeployedNotice() {
  return (
    <div className="flex items-start gap-3 text-sm text-gray-300 bg-gray-950/60 border border-gray-800 rounded-md p-4">
      <span className="text-yellow-400 text-lg leading-none">⚠</span>
      <div>
        <div className="font-semibold text-yellow-300">SBT not yet deployed on Coston2</div>
        <p className="mt-1 text-gray-400">
          The <code className="text-gray-300">CreditScoreSBT</code> contract 
          ({" "}subagent #98{" "}— soulbound credit passport, ERC721) is in
          the source tree but the live Coston2 vault predates it. The SBT is
          deployed by the vault constructor, so its address is only known
          after a redeploy. Set{" "}
          <code className="text-gray-300">
            NEXT_PUBLIC_CREDIT_SCORE_SBT_ADDRESS
          </code>{" "}
          once redeployed and the badge activates automatically.
        </p>
      </div>
    </div>
  );
}

function LoadingState() {
  return (
    <div className="flex flex-col items-center py-10 text-gray-500 text-sm">
      <div className="w-12 h-12 rounded-full border-2 border-gray-700 border-t-gray-400 animate-spin mb-3" />
      Loading borrower's credit score from the SBT…
    </div>
  );
}

function ErrorState() {
  return (
    <div className="flex items-start gap-3 text-sm text-red-300 bg-red-950/40 border border-red-900 rounded-md p-4">
      <span className="text-red-400 text-lg leading-none">■</span>
      <div>
        <div className="font-semibold text-red-200">getScore reverted</div>
        <p className="mt-1 text-red-300/80">
          The CreditScoreSBT contract is configured but{" "}
          <code>getScore(address)</code> reverted. Check that{" "}
          <code>NEXT_PUBLIC_CREDIT_SCORE_SBT_ADDRESS</code> points at a deployed
          CreditScoreSBT, not another contract.
        </p>
      </div>
    </div>
  );
}

function NoSBTState({ address }: { address: `0x${string}` }) {
  return (
    <div className="flex flex-col items-center py-8 text-center">
      {/* Greyed-out ring placeholder — visual continuity with the populated state */}
      <svg
        viewBox={`0 0 ${RING_VIEWBOX} ${RING_VIEWBOX}`}
        className="w-full max-w-[180px] opacity-40"
        role="img"
        aria-label="No Credit Score SBT minted"
      >
        <circle cx={100} cy={100} r={RING_RADIUS} fill="none" stroke="#374151" strokeWidth={14} />
        <text x={100} y={106} textAnchor="middle" fill="#9ca3af" style={{ fontWeight: 700, fontSize: "40px" }}>
          —
        </text>
      </svg>
      <div className="mt-3 text-gray-300 text-sm">
        No Credit Score SBT minted for{" "}
        <code className="text-gray-200 font-mono">
          {address.slice(0, 6)}…{address.slice(-4)}
        </code>
      </div>
      <p className="mt-1 text-xs text-gray-500 max-w-md">
        The SBT is minted automatically on the first successful loan close via
        a verified FDC repayment proof. Repay a loan to earn your on-chain
        credit passport.
      </p>
    </div>
  );
}
