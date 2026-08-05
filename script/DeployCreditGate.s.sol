// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title DeployCreditGate - Deployment script for CreditGateVault on Coston2
/// @author CreditGate - Flare Summer Signal hackathon
/// @notice Deploys the vault with verified Coston2 contract addresses and optionally
///         seeds it with USDT0 lending liquidity from the deployer's balance.
///
/// @dev    All addresses verified live from the on-chain ContractRegistry
///         (0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019, chainId 114) on 2026-08-05.
///         Defaults are baked in so the script runs end-to-end with no .env file.
///
/// Usage (one-shot, no .env required):
///   forge script script/DeployCreditGate.s.sol \
///     --rpc-url https://coston2-api.flare.network/ext/C/rpc \
///     --broadcast \
///     --private-key <DEPLOYER_PK>
///
/// Optional env overrides (placed in .env or exported):
///   PRIVATE_KEY          - used only to derive the deployer/teeAuthority default + log
///   FXRP_ADDRESS         - defaults to live Coston2 FXRP
///   USDT0_ADDRESS        - defaults to live Coston2 USDT0
///   TEE_AUTHORITY        - defaults to deployer address (use a separate TEE signer in prod)
///   FTSO_V2_ADDRESS      - defaults to live Coston2 FtsoV2
///   FDC_VERIFICATION_ADDRESS - defaults to live Coston2 FdcVerification
///   COLLATERAL_RATIO_BPS - defaults to 15000 (150%)
///   FTSO_STALENESS_LIMIT - defaults to 300 (5 min)
///   LOAN_DURATION        - defaults to 7 days
///   USDT0_FUND_AMOUNT    - USDT0 to seed the vault for lending (defaults to 10_000 tokens;
///                          uses USDT0 18-decimal representation of USDT0 on Coston2).
///                          Set to 0 to skip funding.
contract DeployCreditGate is Script {
    using SafeERC20 for IERC20;

    // ═══════════════════ Verified Coston2 contract addresses (chainId 114) ═══════════════════
    // All cross-checked against getAllContracts() on the on-chain ContractRegistry
    // 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019. Do NOT change without re-verifying.
    address internal constant FXRP_ADDRESS = 0x0b6A3645c240605887a5532109323A3E12273dc7;
    address internal constant USDT0_ADDRESS = 0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3;
    address internal constant FTSO_V2_ADDRESS = 0xC4e9c78EA53db782E28f28Fdf80BaF59336B304d;
    address internal constant FDC_VERIFICATION_ADDRESS = 0x906507E0B64bcD494Db73bd0459d1C667e14B933;

    function run() external {
        // Deployer private key - used only to derive a sensible TEE_AUTHORITY default and to
        // log the owner's address. The actual broadcast sender is wired by Foundry through
        // the --private-key / --sender CLI flag and the parameterless vm.startBroadcast() below.
        // We accept PRIVATE_KEY from env so chain-specific demo fixtures (e.g. .env.example
        // FAUCET_PRIVATE_KEY) can override it; otherwise we fall back to the CI demo key.
        uint256 pk = vm.envOr(
            "PRIVATE_KEY",
            uint256(0x2e57a6110c08af5c2d076c6cefe5291683ee913ab4f3d7c50fa050059c4306ab)
        );
        address deployer = vm.addr(pk);

        // ── Pull contract addresses (all default to live Coston2 values) ─────────────────
        address fxrp = vm.envOr("FXRP_ADDRESS", FXRP_ADDRESS);
        address usdt0 = vm.envOr("USDT0_ADDRESS", USDT0_ADDRESS);
        // Default TEE signer = deployer (self-attesting for the demo). In production use a
        // dedicated TEE signer whose private key never touches the deployer.
        address teeAuthority = vm.envOr("TEE_AUTHORITY", deployer);
        address ftsoV2 = vm.envOr("FTSO_V2_ADDRESS", FTSO_V2_ADDRESS);
        address fdcVerification =
            vm.envOr("FDC_VERIFICATION_ADDRESS", FDC_VERIFICATION_ADDRESS);

        // ── Protocol parameters ───────────────────────────────────────────────────────────
        uint256 collateralRatioBps = vm.envOr("COLLATERAL_RATIO_BPS", uint256(15_000)); // 150%
        uint64 ftsoStalenessLimit = uint64(vm.envOr("FTSO_STALENESS_LIMIT", uint256(300))); // 5 min
        uint256 loanDuration = vm.envOr("LOAN_DURATION", uint256(7 days));

        // USDT0 on Coston2 has 18 decimals (verified via decimals() 2026-08-05).
        // USDT0_FUND_AMOUNT=10000 means 10_000 token units. The funding step performs no
        // decimals conversion - supply the exact raw amount you want forwarded to the vault.
        uint256 usdt0FundRaw = vm.envOr("USDT0_FUND_AMOUNT", uint256(10_000) * 1e18);

        // ── Deploy ────────────────────────────────────────────────────────────────────────
        // Parameterless startBroadcast() wires the broadcaster to the --private-key / --sender
        // flag passed at the CLI level. This fixes the broken `--private-key 0x…` one-liner
        // (Forge 1.7 does not auto-populate PRIVATE_KEY env from the --private-key flag).
        vm.startBroadcast();

        CreditGateVault vault = new CreditGateVault(
            fxrp,
            usdt0,
            teeAuthority,
            collateralRatioBps,
            ftsoStalenessLimit,
            loanDuration,
            ftsoV2,
            fdcVerification
        );

        console.log("=== CreditGateVault deployed on Coston2 ===");
        console.log("Vault:                ", address(vault));
        console.log("Owner (=broadcaster): ", msg.sender);
        console.log("FXRP (collateral):    ", fxrp);
        console.log("USDT0 (lend asset):   ", usdt0);
        console.log("TEE Authority:        ", teeAuthority);
        console.log("FtsoV2 (XRP/USD):     ", ftsoV2);
        console.log("FdcVerification:      ", fdcVerification);
        console.log("Collateral ratio:     ", collateralRatioBps, "bps");
        console.log("FTSO staleness:       ", uint256(ftsoStalenessLimit), "seconds");
        console.log("Loan duration:        ", loanDuration, "seconds");

        // ── Optional: seed the vault with USDT0 for lending ───────────────────────────────
        // The vault disburses USDT0 to borrowers from its own balance in drawLoan(), so a real
        // deployment must be funded first. We gently skip when the deployer has no USDT0
        // (e.g. a freshly-funded faucet wallet) so the script succeeds for the deploy-only
        // path. After funding the deployer elsewhere, re-run with USDT0_FUND_AMOUNT>0 or call
        // IERC20(usdt0).transfer(vault, amount) directly.
        if (usdt0FundRaw != 0) {
            uint256 deployerBal = IERC20(usdt0).balanceOf(deployer);
            if (deployerBal >= usdt0FundRaw) {
                IERC20(usdt0).transfer(address(vault), usdt0FundRaw);
                console.log("Funded vault with:    ", usdt0FundRaw, "USDT0 (18-decimal raw)");
            } else {
                console.log("USDT0 funding skipped - deployer balance < requested:");
                console.log("  have  ", deployerBal);
                console.log("  want  ", usdt0FundRaw);
                console.log("Send USDT0 to the deployer, then transfer to the vault.");
            }
        } else {
            console.log("USDT0 funding disabled (USDT0_FUND_AMOUNT=0)");
        }

        console.log("Vault USDT0 balance:", IERC20(usdt0).balanceOf(address(vault)));

        vm.stopBroadcast();
    }
}
