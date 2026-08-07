"use client";

import { useEffect } from "react";

/** Next.js global error boundary (route-level error.tsx). */
export default function GlobalError({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  useEffect(() => {
    console.error("[GlobalError]", error);
  }, [error]);

  return (
    <div className="min-h-screen bg-gray-950 flex items-center justify-center p-8">
      <div className="bg-gray-900 border border-red-500/50 rounded-xl p-8 max-w-md text-center space-y-4">
        <div className="text-4xl">⚠️</div>
        <h2 className="text-xl font-bold text-red-300">Something went wrong</h2>
        <p className="text-sm text-gray-400">
          {error?.message ?? "An unexpected error occurred while loading this page."}
        </p>
        <button
          onClick={reset}
          className="inline-block bg-blue-600 hover:bg-blue-500 text-white font-semibold rounded-lg px-6 py-2 transition-colors"
        >
          Try Again
        </button>
      </div>
    </div>
  );
}
