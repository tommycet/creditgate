"use client";

import Link from "next/link";
import { ReactNode } from "react";

const navItems = [
  { slug: "", label: "Index" },
  { slug: "architecture", label: "Architecture" },
  { slug: "submission", label: "Submission" },
  { slug: "deployment", label: "Deployment" },
  { slug: "testing", label: "Testing" },
  { slug: "security", label: "Security" },
  { slug: "fdc-verify", label: "FDC Verify" },
];

export function DocsLayout({ children, title }: { children: ReactNode; title: string }) {
  return (
    <div className="min-h-screen bg-slate-950 text-slate-200">
      <div className="flex">
        {/* Sidebar */}
        <nav className="w-56 shrink-0 border-r border-slate-800 min-h-screen p-4 sticky top-0 h-screen overflow-y-auto">
          <Link href="/docs" className="block text-cyan-300 font-bold mb-4 hover:text-cyan-200">← Docs</Link>
          <ul className="space-y-1">
            {navItems.map((item) => (
              <li key={item.slug}>
                <Link
                  href={item.slug ? `/docs/${item.slug}` : "/docs"}
                  className={`block px-2 py-1 rounded text-sm ${
                    item.label === title
                      ? "bg-slate-800 text-cyan-300 font-semibold"
                      : "text-slate-400 hover:text-slate-200 hover:bg-slate-800/50"
                  }`}
                >
                  {item.label}
                </Link>
              </li>
            ))}
          </ul>
          <div className="mt-8 pt-4 border-t border-slate-800">
            <Link href="/" className="text-xs text-slate-500 hover:text-slate-300">← Back to app</Link>
          </div>
        </nav>

        {/* Content */}
        <main className="flex-1 p-8 overflow-x-auto">
          <div className="max-w-4xl">
            {children}
          </div>
        </main>
      </div>
    </div>
  );
}
