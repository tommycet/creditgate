// CreditGate Contract Configuration for Coston2
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
// Live deployed CreditGateVault on Coston2 (broadcast 2026-08-06).
// Used as the fallback when NEXT_PUBLIC_VAULT_ADDRESS is unset.
const DEPLOYED_VAULT_ADDRESS = "0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939";
const vaultAddr: string = (process.env.NEXT_PUBLIC_VAULT_ADDRESS as string) || DEPLOYED_VAULT_ADDRESS;
// S1: hard guard — if the vault address is the zero address (env var explicitly set to zero),
// callers must refuse to render contract UI so no tx is ever sent to address(0).
export const isConfigured: boolean = vaultAddr !== ZERO_ADDRESS;
export { ZERO_ADDRESS };
if (!isConfigured) {
  console.warn(
    "NEXT_PUBLIC_VAULT_ADDRESS set to the zero address. Set it in .env.local to your deployed CreditGateVault address on Coston2."
  );
}

export const CREDIT_GATE_CONFIG = {
  chainId: 114,
  rpcUrl: "https://coston2-api.flare.network/ext/C/rpc",
  explorerUrl: "https://coston2-explorer.flare.network",
  contracts: {
    creditGateVault: vaultAddr,
    fxrp: "0x0b6A3645c240605887a5532109323A3E12273dc7",
    usdt0: "0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3",
    fdcVerification: "0x906507E0B64bcD494Db73bd0459d1C667e14B933",
  },
} as const;

export const LOAN_STATES = {
  0: "IDLE",
  1: "COLLATERAL_DEPOSITED",
  2: "ELIGIBILITY_PENDING",
  3: "ELIGIBLE",
  4: "FUNDED",
  5: "REPAYMENT_PENDING",
  6: "CLOSED",
  7: "REJECTED",
  8: "DEFAULTED",
  // S49: Dutch liquidation auction in progress (CreditGateVault.AUCTION).
  9: "AUCTION",
} as const;

export type LoanState = keyof typeof LOAN_STATES;
