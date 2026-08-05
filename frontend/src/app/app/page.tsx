"use client";

import { useState } from "react";
import { useAccount, useWriteContract, useReadContract, useChainId, useSwitchChain } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { parseUnits, formatUnits, keccak256, stringToHex } from "viem";
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
  const { data: borrowerLoanIdsRaw } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "getBorrowerLoanIds",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const borrowerLoanIds: bigint[] = (borrowerLoanIdsRaw ?? []) as bigint[];

  // Write contract hooks — capture errors for user-facing display
  const { writeContract: depositCollateral, isPending: isDepositing, error: depositError } = useWriteContract();
  const { writeContract: requestEligibility, isPending: isRequesting, error: requestError } = useWriteContract();
  const { writeContract: drawLoan, isPending: isDrawing, error: drawError } = useWriteContract();
  const { writeContract: withdrawCollateral, isPending: isWithdrawing, error: withdrawError } = useWriteContract();
  const { writeContract: registerXRPL, isPending: isRegistering, error: registerError } = useWriteContract();
  const { writeContract: approveUsdt0, isPending: isApproving, error: approveError } = useWriteContract();

  const txError = depositError || requestError || drawError || withdrawError || registerError || approveError;

  // Network mismatch detection — Coston2 is chain ID 114
  const chainId = useChainId();
  const { switchChain, isPending: isSwitchingNetwork } = useSwitchChain();
  const wrongNetwork = !!address && chainId !== CREDIT_GATE_CONFIG.chainId;

  const [xrplAddress, setXrplAddress] = useState("");
  const [fccJson, setFccJson] = useState("");

  // Submit eligibility attestation
  const { writeContract: submitEligibilityTx, isPending: isSubmitting } = useWriteContract();

  // Read the borrower's XRPL binding
  const { data: xrplBindingRaw } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "borrowerXRPLAddressHash",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const xrplBound = xrplBindingRaw && (xrplBindingRaw as `0x${string}`) !== "0x0000000000000000000000000000000000000000000000000000000000000000";

  // Read USDT0 allowance for the vault
  const { data: usdt0AllowanceRaw, refetch: refetchAllowance } = useReadContract({
    address: CREDIT_GATE_CONFIG.contracts.usdt0 as `0x${string}`,
    abi: CREDIT_GATE_ABI,
    functionName: "allowance",
    args: address ? [address, vaultAddress] : undefined,
    query: { enabled: !!address },
  });
  const usdt0Allowance = (usdt0AllowanceRaw ?? 0n) as bigint;

  // Read token balances for display
  const { data: fxrpBalanceRaw } = useReadContract({
    address: CREDIT_GATE_CONFIG.contracts.fxrp as `0x${string}`,
    abi: CREDIT_GATE_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const fxrpBalance = (fxrpBalanceRaw ?? 0n) as bigint;

  const { data: usdt0BalanceRaw } = useReadContract({
    address: CREDIT_GATE_CONFIG.contracts.usdt0 as `0x${string}`,
    abi: CREDIT_GATE_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const usdt0Balance = (usdt0BalanceRaw ?? 0n) as bigint;

  const handleDeposit = () => {
    if (!depositAmount) return;
    depositCollateral({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "depositCollateral",
      args: [parseUnits(depositAmount, 6)],
    });
  };

  const handleRegisterXRPL = () => {
    if (!xrplAddress.trim()) return;
    const hash = keccak256(stringToHex(xrplAddress.trim()));
    registerXRPL({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "registerXRPLAddress",
      args: [hash],
    });
  };

  const handleApproveUsdt0 = () => {
    if (!loanAmount) return;
    approveUsdt0({
      address: CREDIT_GATE_CONFIG.contracts.usdt0 as `0x${string}`,
      abi: CREDIT_GATE_ABI,
      functionName: "approve",
      args: [vaultAddress, parseUnits(loanAmount, 18)],
    });
  };

  const handleSubmitEligibility = (loanId: bigint) => {
    if (!fccJson) return;
    try {
      const att = JSON.parse(fccJson);
      submitEligibilityTx({
        address: vaultAddress,
        abi: CREDIT_GATE_ABI,
        functionName: "submitEligibility",
        args: [
          loanId,
          {
            borrower: att.borrower,
            limit: BigInt(att.limit),
            expiry: BigInt(att.expiry),
            nonce: att.nonce,
            revocationVersion: att.revocationVersion,
            v: att.v,
            r: att.r,
            s: att.s,
          },
        ],
      });
    } catch (e) {
      console.error("Invalid FCC JSON:", e);
    }
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
      args: [loanId, parseUnits(loanAmount, 18)],
      value: 0n,
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

        {/* Transaction error banner */}
        {txError && (
          <div className="mb-6 bg-red-900/50 border border-red-500 rounded-lg p-4">
            <p className="text-red-300 text-sm font-semibold">Transaction Error</p>
            <p className="text-red-200 text-xs mt-1">
              {txError?.message || String(txError)}
            </p>
          </div>
        )}

        {/* Network mismatch warning */}
        {wrongNetwork && (
          <div className="mb-6 bg-yellow-900/50 border border-yellow-500 rounded-lg p-4 flex flex-col sm:flex-row sm:items-center justify-between gap-3">
            <div>
              <p className="text-yellow-300 text-sm font-semibold">
                Wrong network — switch to Flare Coston2 (Chain ID 114)
              </p>
              <p className="text-yellow-200 text-xs mt-1">
                Your wallet is on chain {chainId}. CreditGate is deployed on Flare Coston2.
              </p>
            </div>
            <button
              onClick={() => switchChain({ chainId: CREDIT_GATE_CONFIG.chainId })}
              disabled={isSwitchingNetwork}
              className="bg-yellow-500 hover:bg-yellow-400 disabled:bg-gray-700 text-black font-semibold rounded-lg px-4 py-2 text-sm transition-colors whitespace-nowrap"
            >
              {isSwitchingNetwork ? "⏳ Switching…" : "Switch Network"}
            </button>
          </div>
        )}

        {!isConnected ? (
          <div className="text-center py-20">
            <p className="text-gray-400 text-lg">
              Connect your wallet to interact with CreditGate on Flare Coston2
            </p>
            <p className="text-gray-500 text-sm mt-2">
              Use the <span className="text-white font-semibold">Connect Wallet</span> button in the navbar above.
            </p>
          </div>
        ) : (
          <>
          {/* Token balances */}
          <div className="mb-6 grid grid-cols-2 gap-4 max-w-4xl mx-auto">
            <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 text-center">
              <div className="text-xs text-gray-400">Your FXRP Balance</div>
              <div className="text-lg font-semibold">{formatUnits(fxrpBalance, 6)}</div>
            </div>
            <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 text-center">
              <div className="text-xs text-gray-400">Your USDT0 Balance</div>
              <div className="text-lg font-semibold">{formatUnits(usdt0Balance, 18)}</div>
            </div>
          </div>
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

            {/* XRPL Address Binding Panel */}
            <div className="bg-gray-900 rounded-lg p-6 border border-gray-700 md:col-span-2">
              <h2 className="text-xl font-semibold mb-4">Bind XRPL Repayment Address</h2>
              <p className="text-sm text-gray-400 mb-3">
                Required before drawing a loan — the FDC repayment proof&apos;s receiving address must match this binding.
              </p>
              {xrplBound ? (
                <div className="text-sm text-green-400 font-semibold">
                  ✓ XRPL address bound — repayment proofs must match this address
                </div>
              ) : (
                <div className="flex gap-3">
                  <input
                    type="text"
                    value={xrplAddress}
                    onChange={(e) => setXrplAddress(e.target.value)}
                    placeholder="rXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
                    className="flex-1 bg-gray-800 border border-gray-600 rounded-lg px-4 py-2 focus:outline-none focus:border-blue-500"
                  />
                  <button
                    onClick={handleRegisterXRPL}
                    disabled={isRegistering || !xrplAddress.trim()}
                    className="bg-purple-600 hover:bg-purple-500 disabled:bg-gray-700 rounded-lg px-6 py-2 font-semibold transition-colors"
                  >
                    {isRegistering ? "Binding..." : "Bind XRPL Address"}
                  </button>
                </div>
              )}
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
                {/* USDT0 allowance gate */}
                <div className="text-xs text-gray-400">
                  {usdt0Allowance > 0n ? (
                    <span className="text-green-400">
                      ✓ USDT0 approved: {formatUnits(usdt0Allowance, 18)} USDT0
                    </span>
                  ) : (
                    <span>
                      USDT0 not approved yet — approve before drawing (the vault pulls the loan amount from your USDT0).
                    </span>
                  )}
                </div>
                <button
                  onClick={handleApproveUsdt0}
                  disabled={isApproving || !loanAmount || usdt0Allowance >= (loanAmount ? parseUnits(loanAmount, 18) : 0n)}
                  className="w-full bg-yellow-600 hover:bg-yellow-500 disabled:bg-gray-700 rounded-lg py-2 font-semibold transition-colors text-sm"
                >
                  {usdt0Allowance > 0n
                    ? `Approve More (currently ${formatUnits(usdt0Allowance, 18)})`
                    : isApproving
                    ? "Approving..."
                    : "Approve USDT0 for Vault"}
                </button>
              </div>
            </div>

            {/* FCC Attestation Panel */}
            <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
              <h2 className="text-xl font-semibold mb-4">Submit FCC Attestation</h2>
              <div className="space-y-3">
                <div className="text-xs text-gray-400">
                  After requesting eligibility, the FCC handler (:8080) evaluates your credit and returns a signed attestation JSON. Paste it below.
                </div>
                <input
                  type="text"
                  value={fccJson}
                  onChange={(e) => setFccJson(e.target.value)}
                  placeholder='{"borrower":"0x...","limit":"100000000","expiry":"...","nonce":0,"revocationVersion":0,"v":27,"r":"0x...","s":"0x..."}'
                  className="w-full bg-gray-800 border border-gray-600 rounded-lg px-3 py-2 text-xs font-mono focus:outline-none focus:border-purple-500"
                />
                <input
                  type="number"
                  value={selectedLoanId}
                  onChange={(e) => setSelectedLoanId(e.target.value)}
                  placeholder="Loan ID"
                  className="w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-2 focus:outline-none focus:border-blue-500 text-sm"
                />
                <button
                  onClick={() => selectedLoanId && handleSubmitEligibility(BigInt(selectedLoanId))}
                  disabled={isSubmitting || !selectedLoanId || !fccJson}
                  className="w-full bg-purple-600 hover:bg-purple-500 disabled:bg-gray-700 rounded-lg py-2 font-semibold transition-colors text-sm"
                >
                  {isSubmitting ? "Submitting..." : "Submit Eligibility"}
                </button>
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
          </>
        )}
      </div>
    </main>
  );
}

function LoanCard({ loanId }: { loanId: bigint }) {
  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;
  const { writeContract: withdrawCollateral, isPending } = useWriteContract();
  const { writeContract: liquidate, isPending: isLiquidating } = useWriteContract();

  const { data: loan } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "getLoan",
    args: [loanId],
  });

  if (!loan) return null;

  // wagmi returns the tuple as an object with named fields (from the ABI)
  const loanObj = loan as unknown as {
    borrower: `0x${string}`;
    collateralAmount: bigint;
    loanAmount: bigint;
    requiredRepaymentDrops: bigint;
    deadline: bigint;
    eligibilityExpiry: bigint;
    eligibilityNonce: bigint;
    expectedCommitment: `0x${string}`;
    state: bigint;
    borrowerSourceAddressHash: `0x${string}`;
  };
  const borrower = loanObj.borrower;
  const collateralAmount = loanObj.collateralAmount;
  const loanAmount = loanObj.loanAmount;
  const requiredRepaymentDrops = loanObj.requiredRepaymentDrops;
  const deadline = loanObj.deadline;
  const eligibilityExpiry = loanObj.eligibilityExpiry;
  const eligibilityNonce = loanObj.eligibilityNonce;
  const expectedCommitment = loanObj.expectedCommitment;
  const state = loanObj.state;
  const borrowerSourceAddressHash = loanObj.borrowerSourceAddressHash;

  const stateName = LOAN_STATES[Number(state) as keyof typeof LOAN_STATES] || "UNKNOWN";
  const stateNum = Number(state);

  const handleWithdraw = () => {
    withdrawCollateral({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "withdrawCollateral",
      args: [loanId],
    });
  };

  const handleLiquidate = () => {
    liquidate({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "liquidate",
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
              Loan: {formatUnits(loanAmount, 18)} USDT0
            </div>
          )}
          {requiredRepaymentDrops > 0n && (
            <div className="text-sm text-gray-400">
              Repay: {formatUnits(requiredRepaymentDrops, 6)} XRP (drops)
            </div>
          )}
          {expectedCommitment && expectedCommitment !== "0x0000000000000000000000000000000000000000000000000000000000000000" && (
            <div className="text-xs text-gray-500 break-all mt-1">
              Memo commitment: {expectedCommitment.slice(0, 18)}...
            </div>
          )}
          {borrowerSourceAddressHash && borrowerSourceAddressHash !== "0x0000000000000000000000000000000000000000000000000000000000000000" && (
            <div className="text-xs text-gray-500 mt-0.5">
              XRPL binding: {borrowerSourceAddressHash.slice(0, 10)}...
            </div>
          )}
          {stateNum === 2 && (
            <div className="text-sm text-purple-300 mt-1">
              ⏳ Waiting for FCC attestation — request eligibility, then the TEE signs your credit decision.
            </div>
          )}
        </div>
        <div className="text-right">
          <span
            className={`px-2 py-1 rounded text-xs font-semibold ${
              stateNum === 1
                ? "bg-yellow-900 text-yellow-300"
                : stateNum === 2
                ? "bg-purple-900 text-purple-300"
                : stateNum === 3
                ? "bg-green-900 text-green-300"
                : stateNum === 4
                ? "bg-blue-900 text-blue-300"
                : stateNum === 5
                ? "bg-orange-900 text-orange-300"
                : stateNum === 6
                ? "bg-gray-700 text-gray-300"
                : stateNum === 8
                ? "bg-red-900 text-red-300"
                : "bg-gray-700 text-gray-400"
            }`}
          >
            {stateName}
          </span>
        </div>
      </div>
      {stateNum === 1 && (
        <button
          onClick={handleWithdraw}
          disabled={isPending}
          className="mt-3 w-full bg-red-600 hover:bg-red-500 disabled:bg-gray-700 rounded-lg py-1 text-sm font-semibold transition-colors"
        >
          {isPending ? "Withdrawing..." : "Withdraw Collateral"}
        </button>
      )}
      {stateNum === 4 && (
        <div className="mt-3 space-y-2">
          <div className="text-xs text-blue-300 bg-blue-900/30 rounded p-2">
            Repay {formatUnits(requiredRepaymentDrops, 6)} XRP drops on XRPL testnet with the memo commitment above, then submit the FDC proof to release collateral.
          </div>
          <button
            onClick={handleLiquidate}
            disabled={isLiquidating}
            className="w-full bg-red-600 hover:bg-red-500 disabled:bg-gray-700 rounded-lg py-1 text-sm font-semibold transition-colors"
          >
            {isLiquidating ? "Liquidating..." : "Liquidate (deadline passed)"}
          </button>
        </div>
      )}
      {stateNum === 8 && (
        <div className="mt-3 text-xs text-red-300">
          Loan defaulted — collateral seized. Owner can recover via recoverDefaultedCollateral.
        </div>
      )}
    </div>
  );
}
