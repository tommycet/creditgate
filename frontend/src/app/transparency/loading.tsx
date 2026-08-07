import { SkeletonCard } from "@/components/Skeleton";

/** Transparency route loading skeleton. */
export default function TransparencyLoading() {
  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <div className="container mx-auto px-4 py-8">
        {/* Header */}
        <div className="flex justify-between items-center mb-8">
          <div className="h-8 w-56 bg-gray-800 rounded animate-pulse" />
          <div className="h-5 w-32 bg-gray-800 rounded animate-pulse" />
        </div>

        <div className="max-w-4xl mx-auto space-y-8">
          <SkeletonCard lines={4} />
          <SkeletonCard lines={2} />
          <SkeletonCard lines={3} />
        </div>
      </div>
    </main>
  );
}
