"use client";

import Link from "next/link";

const docs = [
  { slug: "architecture", title: "Architecture", desc: "System overview, Flare primitives, state machine, risk paths" },
  { slug: "submission", title: "Submission", desc: "Bounty, description, Flare usage, newly built, roadmap" },
  { slug: "deployment", title: "Live Deployment", desc: "Vault address, tx hashes, FDC attestation, round finalization" },
  { slug: "testing", title: "Testing", desc: "141 tests, 11 suites, 8 invariants, 97.75% coverage" },
  { slug: "security", title: "Security", desc: "Audit findings (M1/M2/L1/L2/L4/L5) and fixes" },
  { slug: "fdc-verify", title: "FDC Real Verify", desc: "Real XRPL testnet tx → FDC attestation, verify path evidence" },
];

export default function DocsPage() {
  return (
    <div className="min-h-screen bg-slate-950 text-slate-200">
      <div className="max-w-4xl mx-auto px-4 py-12">
        <h1 className="text-3xl font-bold text-cyan-300 mb-2">CreditGate Documentation</h1>
        <p className="text-slate-400 mb-8">Technical documentation, evidence, and verification reports.</p>

        <div className="grid gap-4">
          {docs.map((doc) => (
            <Link
              key={doc.slug}
              href={`/docs/${doc.slug}`}
              className="block p-6 rounded-xl bg-slate-900 border border-slate-800 hover:border-cyan-500/50 hover:bg-slate-800/50 transition-all"
            >
              <h2 className="text-lg font-semibold text-white mb-1">{doc.title}</h2>
              <p className="text-sm text-slate-400">{doc.desc}</p>
            </Link>
          ))}
        </div>

        <div className="mt-8 flex gap-4">
          <Link href="/" className="text-cyan-400 hover:text-cyan-300 text-sm">← Back to app</Link>
          <a href="https://coston2-explorer.flare.network/address/0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939" target="_blank" rel="noreferrer" className="text-cyan-400 hover:text-cyan-300 text-sm">
            View vault on Coston2 Explorer ↗
          </a>
        </div>
      </div>
    </div>
  );
}
