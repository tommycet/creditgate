/**
 * Reusable skeleton loading primitives. Every variant uses the same Tailwind
 * `animate-pulse` shimmer so pages feel cohesive while contract data loads.
 */

interface SkeletonProps {
  className?: string;
}

/** Generic rectangle block — pass width/height via className. */
export function SkeletonBlock({ className = "" }: SkeletonProps) {
  return (
    <div
      className={`animate-pulse rounded-lg bg-gray-800 ${className}`}
      aria-hidden="true"
    />
  );
}

/** Single line of text (label or value placeholder). */
export function SkeletonLine({ className = "" }: SkeletonProps) {
  return (
    <div
      className={`animate-pulse h-4 rounded bg-gray-700 ${className}`}
      aria-hidden="true"
    />
  );
}

/** Pre-built card skeleton matching the balance-card / action-panel shape. */
export function SkeletonCard({ lines = 3, className = "" }: SkeletonProps & { lines?: number }) {
  return (
    <div
      className={`bg-gray-900 rounded-lg p-4 border border-gray-700 animate-pulse space-y-3 ${className}`}
      aria-hidden="true"
    >
      <SkeletonLine className="w-1/3 h-3" />
      {Array.from({ length: lines }).map((_, i) => (
        <SkeletonLine key={i} className={i === 0 ? "w-3/4" : "w-1/2"} />
      ))}
    </div>
  );
}
