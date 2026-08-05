"use client";

import Link from "next/link";
import { ConnectButton } from "@rainbow-me/rainbowkit";

export default function HomePage() {
  return (
    <main className="min-h-screen bg-gray-950 text-white">
      {/* Hero */}
      <div className="container mx-auto px-4 py-20">
        <div className="max-w-3xl mx-auto text-center">
          <h1 className="text-5xl font-bold mb-6 bg-gradient-to-r from-blue-400 to-purple-500 bg-clip-text text-transparent">
            CreditGate
          </h1>
          <p className="text-xl text-gray-400 mb-8">
            Private FXRP credit eligibility layer for Flare.
            Borrow against your XRP exposure with confidential credit evaluation.
          </p>

          <div className="flex justify-center gap-4 mb-12">
            <Link
              href="/app"
              className="px-8 py-3 bg-blue-600 hover:bg-blue-500 rounded-lg font-semibold transition-colors"
            >
              Launch App
            </Link>
            <Link
              href="/transparency"
              className="px-8 py-3 border border-gray-600 hover:border-gray-400 rounded-lg font-semibold transition-colors"
            >
              Transparency
            </Link>
          </div>

          <ConnectButton />
        </div>
      </div>

      {/* Architecture */}
      <div className="container mx-auto px-4 py-16 border-t border-gray-800">
        <h2 className="text-3xl font-bold text-center mb-12">How It Works</h2>
        <div className="max-w-4xl mx-auto grid grid-cols-1 md:grid-cols-4 gap-8">
          {[
            { step: "1", title: "Deposit FXRP", desc: "Lock FXRP collateral on Flare Coston2" },
            { step: "2", title: "Bind XRPL + FCC", desc: "Register repayment address; TEE signs private credit decision" },
            { step: "3", title: "Draw USDT0", desc: "Borrow against collateral ratio (FTSO-priced)" },
            { step: "4", title: "Repay on XRPL", desc: "FDC verifies repayment proof, releases collateral" },
          ].map((item) => (
            <div key={item.step} className="text-center">
              <div className="w-12 h-12 bg-blue-600 rounded-full flex items-center justify-center mx-auto mb-4 text-xl font-bold">
                {item.step}
              </div>
              <h3 className="font-semibold mb-2">{item.title}</h3>
              <p className="text-sm text-gray-400">{item.desc}</p>
            </div>
          ))}
        </div>
      </div>

      {/* Flare Integration */}
      <div className="container mx-auto px-4 py-16 border-t border-gray-800">
        <h2 className="text-3xl font-bold text-center mb-12">Flare Integration</h2>
        <div className="max-w-2xl mx-auto grid grid-cols-2 gap-6">
          {[
            { name: "FAssets (FXRP)", role: "Collateral ERC-20" },
            { name: "FTSOv2", role: "XRP/USD Price Feed" },
            { name: "FCC", role: "Private Credit Evaluation" },
            { name: "FDC", role: "XRPL Repayment Verification" },
          ].map((item) => (
            <div key={item.name} className="p-4 bg-gray-900 rounded-lg border border-gray-700">
              <div className="font-semibold text-blue-400">{item.name}</div>
              <div className="text-sm text-gray-400">{item.role}</div>
            </div>
          ))}
        </div>
      </div>
    </main>
  );
}
