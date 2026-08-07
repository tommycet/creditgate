// Content sourced from evidence/live-deployment.md.
// Auto-generated — do not edit by hand.
export const LIVE_DEPLOYMENT_MD: string = `# Live Deployment Evidence — CreditGateVault on Coston2

## Deployment Details

| Field | Value |
|-------|-------|
| **Vault Address** | \`0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939\` |
| **Chain** | Coston2 (Chain ID 114) |
| **RPC** | \`https://coston2-api.flare.network/ext/C/rpc\` |
| **Deploy Block** | 33,686,572 (0x202042c) |
| **Deploy TX** | [\`0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb\`](https://coston2-explorer.flare.network/tx/0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb) |
| **Owner** | \`0x5a3969F3767Cde96D662A94cAa79779073F80A0c\` |
| **Paused** | \`false\` |
| **Next Loan ID** | \`2\` (1 collateral deposit created) |

## Live Transactions

### 1. Vault Deployment
- **TX:** \`0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb\`
- **Block:** 33,686,572
- **Gas Used:** 4,715,838
- **Status:** Success

### 2. FXRP Approve
- **TX:** \`0x7f1905927b661003b5b62be4c2eb8ee67d4c93eb4041c0caea80c89c0ee036b8\`
- **Block:** 33,686,599
- **Action:** Approve vault to spend 1,000,000,000 FXRP (6dp)
- **Status:** Success

### 3. FXRP Collateral Deposit
- **TX:** \`0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149\`
- **Block:** 33,686,600
- **Action:** \`depositCollateral(5000000)\` — 5 FXRP deposited as collateral
- **Event:** \`CollateralDeposited(loanId=1, borrower=0x5a39..., amount=5000000)\`
- **Status:** Success

## Live Vault State (queried 2026-08-06)

\`\`\`
owner()              = 0x5a3969F3767Cde96D662A94cAa79779073F80A0c
paused()             = false
nextLoanId()         = 2
fxrp()               = 0x0b6A3645c240605887a5532109323A3E12273dc7
usdt0()              = 0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3
ftsoV2()             = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d
fdcVerification()    = 0x906507E0B64bcD494Db73bd0459d1C667e14B933
\`\`\`

## Live FTSO Price Feed

\`\`\`
Feed ID:  0x015852502f55534400000000000000000000000000 ("XRP/USD")
Price:    1,050,271,000,000,000,000 (1.050271 USD, 18dp)
Timestamp: 1,785,997,774
\`\`\`

## Vault FXRP Balance

\`\`\`
FXRP balance: 5,000,000 (5 FXRP, 6 decimals)
\`\`\`

## Contract References (all verified live on Coston2)

| Contract | Address | Verified |
|----------|---------|----------|
| CreditGateVault | \`0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939\` | ✅ Has code |
| FXRP (token) | \`0x0b6A3645c240605887a5532109323A3E12273dc7\` | ✅ Has code |
| USDT0 (token) | \`0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3\` | ✅ Has code |
| FtsoV2 | \`0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d\` | ✅ Has code |
| FdcVerification | \`0x906507E0B64bcD494Db73bd0459d1C667e14B933\` | ✅ Has code |
| ContractRegistry | \`0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019\` | ✅ Has code |

## Explorer Links

- **Vault:** https://coston2-explorer.flare.network/address/0x5e74d0a48f6b903b1b1d369e93b2fb9ca6a99939
- **Deploy TX:** https://coston2-explorer.flare.network/tx/0xf2678b28d46729d0aebb0fa9c7590689a1a48cd973de30f5e20e5d96b12771cb
- **Deposit TX:** https://coston2-explorer.flare.network/tx/0x2ba65ff5032b98b5f02d60cc38926e8937fea29f6a3378b00f9b5c08b1614149

## Deploy Command (reproducible)

\`\`\`bash
forge script script/DeployCreditGate.s.sol \\
  --rpc-url https://coston2-api.flare.network/ext/C/rpc \\
  --broadcast \\
  --private-key <DEPLOYER_PK>
\`\`\`

## Verification

All addresses were verified live via \`cast call\` and \`cast code\` on 2026-08-06. The vault is deployed, unpaused, holds 5 FXRP collateral, and reads live FTSO prices.
`;
