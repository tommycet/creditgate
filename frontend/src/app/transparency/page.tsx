"use client";

import { useReadContract } from "wagmi";
import { formatUnits } from "viem";
import { CREDIT_GATE_CONFIG, LOAN_STATES } from "@/config/contract";
import { CREDIT_GATE_ABI } from "@/lib/abi";

export default function TransparencyPage() {
  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;

  const { data: ownerRaw } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "owner",
  });
  const owner = (ownerRaw ?? "") as string;

  const { data: paused } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "paused",
  });

  const { data: collateralRatio } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "collateralRatioBps",
  });

  const { data: nextLoanId } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "nextLoanId",
  });

  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <div className="container mx-auto px-4 py-8">
        <div className="flex justify-between items-center mb-8">
          <h1 className="text-2xl font-bold">Transparency Dashboard</h1>
          <a
            href={`${CREDIT_GATE_CONFIG.explorerUrl}/address/${vaultAddress}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-blue-400 hover:text-blue-300 text-sm"
          >
            View on Explorer ↗
          </a>
        </div>

        <div className="max-w-4xl mx-auto space-y-8">
          {/* Vault Status */}
          <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
            <h2 className="text-xl font-semibold mb-4">Vault Status</h2>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
              <div>
                <div className="text-sm text-gray-400">Status</div>
                <div className={`font-semibold ${paused ? "text-red-400" : "text-green-400"}`}>
                  {paused ? "Paused" : "Active"}
                </div>
              </div>
              <div>
                <div className="text-sm text-gray-400">Collateral Ratio</div>
                <div className="font-semibold">
                  {collateralRatio ? (Number(collateralRatio) / 100).toFixed(0) : "—"}%
                </div>
              </div>
              <div>
                <div className="text-sm text-gray-400">Total Loans</div>
                <div className="font-semibold">
                  {nextLoanId ? (Number(nextLoanId) - 1).toString() : "0"}
                </div>
              </div>
              <div>
                <div className="text-sm text-gray-400">Owner</div>
                <div className="font-semibold text-sm truncate">
                  {owner ? `${owner.slice(0, 6)}...${owner.slice(-4)}` : "—"}
                </div>
              </div>
            </div>
          </div>

          {/* Evidence Modes */}
          <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
            <h2 className="text-xl font-semibold mb-4">Evidence Modes</h2>
            <div className="space-y-3">
              {[
                { surface: "Coston2 vault txs", label: "LIVE Coston2", color: "green" },
                { surface: "FCC eligibility", label: "SIMULATED TEE", color: "yellow" },
                { surface: "XRPL payment", label: "LIVE XRPL TESTNET", color: "green" },
                { surface: "FDC proof", label: "SIMULATED FDC FIXTURE", color: "yellow" },
                { surface: "Foundry mocks", label: "TEST FIXTURE", color: "gray" },
              ].map((item) => (
                <div key={item.surface} className="flex justify-between items-center">
                  <span className="text-gray-300">{item.surface}</span>
                  <span
                    className={`px-2 py-1 rounded text-xs font-semibold ${
                      item.color === "green"
                        ? "bg-green-900 text-green-300"
                        : item.color === "yellow"
                        ? "bg-yellow-900 text-yellow-300"
                        : "bg-gray-700 text-gray-400"
                    }`}
                  >
                    {item.label}
                  </span>
                </div>
              ))}
            </div>
          </div>

          {/* Contract Addresses */}
          <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
            <h2 className="text-xl font-semibold mb-4">Contract Addresses (Coston2)</h2>
            <div className="space-y-2">
              {Object.entries(CREDIT_GATE_CONFIG.contracts).map(([name, addr]) => (
                <div key={name} className="flex justify-between items-center">
                  <span className="text-gray-300 text-sm">{name}</span>
                  <a
                    href={`${CREDIT_GATE_CONFIG.explorerUrl}/address/${addr}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="text-blue-400 hover:text-blue-300 text-sm font-mono"
                  >
                    {addr.slice(0, 6)}...{addr.slice(-4)} ↗
                  </a>
                </div>
              ))}
            </div>
          </div>

          {/* Architecture */}
          <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
            <h2 className="text-xl font-semibold mb-4">Architecture</h2>
            <div className="font-mono text-sm text-gray-300 bg-gray-950 rounded-lg p-4 overflow-x-auto">
              <pre>{`Borrower → Deposit FXRP → Request Eligibility → FCC Evaluates → Draw USDT0
                                                           ↓
                                                    Loan FUNDED
                                                           ↓
Borrower → Repay on XRPL → FDC Verifies Proof → Collateral Released
                                                           ↓
                                                      Loan CLOSED`}</pre>
            </div>
          </div>
        </div>
      </div>
    </main>
  );
}
