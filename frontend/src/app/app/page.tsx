"use client";

import { useState, useEffect } from "react";
import toast from "react-hot-toast";
import { useAccount, useWriteContract, useReadContract, useChainId, useSwitchChain, useWaitForTransactionReceipt } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { parseUnits, formatUnits, keccak256, stringToHex, isAddress } from "viem";
import { ErrorBoundary } from "@/components/ErrorBoundary";
import { CREDIT_GATE_CONFIG, LOAN_STATES, isConfigured } from "@/config/contract";
import { CREDIT_GATE_ABI, ERC20_ABI } from "@/lib/abi";

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

  // Write contract hooks — use writeContractAsync for toast.promise lifecycle
  const { writeContractAsync: depositCollateral, isPending: isDepositing, error: depositError } = useWriteContract();
  const { writeContractAsync: requestEligibility, isPending: isRequesting, error: requestError } = useWriteContract();
  const { writeContractAsync: drawLoan, isPending: isDrawing, error: drawError } = useWriteContract();
  const { writeContractAsync: withdrawCollateral, isPending: isWithdrawing, error: withdrawError } = useWriteContract();
  const { writeContractAsync: registerXRPL, isPending: isRegistering, error: registerError } = useWriteContract();
  const { writeContractAsync: approveUsdt0, isPending: isApproving, error: approveError } = useWriteContract();

  const txError = depositError || requestError || drawError || withdrawError || registerError || approveError;

  // Network mismatch detection — Coston2 is chain ID 114
  const chainId = useChainId();
  const { switchChain, isPending: isSwitchingNetwork } = useSwitchChain();
  const wrongNetwork = !!address && chainId !== CREDIT_GATE_CONFIG.chainId;

  const [xrplAddress, setXrplAddress] = useState("");
  const [fccJson, setFccJson] = useState("");
  // S2: client-side validation errors for the user-pasted FCC JSON
  const [fccError, setFccError] = useState<string | null>(null);
  // S4: pending + confirmed tx hashes plus a transient success toast
  const [pendingTxHash, setPendingTxHash] = useState<`0x${string}` | undefined>(undefined);
  const [_successToast, setSuccessToast] = useState<string | null>(null); // kept for compat

  // Submit eligibility attestation — S4: capture the tx hash + error so we can
  // wait for confirmation and show a success toast once it is mined.
  const {
    writeContract: submitEligibilityTx,
    isPending: isSubmitting,
    data: submitTxData,
    error: submitError,
  } = useWriteContract();

  // S4: track when the most-recent write broadcast is confirmed on-chain. We key
  // on `pendingTxHash` (set in handleSubmitEligibility) so this hook follows a
  // single hashed stream rather than tying to one specific write hook.
  const { data: txReceipt, isLoading: isConfirming } = useWaitForTransactionReceipt({
    hash: pendingTxHash,
  });

  // S4: when a tx that we broadcast confirms, surface a toast + auto-clear later
  useEffect(() => {
    if (txReceipt && pendingTxHash) {
      toast.success(`Transaction confirmed — ${pendingTxHash.slice(0, 10)}…${pendingTxHash.slice(-6)}`);
      setPendingTxHash(undefined);
    }
  }, [txReceipt, pendingTxHash]);

  // Read the borrower's XRPL binding
  const { data: xrplBindingRaw } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "borrowerXRPLAddressHash",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const xrplBound = xrplBindingRaw && (xrplBindingRaw as `0x${string}`) !== "0x0000000000000000000000000000000000000000000000000000000000000000";

  // Read USDT0 allowance for the vault — S3: use proper ERC20 ABI, not the vault ABI
  const { data: usdt0AllowanceRaw, refetch: refetchAllowance } = useReadContract({
    address: CREDIT_GATE_CONFIG.contracts.usdt0 as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, vaultAddress] : undefined,
    query: { enabled: !!address },
  });
  const usdt0Allowance = (usdt0AllowanceRaw ?? 0n) as bigint;

  // Read token balances for display — S3: ERC20_ABI for token balanceOf reads
  const { data: fxrpBalanceRaw } = useReadContract({
    address: CREDIT_GATE_CONFIG.contracts.fxrp as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const fxrpBalance = (fxrpBalanceRaw ?? 0n) as bigint;

  const { data: usdt0BalanceRaw } = useReadContract({
    address: CREDIT_GATE_CONFIG.contracts.usdt0 as `0x${string}`,
    abi: ERC20_ABI,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address },
  });
  const usdt0Balance = (usdt0BalanceRaw ?? 0n) as bigint;

  const handleDeposit = () => {
    if (!depositAmount) return;
    toast.promise(
      depositCollateral({
        address: vaultAddress,
        abi: CREDIT_GATE_ABI,
        functionName: "depositCollateral",
        args: [parseUnits(depositAmount, 6)],
      }),
      {
        loading: "Depositing collateral…",
        success: "Collateral deposited!",
        error: (err) => err?.shortMessage ?? "Deposit failed",
      }
    );
  };

  const handleRegisterXRPL = () => {
    if (!xrplAddress.trim()) return;
    const hash = keccak256(stringToHex(xrplAddress.trim()));
    toast.promise(
      registerXRPL({
        address: vaultAddress,
        abi: CREDIT_GATE_ABI,
        functionName: "registerXRPLAddress",
        args: [hash],
      }),
      {
        loading: "Binding XRPL address…",
        success: "XRPL address bound!",
        error: (err) => err?.shortMessage ?? "Binding failed",
      }
    );
  };

  const handleApproveUsdt0 = () => {
    if (!loanAmount) return;
    toast.promise(
      approveUsdt0({
        address: CREDIT_GATE_CONFIG.contracts.usdt0 as `0x${string}`,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [vaultAddress, parseUnits(loanAmount, 18)],
      }),
      {
        loading: "Approving USDT0…",
        success: "USDT0 approved!",
        error: (err) => err?.shortMessage ?? "Approval failed",
      }
    );
  };

  // S2: helper to validate FCC attestation fields before on-chain submission
  const validateFccAttestation = (att: Record<string, unknown>): string | null => {
    if (!att || typeof att !== "object") return "Invalid JSON: expected an object";
    if (!isAddress(att.borrower as string))
      return "Invalid borrower: must be a valid Ethereum address (0x…)";
    const limit = Number(att.limit);
    if (!Number.isFinite(limit) || limit <= 0) return "Invalid limit: must be a positive integer";
    const expiry = Number(att.expiry);
    if (!Number.isFinite(expiry) || expiry <= 0) return "Invalid expiry: must be a positive integer";
    const nonce = att.nonce;
    if (typeof nonce !== "number" || !Number.isFinite(nonce) || nonce < 0)
      return "Invalid nonce: must be a non-negative integer";
    const v = att.v;
    if (v !== 27 && v !== 28) return "Invalid v: must be 27 or 28";
    if (typeof att.r !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(att.r))
      return "Invalid r: must be a 32-byte hex string (0x + 64 hex chars)";
    if (typeof att.s !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(att.s))
      return "Invalid s: must be a 32-byte hex string (0x + 64 hex chars)";
    return null; // all fields valid
  };

  const handleSubmitEligibility = (loanId: bigint) => {
    if (!fccJson) return;
    setFccError(null);
    try {
      const att = JSON.parse(fccJson);
      const error = validateFccAttestation(att);
      if (error) {
        setFccError(error);
        return;
      }
      const txResult = submitEligibilityTx({
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
      setFccError(`Invalid FCC JSON — check format and try again. ${(e as Error).message ?? ""}`);
      console.error("Invalid FCC JSON:", e);
    }
  };

  // S4: wagmi writeContract is async — the tx hash lands in `data` (submitTxData)
  // after the mutation fires. Once it does, pipe it into pendingTxHash so the
  // useWaitForTransactionReceipt effect can track on-chain confirmation.
  useEffect(() => {
    if (submitTxData) setPendingTxHash(submitTxData);
  }, [submitTxData]);

  const handleRequestEligibility = (loanId: bigint) => {
    toast.promise(
      requestEligibility({
        address: vaultAddress,
        abi: CREDIT_GATE_ABI,
        functionName: "requestEligibility",
        args: [loanId],
      }),
      {
        loading: "Requesting eligibility…",
        success: "Eligibility requested!",
        error: (err) => err?.shortMessage ?? "Request failed",
      }
    );
  };

  const handleDrawLoan = (loanId: bigint) => {
    if (!loanAmount) return;
    toast.promise(
      drawLoan({
        address: vaultAddress,
        abi: CREDIT_GATE_ABI,
        functionName: "drawLoan",
        args: [loanId, parseUnits(loanAmount, 18)],
        value: 0n,
      }),
      {
        loading: "Drawing loan…",
        success: "Loan drawn!",
        error: (err) => err?.shortMessage ?? "Draw failed",
      }
    );
  };

  const handleWithdraw = (loanId: bigint) => {
    toast.promise(
      withdrawCollateral({
        address: vaultAddress,
        abi: CREDIT_GATE_ABI,
        functionName: "withdrawCollateral",
        args: [loanId],
      }),
      {
        loading: "Withdrawing collateral…",
        success: "Collateral withdrawn!",
        error: (err) => err?.shortMessage ?? "Withdrawal failed",
      }
    );
  };

  if (!isConfigured) {
    return (
      <main className="min-h-screen bg-gray-950 text-white">
        <div className="container mx-auto px-4 py-8">
          <div className="flex justify-between items-center mb-8">
            <h1 className="text-2xl font-bold">CreditGate Vault</h1>
            <ConnectButton />
          </div>
          {/* S1: zero-address guard — refuse to render interactive UI when the
               vault address is unset so no tx can ever target address(0). */}
          <div
            className="bg-red-900/60 border border-red-500 rounded-lg p-6 max-w-2xl mx-auto"
            role="alert"
            aria-live="assertive"
          >
            <p className="text-red-300 text-lg font-bold">⚠ Configuration Error</p>
            <p className="text-red-200 text-sm mt-2">
              The vault address (<code className="font-mono">NEXT_PUBLIC_VAULT_ADDRESS</code>) is
              not set. CreditGate cannot interact with the chain until you set it to your deployed
              <span className="font-mono"> CreditGateVault</span> address on Flare Coston2.
            </p>
            <p className="text-red-200/80 text-xs mt-3">
              Until then, deposits, loans, and withdrawals are disabled to prevent sending
              transactions to the zero address.
            </p>
          </div>
        </div>
      </main>
    );
  }

  return (
    <ErrorBoundary>
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
            <p className="text-red-200 text-xs mt-1 break-all">
              {txError?.message || String(txError)}
            </p>
          </div>
        )}

        {/* S4: success toast now handled by react-hot-toast — no manual banner */}

        {/* S4: pending tx confirmation indicator */}
        {isConfirming && (
          <div
            className="mb-6 bg-blue-900/60 border border-blue-500 rounded-lg p-4"
            role="status"
            aria-live="polite"
          >
            <p className="text-blue-300 text-sm font-semibold">
              ⏳ Waiting for on-chain confirmation…
            </p>
            <p className="text-blue-200 text-xs mt-1">
              {pendingTxHash && `Tx: ${pendingTxHash.slice(0, 10)}…${pendingTxHash.slice(-6)}`}
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
          <div className="mb-6 grid grid-cols-1 sm:grid-cols-2 gap-4 max-w-4xl mx-auto">
            <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 text-center min-w-0">
              <div className="text-xs text-gray-400">Your FXRP Balance</div>
              <div className="text-lg font-semibold truncate">{formatUnits(fxrpBalance, 6)}</div>
            </div>
            <div className="bg-gray-900 rounded-lg p-3 border border-gray-700 text-center">
              <div className="text-xs text-gray-400">Your USDT0 Balance</div>
              <div className="text-lg font-semibold truncate">{formatUnits(usdt0Balance, 18)}</div>
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
                <div className="flex flex-col sm:flex-row gap-3">
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
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
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

            {/* FCC Attestation Panel — S2: inline validation error display */}
            <div className="bg-gray-900 rounded-lg p-6 border border-gray-700">
              <h2 className="text-xl font-semibold mb-4">Submit FCC Attestation</h2>
              <div className="space-y-3">
                <div className="text-xs text-gray-400">
                  After requesting eligibility, the FCC handler (:8080) evaluates your credit and returns a signed attestation JSON. Paste it below.
                </div>
                <input
                  type="text"
                  value={fccJson}
                  onChange={(e) => { setFccJson(e.target.value); setFccError(null); }}
                  placeholder='{"borrower":"0x...","limit":"100000000","expiry":"...","nonce":0,"revocationVersion":0,"v":27,"r":"0x...","s":"0x..."}'
                  className="w-full bg-gray-800 border border-gray-600 rounded-lg px-3 py-2 text-xs font-mono focus:outline-none focus:border-purple-500"
                />
                {/* S2: inline red error when validation fails */}
                {fccError && (
                  <p className="text-red-400 text-xs font-semibold" role="alert">
                    {fccError}
                  </p>
                )}
                {/* S4: submit error from wagmi */}
                {submitError && (
                  <p className="text-red-400 text-xs font-semibold" role="alert">
                    {submitError?.message ?? String(submitError)}
                  </p>
                )}
                <input
                  type="number"
                  value={selectedLoanId}
                  onChange={(e) => setSelectedLoanId(e.target.value)}
                  placeholder="Loan ID"
                  className="w-full bg-gray-800 border border-gray-600 rounded-lg px-4 py-2 focus:outline-none focus:border-blue-500 text-sm"
                />
                <button
                  onClick={() => selectedLoanId && handleSubmitEligibility(BigInt(selectedLoanId))}
                  disabled={isSubmitting || isConfirming || !selectedLoanId || !fccJson}
                  className="w-full bg-purple-600 hover:bg-purple-500 disabled:bg-gray-700 rounded-lg py-2 font-semibold transition-colors text-sm"
                >
                  {isSubmitting ? "Submitting..." : isConfirming ? "Confirming…" : "Submit Eligibility"}
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
    </ErrorBoundary>
  );
}

// S49: Auction duration is a public constant on the vault (1 hour). We
// hardcode the value here because reading a `uint256 public constant` is not
// exposed through the ABI (constants are compile-time). The contract mirrors
// this same 3600s value, so the countdown stays in sync with on-chain logic.
const AUCTION_DURATION_SECONDS = 3600;

// S49: Aave-style health factor is scaled to 1e18 on-chain. type(uint256).max
// is returned for loans with no outstanding debt to liquidate (non-FUNDED /
// non-AUCTION), so we display a badge only for FUNDED (4) and AUCTION (9).
function isMaxUint256(v: bigint): boolean {
  return v === 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffn;
}

// S49: Render the on-chain health factor next to a loan, with traffic-light
// color coding: green > 1.5, yellow 1.0–1.5, red < 1.0. Only shown for loans
// that actually have live collateralised debt (FUNDED or AUCTION).
function HealthFactorBadge({ loanId }: { loanId: bigint }) {
  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;
  // getHealthFactor is payable (forwards the FTSO query fee in msg.value),
  // but the fee is 0 on Coston2 today. wagmi's useReadContract does not expose
  // a `value` field, so we read it as a normal (zero-value) call — calling a
  // payable function without attached value works because msg.value defaults to
  // 0, which is exactly what the FTSO query requires on Coston2.
  const { data, error } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "getHealthFactor",
    args: [loanId],
    query: { refetchInterval: 15000 },
  });

  if (error) {
    return (
      <span
        className="ml-2 px-2 py-0.5 rounded text-xs font-semibold bg-gray-700 text-gray-300"
        title={`health factor read failed: ${error.message ?? String(error)}`}
      >
        HF: ?
      </span>
    );
  }
  if (data === undefined) {
    return (
      <span className="ml-2 px-2 py-0.5 rounded text-xs font-semibold bg-gray-700 text-gray-400">
        HF: …
      </span>
    );
  }
  const hf = data as bigint;
  if (isMaxUint256(hf)) {
    // No outstanding debt — don't clutter the card with a badge.
    return null;
  }
  // 1e18-scaled → compare as decimals of 1.0.
  const ratio = Number(hf) / 1e18;
  const tone =
    ratio >= 1.5
      ? "bg-green-900 text-green-300"
      : ratio >= 1.0
      ? "bg-yellow-900 text-yellow-300"
      : "bg-red-900 text-red-300";
  const label = ratio >= 1.5 ? "healthy" : ratio >= 1.0 ? "watch" : "at risk";
  return (
    <span
      className={`ml-2 px-2 py-0.5 rounded text-xs font-semibold ${tone}`}
      title={`health factor = ${ratio.toFixed(3)} (1e18-scaled). <1.0 means liquidatable.`}
    >
      HF: {ratio.toFixed(2)} · {label}
    </span>
  );
}

// S49: Live Dutch-auction panel. Shown only while a loan is in the AUCTION (9)
// state. Reads `auctions(loanId)` for startTimestamp/highestBidder/ highestBid
// and `getAuctionPrice(loanId)` for the current decaying price. Lets a user
// place a bid (bidOnLiquidation), and once AUCTION_DURATION has elapsed, shows
// a "Finalize Auction" button (finalizeAuction).
function AuctionPanel({ loanId }: { loanId: bigint }) {
  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;
  const { writeContract: placeBid, isPending: isBidding } = useWriteContract();
  const { writeContract: finalize, isPending: isFinalizing } = useWriteContract();
  const [bidAmount, setBidAmount] = useState("");
  // Tick once a second so the countdown + finalize-eligibility roll live.
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);

  // Read the LiquidationAuction struct (public mapping getter).
  const { data: auctionRaw } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "auctions",
    args: [loanId],
  });
  // Read the current decaying price. This reverts if state != AUCTION, so wagmi
  // surfaces it as `error`; we guard the hook on state == 9 at the call site
  // (AuctionPanel only renders from LoanCard when stateNum === 9), which keeps
  // the revert from firing in practice.
  const { data: priceRaw, error: priceError } = useReadContract({
    address: vaultAddress,
    abi: CREDIT_GATE_ABI,
    functionName: "getAuctionPrice",
    args: [loanId],
  });

  if (!auctionRaw) {
    return <div className="text-xs text-gray-500 mt-2">Loading auction…</div>;
  }
  const auction = auctionRaw as {
    startPrice: bigint;
    startTimestamp: bigint;
    highestBidder: `0x${string}`;
    highestBid: bigint;
  };
  const startTs = Number(auction.startTimestamp);
  const endTs = startTs + AUCTION_DURATION_SECONDS;
  const remaining = endTs - now;
  const expired = remaining <= 0;
  const hasBid = auction.highestBidder !== "0x0000000000000000000000000000000000000000";
  const currentPrice = (priceRaw ?? 0n) as bigint;

  const handleBid = () => {
    if (!bidAmount) return;
    placeBid({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "bidOnLiquidation",
      args: [loanId, parseUnits(bidAmount, 18)],
    });
  };
  const handleFinalize = () => {
    finalize({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "finalizeAuction",
      args: [loanId],
    });
  };

  return (
    <div className="mt-3 bg-purple-950/40 border border-purple-700 rounded-lg p-3 space-y-2">
      <div className="text-sm font-semibold text-purple-300">🇳🇱 Dutch Liquidation Auction</div>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2 text-xs text-gray-300">
        <div>
          <div className="text-gray-500">Start price</div>
          <div className="font-mono">{formatUnits(auction.startPrice, 18)} USDT0</div>
        </div>
        <div>
          <div className="text-gray-500">Current price</div>
          <div className="font-mono text-purple-200">
            {priceError
              ? "— (auction closed)"
              : `${formatUnits(currentPrice, 18)} USDT0`}
          </div>
        </div>
        <div>
          <div className="text-gray-500">Time remaining</div>
          <div className={`font-mono ${expired ? "text-red-300" : "text-green-300"}`}>
            {expired
              ? "Auction ended"
              : `${Math.floor(remaining / 60)}m ${remaining % 60}s`}
          </div>
        </div>
        <div>
          <div className="text-gray-500">Highest bidder</div>
          <div className="font-mono text-xs">
            {hasBid
              ? `${auction.highestBidder.slice(0, 8)}…${auction.highestBidder.slice(-4)}`
              : "No bids yet"}
          </div>
        </div>
      </div>
      {hasBid && (
        <div className="text-xs text-gray-400">
          Highest bid: {formatUnits(auction.highestBid, 18)} USDT0
        </div>
      )}

      {/* Place Bid — only meaningful while the auction window is open. */}
      {!expired && (
        <div className="flex flex-col sm:flex-row gap-2">
          <input
            type="number"
            value={bidAmount}
            onChange={(e) => setBidAmount(e.target.value)}
            placeholder={`Bid ≥ ${priceError ? "—" : formatUnits(currentPrice, 18)} USDT0`}
            className="flex-1 bg-gray-800 border border-gray-600 rounded-lg px-3 py-1.5 text-sm focus:outline-none focus:border-purple-500"
          />
          <button
            onClick={handleBid}
            disabled={isBidding || !bidAmount}
            className="bg-purple-600 hover:bg-purple-500 disabled:bg-gray-700 rounded-lg px-4 py-1.5 text-sm font-semibold transition-colors whitespace-nowrap"
          >
            {isBidding ? "Bidding…" : "Place Bid"}
          </button>
        </div>
      )}

      {/* Finalize Auction — available to anyone once AUCTION_DURATION elapses. */}
      {expired && (
        <button
          onClick={handleFinalize}
          disabled={isFinalizing}
          className="w-full bg-orange-600 hover:bg-orange-500 disabled:bg-gray-700 rounded-lg py-1.5 text-sm font-semibold transition-colors"
        >
          {isFinalizing ? "Finalizing…" : "Finalize Auction"}
        </button>
      )}
    </div>
  );
}

function LoanCard({ loanId }: { loanId: bigint }) {
  const vaultAddress = CREDIT_GATE_CONFIG.contracts.creditGateVault as `0x${string}`;
  const { writeContract: withdrawCollateral, isPending } = useWriteContract();
  const { writeContract: liquidate, isPending: isLiquidating } = useWriteContract();
  // S49: startLiquidationAuction is payable (forwards the FTSO query fee; 0 on
  // Coston2 today). We attach value: 0n rather than asking the user to set one.
  const { writeContract: startAuction, isPending: isStartingAuction } = useWriteContract();

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

  // S49: FUNDED loans past their deadline are liquidatable via the new Dutch
  // auction path. Keep the legacy "Liquidate" button too (it directly seizes
  // collateral without an auction), but prioritise the auction entry point.
  const deadlinePassed = deadline > 0n && Number(deadline) <= Math.floor(Date.now() / 1000);

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

  // S49: kick off the Dutch-auction liquidation (payable — value: 0n on Coston2).
  const handleStartAuction = () => {
    startAuction({
      address: vaultAddress,
      abi: CREDIT_GATE_ABI,
      functionName: "startLiquidationAuction",
      args: [loanId],
      value: 0n,
    });
  };

  return (
    <div className="bg-gray-800 rounded-lg p-4 border border-gray-600">
      <div className="flex flex-col sm:flex-row sm:justify-between sm:items-start gap-2">
        <div>
          <div className="font-semibold">
            Loan #{loanId.toString()}
            {/* S49: health factor badge for live debt positions (FUNDED/AUCTION). */}
            {(stateNum === 4 || stateNum === 9) && <HealthFactorBadge loanId={loanId} />}
          </div>
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
                : stateNum === 9
                ? "bg-fuchsia-900 text-fuchsia-300"
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
          {/* S49: new Dutch-auction liquidation entry point — the recommended
               path once the loan deadline has passed. Anyone can call it. */}
          {deadlinePassed && (
            <button
              onClick={handleStartAuction}
              disabled={isStartingAuction}
              className="w-full bg-fuchsia-600 hover:bg-fuchsia-500 disabled:bg-gray-700 rounded-lg py-1 text-sm font-semibold transition-colors"
            >
              {isStartingAuction ? "Starting auction…" : "Start Liquidation Auction"}
            </button>
          )}
          <button
            onClick={handleLiquidate}
            disabled={isLiquidating}
            className="w-full bg-red-600 hover:bg-red-500 disabled:bg-gray-700 rounded-lg py-1 text-sm font-semibold transition-colors"
          >
            {isLiquidating ? "Liquidating..." : "Liquidate (deadline passed)"}
          </button>
        </div>
      )}
      {/* S49: Dutch-auction panel — current price, countdown, bid input,
           highest bidder, finalize button. Only while state === AUCTION (9). */}
      {stateNum === 9 && <AuctionPanel loanId={loanId} />}
      {stateNum === 8 && (
        <div className="mt-3 text-xs text-red-300">
          Loan defaulted — collateral seized. Owner can recover via recoverDefaultedCollateral.
        </div>
      )}
    </div>
  );
}
