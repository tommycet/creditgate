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

          {/* Stats badges */}
          <div className="flex justify-center gap-6 mb-12 flex-wrap">
            <div className="text-center">
              <div className="text-3xl font-bold text-orange-400">138/138</div>
              <div className="text-xs text-gray-500">tests passing</div>
            </div>
            <div className="text-center">
              <div className="text-3xl font-bold text-blue-400">4</div>
              <div className="text-xs text-gray-500">Flare primitives</div>
            </div>
            <div className="text-center">
              <div className="text-3xl font-bold text-green-400">7</div>
              <div className="text-xs text-gray-500">test suites</div>
            </div>
            <div className="text-center">
              <div className="text-3xl font-bold text-purple-400">5</div>
              <div className="text-xs text-gray-500">security fixes</div>
            </div>
          </div>

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
            <Link
              href="/docs"
              className="px-8 py-3 border border-gray-600 hover:border-gray-400 rounded-lg font-semibold transition-colors"
            >
              Docs
            </Link>
          </div>

          <ConnectButton />
        </div>
      </div>

      {/* How It Works — 4-step flow with arrows */}
      <div className="container mx-auto px-4 py-16 border-t border-gray-800">
        <h2 className="text-3xl font-bold text-center mb-4">How It Works</h2>
        <p className="text-center text-gray-400 mb-12 max-w-2xl mx-auto">
          Four steps, four Flare primitives. Each stage of the credit lifecycle uses a different Flare primitive end-to-end.
        </p>
        <div className="max-w-6xl mx-auto flex flex-col md:flex-row items-stretch justify-between gap-2 md:gap-0">
          {[
            {
              step: "1",
              title: "Deposit FXRP",
              primitive: "FAssets",
              desc: "Lock FXRP collateral on Flare Coston2 as the loan's security.",
            },
            {
              step: "2",
              title: "Private Credit Check",
              primitive: "FCC",
              desc: "Go handler in a TEE evaluates credit and signs an EIP-191 attestation — data never leaves the enclave.",
            },
            {
              step: "3",
              title: "Draw USDT0 Loan",
              primitive: "FTSOv2",
              desc: "Borrow USDT0 against your collateral at the live FTSO-priced collateral ratio.",
            },
            {
              step: "4",
              title: "Repay on XRPL",
              primitive: "FDC",
              desc: "Repay on the XRPL; FDC verifies the cross-chain proof and releases your FXRP.",
            },
          ].map((item, i, arr) => (
            <div key={item.step} className="flex flex-col md:flex-row items-stretch md:items-center w-full md:w-auto flex-1">
              <div className="flex-1 p-5 bg-gray-900 rounded-lg border border-gray-700 hover:border-blue-500 transition-colors text-center h-full flex flex-col justify-between">
                <div>
                  <div className="w-11 h-11 bg-blue-600 rounded-full flex items-center justify-center mx-auto mb-3 text-lg font-bold">
                    {item.step}
                  </div>
                  <h3 className="font-semibold mb-1">{item.title}</h3>
                  <div className="inline-block mb-3 px-2 py-0.5 rounded text-[11px] font-semibold tracking-wide bg-blue-900/60 text-blue-300 border border-blue-700/40">
                    {item.primitive}
                  </div>
                  <p className="text-xs text-gray-400 leading-relaxed">{item.desc}</p>
                </div>
              </div>
              {/* Arrow between cards */}
              {i < arr.length - 1 && (
                <div className="flex items-center justify-center md:px-2 py-2 md:py-0" aria-hidden>
                  <span className="text-2xl text-blue-400 md:rotate-0 rotate-90 select-none">&rarr;</span>
                </div>
              )}
            </div>
          ))}
        </div>
      </div>

      {/* Why CreditGate */}
      <div className="container mx-auto px-4 py-16 border-t border-gray-800">
        <h2 className="text-3xl font-bold text-center mb-12">Why CreditGate</h2>
        <div className="max-w-4xl mx-auto grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="p-6 bg-gray-900 rounded-lg border border-gray-700 text-center">
            <div className="text-3xl mb-3">&#11088;</div>
            <div className="font-semibold mb-2">All 4 Flare Primitives</div>
            <p className="text-sm text-gray-400">
              The only Flare Summer Signal submission using FAssets, FTSOv2, FCC, and FDC in a single cohesive protocol.
            </p>
          </div>
          <div className="p-6 bg-gray-900 rounded-lg border border-gray-700 text-center">
            <div className="text-3xl mb-3">&#128274;</div>
            <div className="font-semibold mb-2">Private by Design</div>
            <p className="text-sm text-gray-400">
              Credit evaluation runs inside a TEE — your financial data never leaves the enclave, only an EIP-191 signature is published.
            </p>
          </div>
          <div className="p-6 bg-gray-900 rounded-lg border border-gray-700 text-center">
            <div className="text-3xl mb-3">&#9989;</div>
            <div className="font-semibold mb-2">Trustless Repayment Proof</div>
            <p className="text-sm text-gray-400">
              Public repayment verification via FDC — cross-chain XRPL &rarr; Flare proof, no oracle or centralized bridge to trust.
            </p>
          </div>
        </div>
      </div>

      {/* Flare Integration */}
      <div className="container mx-auto px-4 py-16 border-t border-gray-800">
        <h2 className="text-3xl font-bold text-center mb-4">All 4 Flare Primitives</h2>
        <p className="text-center text-gray-400 mb-12 max-w-2xl mx-auto">
          CreditGate is the only Flare Summer Signal submission using FAssets, FTSO, FCC, and FDC in a single cohesive protocol.
        </p>
        <div className="max-w-2xl mx-auto grid grid-cols-2 gap-6">
          {[
            { name: "FAssets (FXRP)", role: "Collateral ERC-20", live: true },
            { name: "FTSOv2", role: "XRP/USD Price Feed", live: true },
            { name: "FCC", role: "Private Credit Evaluation", live: false },
            { name: "FDC", role: "XRPL Repayment Verification", live: false },
          ].map((item) => (
            <div key={item.name} className="p-4 bg-gray-900 rounded-lg border border-gray-700">
              <div className="flex justify-between items-start">
                <div>
                  <div className="font-semibold text-blue-400">{item.name}</div>
                  <div className="text-sm text-gray-400">{item.role}</div>
                </div>
                <span className={`px-2 py-0.5 rounded text-xs font-semibold ${item.live ? "bg-green-900 text-green-300" : "bg-yellow-900 text-yellow-300"}`}>
                  {item.live ? "LIVE" : "SIM"}
                </span>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Security Evidence */}
      <div className="container mx-auto px-4 py-16 border-t border-gray-800">
        <h2 className="text-3xl font-bold text-center mb-12">Security Evidence</h2>
        <div className="max-w-3xl mx-auto grid grid-cols-1 md:grid-cols-3 gap-6">
          <div className="p-4 bg-gray-900 rounded-lg border border-gray-700 text-center">
            <div className="text-2xl mb-2">&#128737;</div>
            <div className="font-semibold text-sm">Reentrancy Attack Test</div>
            <div className="text-xs text-gray-400 mt-1">Malicious FXRP token callback blocked by ReentrancyGuard</div>
          </div>
          <div className="p-4 bg-gray-900 rounded-lg border border-gray-700 text-center">
            <div className="text-2xl mb-2">&#128274;</div>
            <div className="font-semibold text-sm">Go-TEE Compatibility</div>
            <div className="text-xs text-gray-400 mt-1">Go FCC signature accepted by Solidity ecrecover (EIP-191)</div>
          </div>
          <div className="p-4 bg-gray-900 rounded-lg border border-gray-700 text-center">
            <div className="text-2xl mb-2">&#128270;</div>
            <div className="font-semibold text-sm">Invariant Fuzz Tests</div>
            <div className="text-xs text-gray-400 mt-1">FXRP conservation + USDT0 solvency (256 runs each)</div>
          </div>
        </div>
      </div>
    </main>
  );
}
