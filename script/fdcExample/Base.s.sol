// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {IFdcHub} from "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcHub.sol";
import {IXRPPayment} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";
import {IFdcRequestFeeConfigurations} from "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcRequestFeeConfigurations.sol";

/// @title FDC Base Script — Foundation for FDC attestation request scripts on Coston2
/// @dev Provides utility functions for submitting FDC attestation requests.
///      Coston2 FdcHub: 0x48aC463d7975828989331F4De43341627b9c5f1D
///      Verified live via ContractRegistry on 2026-08-05.
///
///      IMPORTANT (per Flare FDC spec):
///      - `attestationType` is the UTF8-hex of the attestation type name ("XRPPayment"),
///        zero-padded to 32 bytes — NOT a numeric ID.
///      - `sourceId` is the UTF8-hex of the data source name ("testXRP" on testnet,
///        "XRP" on mainnet), zero-padded to 32 bytes.
///      - `messageIntegrityCode` is computed by hashing the expected response; 0 is
///        accepted but weakens the request. See the official flow:
///        https://dev.flare.network/fdc/guides/foundry/payment
abstract contract FDCBase is Script {
    // Coston2 FdcHub address (verified via ContractRegistry 2026-08-05)
    address constant FDC_HUB = 0x48aC463d7975828989331F4De43341627b9c5f1D;
    // Coston2 FdcRequestFeeConfigurations (verified live via ContractRegistry 2026-08-05:
    // cast call 0xaD67FE... "getContractAddressByName(string)(address)" "FdcRequestFeeConfigurations")
    address constant FDC_REQUEST_FEE_CONFIGURATIONS = 0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e;

    // Attestation type name per Flare spec (UTF8 hex zero-padded to 32 bytes)
    // bytes32("XRPPayment") = "XRPPayment" left-padded with zeros.
    bytes32 internal constant ATTESTATION_TYPE_XRPPAYMENT = bytes32("XRPPayment");
    // Source ID for XRPL testnet (UTF8 hex zero-padded to 32 bytes)
    bytes32 internal constant SOURCE_ID_TEST_XRP = bytes32("testXRP");
    // Source ID for XRPL mainnet
    bytes32 internal constant SOURCE_ID_XRP = bytes32("XRP");

    /// @notice Submit an FDC attestation request for XRPPayment
    /// @param transactionId The XRPL transaction hash to attest
    /// @param proofOwner The address authorized to use the proof
    /// @param useMainnetSource Whether to use "XRP" (mainnet) or "testXRP" (testnet) source ID
    function _requestXRPPaymentAttestation(
        bytes32 transactionId,
        address proofOwner,
        bool useMainnetSource
    ) internal returns (uint64 votingRound) {
        IFdcHub fdcHub = IFdcHub(FDC_HUB);

        // Build XRPPayment attestation request body
        IXRPPayment.RequestBody memory reqBody = IXRPPayment.RequestBody({
            transactionId: transactionId,
            proofOwner: proofOwner
        });

        IXRPPayment.Request memory request = IXRPPayment.Request({
            attestationType: ATTESTATION_TYPE_XRPPAYMENT,
            sourceId: useMainnetSource ? SOURCE_ID_XRP : SOURCE_ID_TEST_XRP,
            messageIntegrityCode: bytes32(0),
            requestBody: reqBody
        });

        // ── Read the required request fee (official flow reads this before submit) ──
        bytes memory abiEncodedRequest = abi.encode(request);
        uint256 requestFee = IFdcRequestFeeConfigurations(FDC_REQUEST_FEE_CONFIGURATIONS)
            .getRequestFee(abiEncodedRequest);
        console.log("FDC request fee (wei):", requestFee);

        // Submit the attestation request, paying the fee
        fdcHub.requestAttestation{value: requestFee}(abiEncodedRequest);

        console.log("FDC attestation requested for tx:", vm.toString(transactionId));
        console.log("Proof owner:", proofOwner);
        console.log("Source ID:", useMainnetSource ? "XRP" : "testXRP");
    }
}
