"use client";

import { useState, useEffect } from "react";

/**
 * CollateralCoverageBar — horizontal bar showing borrowed amount vs
 * collateral value, animated based on the LTV (loan-to-value) ratio.
 *
 * Visualizes how much of the deposited collateral has been lent out:
 *   - Low utilization (bar mostly empty) → healthy, lots of reserve
 *   - High utilization (bar nearly full) → approach operation limits
 *
 * Color follows the LTV against the required coverage ratio:
 *   - Green  when utilization ≤ 60% of required coverage
 *   - Yellow when 60%–90% (buffering zone)
 *   - Red    when ≥ 90%  (collateral critically consumed)
 */
interface CollateralCoverageBarProps {
  /** Borrowed USDT0 amount (scaled 1e18) as a number, or `undefined` while loading. */
  borrowed: bigint | undefined;
  /** Collateral value in USDT0 terms (scaled 1e18) for ratio, or undefined. */
  collateralValue: bigint | undefined;
  /** Required collateral coverage ratio (e.g. 1.5 = 150%). Optional — used to draw the "required" tick. */
  requiredCoverage?: number;
}

export function CollateralCoverageBar({
  borrowed,
  collateralValue,
  requiredCoverage = 1.5,
}: CollateralCoverageBarProps) {
  // LTV ratio = borrowed / collateral. When collateralValue is 0/undefined
  // we can't compute — show empty / loading.
  const ltv =
    borrowed == null || collateralValue == null || collateralValue === 0n
      ? 0
      : Number(borrowed) / Number(collateralValue);

  // Animate the bar fill smoothly between LTV updates.
  const [animatedLtv, setAnimatedLtv] = useState(0);
  useEffect(() => {
    setAnimatedLtv(ltv);
  }, [ltv]);

  // Bar visualizes LTV up to 2.0 (200% utilized = full bar).
  const MAX_LTV_DISPLAY = 2.0;
  const fillFraction = Math.min(1, animatedLtv / MAX_LTV_DISPLAY);

  // Required marker at requiredCoverage/MAX_LTV_DISPLAY.
  const requiredMarkerFraction =
    requiredCoverage / MAX_LTV_DISPLAY; // e.g. 1.5/2.0 = 0.75

  // Color: green / yellow / red based on distance to requiredCoverage margin.
  let barColor = "#4ade80"; // green-400 default
  if (animatedLtv >= requiredCoverage) {
    barColor = "#f87171"; // red-400
  } else if (animatedLtv >= 0.6 * requiredCoverage) {
    barColor = "#facc15"; // yellow-400
  }

  const borrowedStr = borrowed == null
    ? "—"
    : (Number(borrowed) / 1e18).toLocaleString(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      });
  const collateralStr = collateralValue == null
    ? "—"
    : (Number(collateralValue) / 1e18).toLocaleString(undefined, {
        minimumFractionDigits: 2,
        maximumFractionDigits: 2,
      });

  return (
    <div className="space-y-3">
      <div className="flex justify-between items-baseline text-sm">
        <div>
          <span className="text-gray-400">Borrowed: </span>
          <span className="font-semibold text-white">{borrowedStr} USDT0</span>
        </div>
        <div>
          <span className="text-gray-400">Collateral: </span>
          <span className="font-semibold text-white">{collateralStr} USDT0</span>
        </div>
      </div>
      <div
        className="relative h-8 w-full bg-gray-800 rounded-full overflow-hidden border border-gray-700"
        role="img"
        aria-label={`Loan-to-value ratio: ${(animatedLtv * 100).toFixed(1)}%. Required coverage: ${(requiredCoverage * 100).toFixed(0)}%`}
      >
        {/* Filled portion — smooth transition */}
        <div
          className="absolute inset-y-0 left-0 rounded-full"
          style={{
            width: `${fillFraction * 100}%`,
            backgroundColor: barColor,
            transition: "width 700ms ease-out, background-color 300ms ease",
          }}
        />
        {/* Required marker */}
        <div
          className="absolute inset-y-0 w-0.5 bg-white/70"
          style={{ left: `${requiredMarkerFraction * 100}%` }}
          aria-hidden="true"
        />
      </div>
      <div className="flex justify-between text-xs text-gray-500">
        <span>LTV: <span className="font-semibold text-gray-300">{(animatedLtv * 100).toFixed(1)}%</span></span>
        <span>Required ≥ {(requiredCoverage * 100).toFixed(0)}% coverage</span>
      </div>
    </div>
  );
}
