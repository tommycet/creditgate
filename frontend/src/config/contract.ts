// CreditGate Contract Configuration for Coston2
export const CREDIT_GATE_CONFIG = {
  chainId: 114,
  rpcUrl: "https://coston2-api.flare.network/ext/C/rpc",
  explorerUrl: "https://coston2-explorer.flare.network",
  contracts: {
    creditGateVault: process.env.NEXT_PUBLIC_VAULT_ADDRESS || "0x0000000000000000000000000000000000000000",
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
} as const;

export type LoanState = keyof typeof LOAN_STATES;
