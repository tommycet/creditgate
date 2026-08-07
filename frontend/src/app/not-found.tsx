/** Custom 404 page. */
export default function NotFound() {
  return (
    <div className="min-h-screen bg-gray-950 flex items-center justify-center p-8">
      <div className="text-center space-y-4">
        <div className="text-6xl">🔍</div>
        <h1 className="text-3xl font-bold text-white">404 — Page Not Found</h1>
        <p className="text-gray-400">
          The page you are looking for does not exist or has been moved.
        </p>
        <a
          href="/"
          className="inline-block bg-blue-600 hover:bg-blue-500 text-white font-semibold rounded-lg px-6 py-2 transition-colors"
        >
          Go Home
        </a>
      </div>
    </div>
  );
}
