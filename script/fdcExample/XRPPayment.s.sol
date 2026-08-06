// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {FDCBase} from "./Base.s.sol";
import {console} from "forge-std/Script.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcVerification.sol";
import {IXRPPayment} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title XRPPayment — FDC proof verification script for CreditGate repayment
/// @dev Demonstrates the full FDC flow for verifying an XRPL payment:
///      1. Request attestation via FdcHub
///      2. Wait for voting round finalization
///      3. Verify the proof via FdcVerification
///
/// Usage:
///   forge script script/fdcExample/XRPPayment.s.sol \
///     --rpc-url coston2 --broadcast \
///     --sig "run(bytes32)" -- <XRPL_TX_HASH>
contract XRPPayment is FDCBase {
    // Coston2 FdcVerification address
    address constant FDC_VERIFICATION = 0x906507E0B64bcD494Db73bd0459d1C667e14B933;

    /// @notice Request and verify an XRPPayment attestation
    /// @param transactionId The XRPL transaction hash to verify
    function run(bytes32 transactionId) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proofOwner = vm.addr(deployerPrivateKey);

        console.log("=== Step 1: Request FDC Attestation ===");
        console.log("Transaction ID:", vm.toString(transactionId));
        console.log("Proof Owner:", proofOwner);

        vm.startBroadcast(deployerPrivateKey);
        _requestXRPPaymentAttestation(transactionId, proofOwner, false);
        vm.stopBroadcast();

        console.log("");
        console.log("=== Step 2: Wait for Voting Round ===");
        console.log("After the voting round finalizes (typically 90-180 seconds),");
        console.log("fetch the proof from the Flare FDC API and verify it on-chain.");
        console.log("");
        console.log("FDC API endpoint: https://coston2-fdc-api.flare.network/");
        console.log("Proof fetch: GET /api/tx-proof/XRP/<transactionId>");
        console.log("");
        console.log("=== Step 3: Verify On-Chain ===");
        console.log("Once you have the proof, call verifyXRPPayment() on:");
        console.log("  FdcVerification:", FDC_VERIFICATION);
        console.log("  Or use CreditGateVault.submitRepaymentProof() to close a loan.");
    }

    /// @notice Verify a pre-fetched FDC proof on-chain
    /// @param proof The complete IXRPPayment.Proof from the FDC API
    function verifyProof(IXRPPayment.Proof calldata proof) external view {
        IFdcVerification fdcVerification = IFdcVerification(FDC_VERIFICATION);
        bool proved = fdcVerification.verifyXRPPayment(proof);

        console.log("=== FDC Proof Verification ===");
        console.log("Proved:", proved);

        if (proved) {
            IXRPPayment.ResponseBody memory resp = proof.data.responseBody;
            console.log("Status:", resp.status);
            console.log("Received Amount:", resp.receivedAmount);
            console.log("Has Memo Data:", resp.hasMemoData);
            if (resp.hasMemoData) {
                console.log("First Memo Data:", vm.toString(resp.firstMemoData));
            }
            console.log("Source Address Hash:", vm.toString(resp.sourceAddressHash));
            console.log("Receiving Address Hash:", vm.toString(resp.receivingAddressHash));
        }
    }
}
