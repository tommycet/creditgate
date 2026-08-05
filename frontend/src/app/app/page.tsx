"use client";

import { useState } from "react";
import { useAccount, useWriteContract, useReadContract } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { parseUnits, formatUnits } from "viem";
import { CREDIT_GATE_CONFIG, LOAN_STATES } from "@/config/contract";
import { CREDIT_GATE_ABI } from "@/lib/abi";

export default function AppPage() {
  const { address, isConnected } = useAccount();
  const [depositAmount, setDepositAmount] = useState("");
  const [loanAmount, setLoanAmount] = useState("");
  const [selectedLoanId, setSelectedLoanId] = useState<string>("");

  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;

  // Read vault state
  const { data: nextLoanId } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "nextLoanId",
  });

  // Read borrower loans
  const { data: borrowerLoanIds } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "getBorrowerLoanIds",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });

  // Write contract hooks
  const { writeContract: depositCollateral, isPending: isDepositing } = useWriteContract();
  const { writeContract: requestEligibility, isPending: isRequesting } = useWriteContract();
  const { writeContract: drawLoan, isPending: isDrawing } = useWriteContract();
  const { writeContract: withdrawCollateral, isPending: isWithdrawing } = useWriteContract();

  const handleDeposit = () => {
    if (!depositAmount) return;
    depositCollateral({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "depositCollateral",
      args: [parseUnits(depositAmount, 6)],
    });
  };

  const handleRequestEligibility = (loanId: bigint) => {
    requestEligibility({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "requestEligibility",
      args: [loanId],
    });
  };

  const handleDrawLoan = (loanId: bigint) => {
    if (!loanAmount) return;
    drawLoan({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "drawLoan",
      args: [loanId, parseUnits(loanAmount, 6)],
    });
  };

  const handleWithdraw = (loanId: bigint) => {
    withdrawCollateral({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "withdrawCollateral",
      args: [loanId],
    });
  };

  return (
    <main className="min-h-screen bg-gray-950 text-white">
      <div className="container mx-auto px-4 py-8">
        {/* Header */}
        <div className="flex justify-between items-center mb-8">
          <h1 className="text-2xl font-bold">CreditGate Vault</h1>
          <ConnectButton />
        </div>

        {!isConnected ? (
          <div className="text-center py-20">
            <p className="text-gray-400 text-lg">Connect your wallet to interact with CreditGate</p>
          </div>
        ) : (
          <div className="max-w-4xl mx-auto grid grid-cols-1 md:grid-cols-2 gap-8">
            {/* Deposit Panel */}
            <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
              <h2 className="text-xl font-semibold mb-4">Deposit FXRP Collateral</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-sm text-gray-400 mb-1">Amount (FXRP)</label>
                  <input
                    type="number"
                    value={depositAmount}
                    onChange={(e) => setDepositAmount(e.target.value)}
                    placeholder="100"
                    className="w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-2 focus:outline-none focus:border-blue-500"
                  />
                </div>
                <button
                  onClick={handleDeposit}
                  disabled={isDepositing || !depositAmount}
                  className="w-full bg-blue-600 hover:bg-blue-500 disabled:bg-gray-700 rounded-lg py-2 font-semibold transition-colors"
                >
                  {isDepositing ? "Depositing..." : "Deposit"}
                </button>
              </div>
            </div>

            {/* Loan Panel */}
            <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
              <h2 className="text-xl font-semibold mb-4">Draw USDT0 Loan</h2>
              <div className="space-y-4">
                <div>
                  <label className="block text-sm text-gray-400 mb-1">Loan ID</label>
                  <input
                    type="number"
                    value={selectedLoanId}
                    onChange={(e) => setSelectedLoanId(e.target.value)}
                    placeholder="1"
                    className="w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-2 focus:outline-none focus:border-blue-500"
                  />
                </div>
                <div>
                  <label className="block text-sm text-gray-400 mb-1">Amount (USDT0)</label>
                  <input
                    type="number"
                    value={loanAmount}
                    onChange={(e) => setLoanAmount(e.target.value)}
                    placeholder="100"
                    className="w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-2 focus:outline-none focus:border-blue-500"
                  />
                </div>
                <div className="grid grid-cols-2 gap-2">
                  <button
                    onClick={() => selectedLoanId && handleRequestEligibility(BigInt(selectedLoanId))}
                    disabled={isRequesting || !selectedLoanId}
                    className="bg-purple-600 hover:bg-purple-500 disabled:bg-gray-700 rounded-lg py-2 font-semibold transition-colors text-sm"
                  >
                    {isRequesting ? "Requesting..." : "Request Eligibility"}
                  </button>
                  <button
                    onClick={() => selectedLoanId && handleDrawLoan(BigInt(selectedLoanId))}
                    disabled={isDrawing || !selectedLoanId || !loanAmount}
                    className="bg-green-600 hover:bg-green-500 disabled:bg-gray-700 rounded-lg py-2 font-semibold transition-colors text-sm"
                  >
                    {isDrawing ? "Drawing..." : "Draw Loan"}
                  </button>
                </div>
              </div>
            </div>

            {/* Active Loans */}
            <div className="bg-gray-900 rounded-lg p-6 border border-gray-700 md:col-span-2">
              <h2 className="text-xl font-semibold mb-4">Your Loans</h2>
              {borrowerLoanIds && borrowerLoanIds.length > 0 ? (
                <div className="space-y-3">
                  {borrowerLoanIds.map((loanId) => (
                    <LoanCard key={loanId.toString()} loanId={loanId} />
                  ))}
                </div>
              ) : (
                <p className="text-gray-400">No loans found. Deposit collateral to get started.</p>
              )}
            </div>
          </div>
        )}
      </div>
    </main>
  );
}

function LoanCard({ loanId }: { loanId: bigint }) {
  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;
  const { writeContract: withdrawCollateral, isPending } = useWriteContract();

  const { data: loan } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "getLoan",
    args: [loanId],
  });

  if (!loan) return null;

  const [borrower, collateralAmount, loanAmount, requiredRepaymentDrops, deadline, eligibilityExpiry, eligibilityNonce, expectedCommitment, state] = loan;

  const stateName = LOAN_STATES[state as keyof typeof LOAN_STATES] || "UNKNOWN";

  const handleWithdraw = () => {
    withdrawCollateral({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "withdrawCollateral",
      args: [loanId],
    });
  };

  return (
    <div className="bg-gray-800 rounded-lg p-4 border border-gray-600">
      <div className="flex justify-between items-start">
        <div>
          <div className="font-semibold">Loan #{loanId.toString()}</div>
          <div className="text-sm text-gray-400">
            Collateral: {formatUnits(collateralAmount, 6)} FXRP
          </div>
          {loanAmount > 0n && (
            <div className="text-sm text-gray-400">
              Loan: {formatUnits(loanAmount, 6)} USDT0
            </div>
          )}
        </div>
        <div className="text-right">
          <span
            className={`px-2 py-1 rounded text-xs font-semibold ${
              state === 1
                ? "bg-yellow-900 text-yellow-300"
                : state === 3
                ? "bg-green-900 text-green-300"
                : state === 4
                ? "bg-blue-900 text-blue-300"
                : state === 6
                ? "bg-gray-700 text-gray-300"
                : "bg-gray-700 text-gray-400"
            }`}
          >
            {stateName}
          </span>
        </div>
      </div>
      {state === 1 && (
        <button
          onClick={handleWithdraw}
          disabled={isPending}
          className="mt-3 w-full bg-red-600 hover:bg-red-500 disabled:bg-gray-700 rounded-lg py-1 text-sm font-semibold transition-colors"
        >
          {isPending ? "Withdrawing..." : "Withdraw Collateral"}
        </button>
      )}
    </div>
  );
}
