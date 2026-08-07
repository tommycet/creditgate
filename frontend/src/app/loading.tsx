import { SkeletonCard } from "@/components/Skeleton";

/** Global loading skeleton shown during route transitions (Next.js streaming). */
export default function GlobalLoading() {
  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <div className="container mx-auto px-4 py-8 space-y-6">
        {/* Header skeleton */}
        <div className="flex justify-between items-center">
          <div className="h-8 w-48 bg-gray-800 rounded animate-pulse" />
          <div className="h-10 w-36 bg-gray-800 rounded animate-pulse" />
        </div>
        {/* Card skeletons */}
        <div className="max-w-4xl mx-auto space-y-4">
          <SkeletonCard />
          <SkeletonCard />
          <SkeletonCard />
        </div>
      </div>
    </main>
  );
}
