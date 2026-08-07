"use client";

import React, { Component, type ReactNode } from "react";

interface Props {
  children: ReactNode;
  /** Optional fallback UI — if omitted, a default retry card is rendered. */
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error: Error | null;
}

/**
 * Class-based React error boundary. Wraps page content so that uncaught render
 * errors show a friendly card with a retry button instead of a blank screen.
 */
export class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    console.error("[ErrorBoundary]", error, info.componentStack);
  }

  handleRetry = () => {
    this.setState({ hasError: false, error: null });
  };

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) return this.props.fallback;

      return (
        <div className="min-h-[50vh] flex items-center justify-center p-8">
          <div className="bg-gray-900 border border-red-500/50 rounded-xl p-8 max-w-md text-center space-y-4">
            <div className="text-4xl">💥</div>
            <h2 className="text-xl font-bold text-red-300">Something went wrong</h2>
            <p className="text-sm text-gray-400">
              {this.state.error?.message ?? "An unexpected error occurred."}
            </p>
            <button
              onClick={this.handleRetry}
              className="inline-block bg-blue-600 hover:bg-blue-500 text-white font-semibold rounded-lg px-6 py-2 transition-colors"
            >
              Try Again
            </button>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}
