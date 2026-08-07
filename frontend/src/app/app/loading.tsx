import { SkeletonCard } from "@/components/Skeleton";

/** App route loading skeleton — mirrors the Vault page layout. */
export default function AppLoading() {
  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <div className="container mx-auto px-4 py-8">
        {/* Header */}
        <div className="flex justify-between items-center mb-8">
          <div className="h-8 w-48 bg-gray-800 rounded animate-pulse" />
          <div className="h-10 w-36 bg-gray-800 rounded animate-pulse" />
        </div>

        {/* Balance cards */}
        <div className="mb-6 grid grid-cols-1 sm:grid-cols-2 gap-4 max-w-4xl mx-auto">
          <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 animate-pulse">
            <div className="h-3 w-20 bg-gray-700 rounded mb-2" />
            <div className="h-6 w-28 bg-gray-700 rounded" />
          </div>
          <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 animate-pulse">
            <div className="h-3 w-20 bg-gray-700 rounded mb-2" />
            <div className="h-6 w-28 bg-gray-700 rounded" />
          </div>
        </div>

        {/* Action panels */}
        <div className="max-w-4xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-8">
          <SkeletonCard lines={3} />
          <SkeletonCard lines={3} />
          <SkeletonCard lines={2} className="md:col-span-2" />
        </div>
      </div>
    </main>
  );
}
