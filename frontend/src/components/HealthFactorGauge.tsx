"use client";

import { useState, useEffect } from "react";

/**
 * HealthFactorGauge — semicircular gauge that shows the protocol health factor
 * against the liquidation threshold (1.0).
 *
 * Color zones (matches Aave/Compound conventions and discovery-82 research):
 *   - HF > 1.5   → green (safe)
 *   - HF 1.0–1.5 → yellow (warning, approaching liquidation)
 *   - HF < 1.0   → red   (liquidatable)
 *
 * The gauge is a 180° semicircular arc rendered with an SVG stroke-dasharray
 * that smoothly transitions between values via CSS transition on the
 * stroke-dashoffset property. When the underlying health factor is still
 * loading (undefined) a neutral gray "—" is shown.
 */
interface HealthFactorGaugeProps {
  /** Protocol-wide health factor, or `undefined` while loading. */
  healthFactor: number | undefined;
  /** Liquidation threshold; default 1.0 — the point at which HF is "red". */
  liquidationThreshold?: number;
}

const ARC_DEGREES = 180;
const ARC_RADIUS = 70;
// circumference of a semicircle of radius 70: π·r = π·70 ≈ 219.91
const ARC_CIRCUMFERENCE = Math.PI * ARC_RADIUS;

export function HealthFactorGauge({
  healthFactor,
  liquidationThreshold = 1.0,
}: HealthFactorGaugeProps) {
  // Normalize a health factor onto the 0–1 fraction of the arc.
  // We cap the visualization at HF = 3.0 (anything above is "fully healthy"
  // — the bar fills the whole arc) so the gauge stays readable.
  const MAX_HF_DISPLAY = 3.0;
  const fraction =
    healthFactor == null
      ? 0
      : Math.min(1, Math.max(0, healthFactor / MAX_HF_DISPLAY));

  // Smooth between rendered fraction so the needle/bar animates rather than
  // snaps when the underlying value updates from the chain.
  const [animatedFraction, setAnimatedFraction] = useState(0);
  useEffect(() => {
    setAnimatedFraction(fraction);
  }, [fraction]);

  // Derive the color zone from the raw (un-animated) value so the color flips
  // the moment the new value comes in, not when the animation settles.
  const color =
    healthFactor == null
      ? "text-gray-500"
      : healthFactor < liquidationThreshold
      ? "text-red-400"
      : healthFactor < 1.5
      ? "text-yellow-400"
      : "text-green-400";

  const strokeColor =
    healthFactor == null
      ? "#6b7280" // gray-500
      : healthFactor < liquidationThreshold
      ? "#f87171" // red-400
      : healthFactor < 1.5
      ? "#facc15" // yellow-400
      : "#4ade80"; // green-400

  const label =
    healthFactor == null ? "—" : healthFactor.toFixed(3);

  // stroke-dasharray = [filled portion, gap], stroke-dashoffset shifts the fill
  const dashOffset = ARC_CIRCUMFERENCE * (1 - animatedFraction);

  // Position of the threshold mark as a fraction of the arc.
  // The default threshold is 1.0, which sits at 1.0/3.0 = 0.333 of the arc.
  const thresholdFraction = Math.min(
    1,
    liquidationThreshold / MAX_HF_DISPLAY
  );

  return (
    <div className="flex flex-col items-center">
      <svg
        viewBox="0 0 200 110"
        className="w-full max-w-[260px]"
        role="img"
        aria-label={
          healthFactor == null
            ? "Health factor loading"
            : `Health factor ${healthFactor.toFixed(3)}, liquidation threshold ${liquidationThreshold}`
        }
      >
        {/* Background track */}
        <path
          d={describeArc()}
          fill="none"
          stroke="#374151"
          strokeWidth={14}
          strokeLinecap="round"
        />
        {/* Filled portion — smooth transition via CSS */}
        <path
          d={describeArc()}
          fill="none"
          stroke={strokeColor}
          strokeWidth={14}
          strokeLinecap="round"
          strokeDasharray={ARC_CIRCUMFERENCE}
          strokeDashoffset={dashOffset}
          style={{ transition: "stroke-dashoffset 700ms ease-out, stroke 300ms ease" }}
        />
        {/* Liquidation threshold tick */}
        <line
          x1={arcPoint(thresholdFraction).x}
          y1={arcPoint(thresholdFraction).y - 12}
          x2={arcPoint(thresholdFraction).x}
          y2={arcPoint(thresholdFraction).y + 4}
          stroke="#ef4444"
          strokeWidth={2}
        />
        <text
          x={arcPoint(thresholdFraction).x}
          y={arcPoint(thresholdFraction).y - 16}
          textAnchor="middle"
          className="fill-red-400"
          style={{ fontSize: "9px", fontWeight: 600 }}
        >
          1.0
        </text>
      </svg>
      <div className="-mt-6 flex flex-col items-center">
        <div className={`text-3xl font-bold ${color}`}>{label}</div>
        <div className="text-xs text-gray-400 uppercase tracking-wide mt-1">
          Protocol Health Factor
        </div>
        <div className="text-xs text-gray-500 mt-1">
          Liquidation at{" "}
          <span className="text-red-400 font-semibold">
            {liquidationThreshold.toFixed(2)}
          </span>
        </div>
      </div>
    </div>
  );
}

/**
 * SVG path string for a 180° semicircle arc. The arc starts at the left
 * (10, 100) and ends at the right (190, 100) with the centre at (100, 100)
 * and radius 70. We sweep anticlockwise so the fill grows left → right.
 */
function describeArc(): string {
  return "M 30 100 A 70 70 0 0 1 170 100";
}

/**
 * Returns the (x, y) point on the arc for a given fraction ∈ [0, 1],
 * where 0 is the left end and 1 is the right end. Used to position the
 * threshold tick mark along the gauge.
 */
function arcPoint(fraction: number): { x: number; y: number } {
  // angle from π (left) to 0 (right), measured anticlockwise from positive x.
  const angle = Math.PI * (1 - fraction);
  return {
    x: 100 + ARC_RADIUS * Math.cos(angle),
    y: 100 - ARC_RADIUS * Math.sin(angle),
  };
}
