// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {CreditGateVault} from "../src/CreditGateVault.sol";

/// @title DeployCreditGate — Deployment script for CreditGateVault on Coston2
/// @dev Usage:
///   1. Copy .env.example to .env and fill in PRIVATE_KEY
///   2. forge script script/DeployCreditGate.s.sol --rpc-url coston2 --broadcast --verify
///
/// Coston2 addresses (chain ID 114):
///   FXRP:       0x0b6A3645c240605887a5532109323A3E12273dc7 (6 decimals)
///   USDT0:      0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3 (6 decimals)
///   FtsoV2:     See Flare documentation for current Coston2 FTSO address
///   FdcVerification: 0x906507E0B64bcD494Db73bd0459d1C667e14B933
contract DeployCreditGate is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Coston2 contract addresses
        address fxrp = vm.envOr("FXRP_ADDRESS", address(0x0b6A3645c240605887a5532109323A3E12273dc7));
        address usdt0 = vm.envOr("USDT0_ADDRESS", address(0x479854495cefBc8D12B971A3Ec4d18E6dbcE81a3));
        address teeAuthority = vm.envAddress("TEE_AUTHORITY");
        address ftsoV2 = vm.envAddress("FTSO_V2_ADDRESS");
        address fdcVerification = vm.envOr("FDC_VERIFICATION_ADDRESS", address(0x906507E0B64bcD494Db73bd0459d1C667e14B933));

        // Protocol parameters
        uint256 collateralRatioBps = vm.envOr("COLLATERAL_RATIO_BPS", uint256(15_000)); // 150%
        uint64 ftsoStalenessLimit = uint64(vm.envOr("FTSO_STALENESS_LIMIT", uint256(300))); // 5 minutes
        uint256 loanDuration = vm.envOr("LOAN_DURATION", uint256(7 days));

        vm.startBroadcast(deployerPrivateKey);

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

        console.log("CreditGateVault deployed at:", address(vault));
        console.log("Owner:", vm.addr(deployerPrivateKey));
        console.log("TEE Authority:", teeAuthority);
        console.log("Collateral Ratio:", collateralRatioBps, "bps");
        console.log("FTSO Staleness:", ftsoStalenessLimit, "seconds");
        console.log("Loan Duration:", loanDuration, "seconds");

        vm.stopBroadcast();
    }
}
