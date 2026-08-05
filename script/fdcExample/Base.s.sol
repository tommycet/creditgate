// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {IFdcHub} from "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcHub.sol";
import {IXRPPayment} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title FDC Base Script — Foundation for FDC attestation request scripts on Coston2
/// @dev Provides utility functions for submitting FDC attestation requests.
///      Coston2 FdcHub: 0x48aC463d7975828989331F4De43341627b9c5f1D
abstract contract FDCBase is Script {
    // Coston2 FdcHub address
    address constant FDC_HUB = 0x48aC463d7975828989331F4De43341627b9c5f1D;

    /// @notice Submit an FDC attestation request for XRPPayment
    /// @param transactionId The XRPL transaction hash to attest
    /// @param proofOwner The address authorized to use the proof
    /// @return votingRound The voting round ID where the attestation will be processed
    function _requestXRPPaymentAttestation(
        bytes32 transactionId,
        address proofOwner
    ) internal returns (uint64 votingRound) {
        IFdcHub fdcHub = IFdcHub(FDC_HUB);

        // Build XRPPayment attestation request body
        IXRPPayment.RequestBody memory reqBody = IXRPPayment.RequestBody({
            transactionId: transactionId,
            proofOwner: proofOwner
        });

        // Attestation type ID for XRPPayment (0x08 from Flare docs)
        bytes32 attestationType = bytes32(uint256(8));
        bytes32 sourceId = keccak256("XRP");

        IXRPPayment.Request memory request = IXRPPayment.Request({
            attestationType: attestationType,
            sourceId: sourceId,
            messageIntegrityCode: bytes32(0),
            requestBody: reqBody
        });

        // Submit the attestation request
        fdcHub.requestAttestation{value: 0}(abi.encode(request));

        console.log("FDC attestation requested for tx:", vm.toString(transactionId));
        console.log("Proof owner:", proofOwner);
    }
}
