# Contributing to CreditGate

CreditGate is a private FXRP credit eligibility layer on Flare, built for the Flare Summer Signal hackathon (DoraHacks, Bounty 2: Confidential Compute Apps). A borrower deposits FXRP collateral on Flare Coston2; a Go Flare Confidential Compute (FCC) handler evaluates credit eligibility privately and signs an EIP-191 attestation; the borrower then draws a USDT0 loan priced via FTSO feeds, repays on XRPL, and an FDC verifying contract confirms the repayment on-chain before collateral is released. The codebase spans three layers: Solidity contracts (Foundry), a Go FCC handler, and a Next.js + wagmi + RainbowKit frontend.

Thanks for contributing! This guide covers setup, structure, tests, and conventions.

## Prerequisites

| Tool | Version | Purpose |
| --- | --- | --- |
| [Foundry](https://book.getfoundry.sh/) (`forge`, `cast`) | latest stable | Solidity contracts, tests, deployment |
| [Node.js](https://nodejs.org/) | 18+ | Frontend |
| [npm](https://www.npmjs.com/) | bundled with Node | Frontend dependencies |
| [Go](https://go.dev/) | 1.21+ | FCC handler (`fcc/credit-extension/extension`) |
| Git (with submodule support) | 2.20+ | Cloning with `--recurse-submodules` |

### Toolchain install (one-time, if missing)

```bash
# Foundry
curl -L https://foundry.paradigm.xyz | bash && foundryup

# Go (Debian/Ubuntu)
sudo apt-get install -y golang-go   # or install from https://go.dev/dl/

# Node.js (nvm recommended)
nvm install 18 && nvm use 18
```

## Quick Start

```bash
# 1. Clone with submodules (forge-std, openzeppelin-contracts, flare-periphery)
git clone --recurse-submodules <repo-url> creditgate
cd creditgate

# 2. Solidity deps (idempotent — restores submodules if skipped at clone)
forge install

# 3. Frontend deps
cd frontend
npm install
cp .env.example .env.local   # then edit RPC + contract addresses
cd ..

# 4. Run the Solidity test suite (171 tests across 15 suites)
forge test

# 5. Start the FCC handler (default :8080, /health + /action)
cd fcc/credit-extension/extension
go run .
cd ../..

# 6. Start the frontend dev server
cd frontend && npm run dev   # http://localhost:3000
```

For deployment, copy `.env.example` to `.env`, fill in `PRIVATE_KEY` and `COSTON2_RPC_URL`, then run `forge script script/DeployCreditGate.s.sol --rpc-url coston2 --broadcast`.

## Project Structure

```
creditgate/
├── foundry.toml               # Foundry config (Cancun, optimizer, fuzz runs)
├── remappings.txt             # src/=, @openzeppelin/, @flare/
├── .gitmodules                # forge-std, openzeppelin-contracts, flare-periphery
├── .env.example               # Coston2 addresses + deploy vars
├── src/
│   ├── CreditGateVault.sol    # Main vault: state machine, collateral, loans, FDC verify
│   ├── CreditGateTypes.sol    # Types, custom errors, events, constants
│   └── mocks/                 # MockERC20, MockFtsoV2, MockFdcVerification
├── test/
│   ├── CreditGateVault.t.sol                  # 69 unit tests
│   ├── CreditGateVault.fdc-fixture.t.sol      # 4 FDC lifecycle tests
│   ├── CreditGateVault.invariant.t.sol        # 8 invariant / fuzz tests
│   ├── CreditGateVault.go-tee-compat.t.sol    # 2 cross-language EIP-191 tests
│   ├── CreditGateVault.malicious-reentrancy.t.sol  # 1 malicious-token attack test
│   ├── CreditGateVault.reentrancy.t.sol        # 2 reentrancy / solvency / FTSO-edge
│   ├── CreditGateVault.edge-cases.t.sol        # 15 border-case + security-boundary tests
│   ├── CreditGateVault.views.t.sol            # 15 health-factor + loan/portfolio views
│   └── CreditGateVault.auction.t.sol          # 5 Dutch auction liquidation tests
├── script/
│   ├── DeployCreditGate.s.sol                 # Main deployment
│   └── fdcExample/                            # FDC request/verify scripts
├── fcc/
│   └── credit-extension/
│       ├── contracts/                         # FCC contract interfaces
│       └── extension/
│           ├── main.go
│           ├── handler/handler.go             # Credit eval + EIP-191 signing, /health
│           ├── go.mod / go.sum
│           └── scripts/
├── frontend/
│   ├── package.json
│   ├── .env.example
│   └── src/
│       ├── app/          (Next.js App Router: landing + app + transparency)
│       ├── components/   (wagmi/RainbowKit UI, badges, panels)
│       ├── config/       (chain, contracts, wagmi)
│       ├── lib/  src/  types/  utils/
├── lib/                       # Foundry submodules (do not edit)
├── evidence/                  # Verifiable artifacts: attestation JSON, Coston2/FDC/XRPL fixtures
├── planning/                  # Verdict docs (fdc-review, security-audit, gas-audit, judge-sim, ...)
├── deployments/               # Recorded deployment addresses per chain
├── ARCHITECTURE.md            # EIP-191 payload, FDC flow, Flare primitive addresses
├── DEMO.md                    # 90-second demo script
├── README.md
└── PROGRAM-SUMMARY.md         # Live status snapshot for improvement subagents
```

## How to Run Tests

### Solidity (Foundry)

```bash
forge test                                  # all 171 tests, 15 suites
forge test -vvv                             # verbose traces (useful for failures)
forge test --match-contract CreditGateVault # main unit suite only
forge test --match-test test_RequestLoan    # single test by name
forge test --gas-report                     # gas report
forge coverage                              # coverage -> lcov.info (gitignored)
```

### Frontend (Next.js)

```bash
cd frontend
npm run build      # production build (rendered routes must succeed)
npm run lint       # next lint
npm run dev        # local dev server on :3000
```

### Go FCC handler

```bash
cd fcc/credit-extension/extension
go build ./...     # compile-only check
go run .           # start handler at :8080 (test /health)
go vet ./...       # lint
```

### Full pre-commit sweep

```bash
forge test && (cd frontend && npm run build) && (cd fcc/credit-extension/extension && go build ./...)
```

All three must pass before opening a PR.

## How to Add a New Test

Tests are organized *by concern*, not by a single mega-suite. Choose the file that matches what you are testing:

| You are adding… | Extend this file |
| --- | --- |
| A new unit case for vault behavior (deposit, borrow, repay, release) | `test/CreditGateVault.t.sol` |
| An end-to-end FDC attestation→verify lifecycle case | `test/CreditGateVault.fdc-fixture.t.sol` |
| An invariant property or fuzz test over the state machine | `test/CreditGateVault.invariant.t.sol` |
| A test that must match the Go FCC handler's EIP-191 signing byte-for-byte | `test/CreditGateVault.go-tee-compat.t.sol` |
| A reentrancy / malicious-token / solvency attack test | `test/CreditGateVault.malicious-reentrancy.t.sol` or `test/CreditGateVault.reentrancy.t.sol` |
| Border ratios, expired attestations, double-request rejection, etc. | `test/CreditGateVault.edge-cases.t.sol` |

**Pattern** (forge-std style):

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditGateVault} from "src/CreditGateVault.sol";
// ...existing imports + harness setup from the file you are extending

contract CreditGateVaultNewTest is Test {
    CreditGateVault vault;
    function setUp() public {
        // reuse the existing harness setup in the file you extend
    }

    function test_NewBehavior_RevertsWhenX() public {
        vm.expectRevert(CreditGateTypes.SomeError.selector);
        vault.someFunction();
    }
}
```

Then run `forge test --match-test test_NewBehavior` to iterate quickly. Fuzz tests use `function testFuzz_X(uint256 amount)` parameters; invariant tests are `function invariant_X()` in their own contract.

## Coding Conventions

### Solidity

- **NatSpec is required** on all external/public functions and events: `@dev` for vault internals, `@param`/`@return` on external entrypoints, `@notice` on user-facing functions.
- **Reentrancy guard**: every function that transfers tokens (deposit, draw loan, repay, release collateral, liquidate) must be guarded by `ReentrancyGuard.nonReentrant` or a state-machine lock. The malicious-reentrancy suite exists specifically to defend this invariant — keep it green.
- **SafeERC20**: use `SafeERC20.safeTransfer` / `safeApprove` from OpenZeppelin (`@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`) for *all* ERC-20 transfers. Never call `IERC20.transfer` directly.
- **Custom errors over revert strings**: `CreditGateTypes.sol` defines all errors; `revert SomeError()` (selector-form) is preferred over `require(cond, "msg")` for gas.
- **State machine**: vault flips a `LoanState` enum; functions must `require` the expected state and transition atomically.
- **FTSO prices**: always consume the latest FTSO V2 price via the injected `IFtsoV2` interface (mocked in tests); never hardcode prices.
- **FDC verification**: repayment proof must be confirmed by `FdcVerification` before collateral release — do not bypass this even in tests (use the fixture helpers).
- **USDT0 is 18 decimals on Coston2** — keep decimal handling consistent across all suites.
- **Pragmas**: `pragma solidity ^0.8.24`; target `evm_version = "cancun"` (see `foundry.toml`).

### Go (FCC handler)

- Keep the handler stateless where possible; the `/health` endpoint must return 200 without external deps.
- Use structured logging (`log/slog`).
- EIP-191 signatures produced here MUST be recoverable by Solidity `ecrecover` — extend `go-tee-compat.t.sol` if you change the signing format.

### Frontend (Next.js + wagmi)

- App Router (`src/app`); components in `src/components`.
- Read contract addresses from `src/config` (driven by `.env.local`), never hardcode.
- All user-facing wallet interactions via RainbowKit + wagmi hooks.

### Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(scope): summary
fix(scope): summary
docs: summary
test: summary
chore: summary
```

`scope` is typically `vault`, `fcc`, `frontend`, `deploy`, or omitted for cross-cutting changes.

## Git Workflow

1. Branch off `main`: `git switch -c feat/your-feature`.
2. Keep commits focused; one logical change per commit.
3. All three test commands green before push (see *Full pre-commit sweep*).
4. Open a PR with a clear description referencing the planning verdict it addresses (if any).
5. Submodules (`lib/`) are pinned; do not bump them in a feature PR unless the feature depends on it.

## Questions / Status

Current status (live snapshot): see `PROGRAM-SUMMARY.md` for test counts, deployed addresses, and known gaps. Architecture details: see `ARCHITECTURE.md`. Demo script: see `DEMO.md`.
