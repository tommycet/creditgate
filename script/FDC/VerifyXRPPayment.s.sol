// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {IFdcVerification} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcVerification.sol";
import {IXRPPayment} from
    "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title VerifyXRPPayment — FDC Stage 5 (Interact)
/// @notice Reads the proof JSON written by poll_retrieve_and_verify.py
///         (evidence/fdc/raw-proof-response.json), assembles an
///         `IXRPPayment.Proof`, and calls `FdcVerification.verifyXRPPayment`
///         against the LIVE Coston2 contract.
/// @author CreditGate FDC fine-tune subagent #69
///
/// Usage:
///   forge script script/FDC/VerifyXRPPayment.s.sol \
///     --rpc-url https://coston2-api.flare.network/ext/C/rpc \
///     --sig "run(string)" -- "evidence/fdc/raw-proof-response.json"
///
///   (No `--broadcast` flag is needed; `verifyXRPPayment` is a `view` call
///   on Coston2 and so uses `eth_call` only — no gas, no signer required.)
///
/// Ingested JSON shape (from DA Layer `POST /api/v1/fdc/proof-by-request-round-raw`):
/// {
///   "votingRoundId": <uint>,
///   "merkleRoot":    "0x...",
///   "requestBytes":  "0x...",
///   "proof": {
///     "response_hex":   "0x...",              // ABI-encoded Response struct
///     "attestation_type": "XRPPayment",
///     "proof": ["0x..", "0x..", ...]          // merkleProof bytes32 leaves
///   }
/// }
contract VerifyXRPPayment is Script {
    address constant FDC_VERIFICATION = 0x906507E0B64bcD494Db73bd0459d1C667e14B933;

    function run(string memory proofJsonPath) external view {
        string memory raw = vm.readFile(proofJsonPath);

        // ── Pull the merkleProof bytes32[] and response_hex from the JSON ─────────
        // The DA Layer wraps the proof fields under "proof" (an object containing
        // "response_hex", "attestation_type", and "proof" array of 0x-hex strings).
        bytes memory responseHexRaw = vm.parseJsonBytes(raw, ".proof.response_hex");
        // vm.parseJsonBytes expects the literal field value to be a bytes literal like
        // "0x1234" — but the JSON file has it as a hex string in quotes, so it parses
        // cleanly. If it doesn't parse, fall back: hex string -> bytes via assembly.
        // For simplicity we always re-derive bytes from hex via the helper below.

        // vm.parseJsonString returns the contents WITHOUT surrounding quotes.
        string memory responseHexStr = vm.parseJsonString(raw, ".proof.response_hex");
        bytes memory responseBytes = _hexStringToBytes(responseHexStr);

        // Parse the proof array of hex strings.
        string[] memory proofStrs = vm.parseJsonStringArray(raw, ".proof.proof");
        bytes32[] memory merkleProof = new bytes32[](proofStrs.length);
        for (uint256 i = 0; i < proofStrs.length; i++) {
            merkleProof[i] = vm.parseBytes32(
                string.concat('{"v":"', proofStrs[i], '"}'), ".v"
            );
        }

        // ── ABI-decode the response_hex into IXRPPayment.Response ───────────────
        // response_bytes is the abi-encoded `Response` struct (top-level); decode
        // the first 320+ bytes of the payload.
        IXRPPayment.Response memory decoded = abi.decode(responseBytes, (IXRPPayment.Response));

        // Pull optional top-level handles for the evidence report
        uint256 votingRoundId = vm.parseJsonUint(raw, ".votingRoundId");
        string memory merkleRootHex = vm.parseJsonString(raw, ".merkleRoot");

        console.log("=== FDC verifyXRPPayment against LIVE Coston2 FdcVerification ===");
        console.log("Contract:        ", FDC_VERIFICATION);
        console.log("votingRoundId:   ", votingRoundId);
        console.log("merkleRoot:      ", merkleRootHex);
        console.log("requestBytes:   ", vm.toString(keccak256(bytes(_hexStrStrip(vm.parseJsonString(raw, ".requestBytes"))))));
        console.log("");
        console.log("---- Decoded IXRPPayment.Response ----");
        console.log("attestationType:", vm.toString(decoded.attestationType));
        console.log("sourceId:       ", vm.toString(decoded.sourceId));
        console.log("votingRound:    ", uint256(decoded.votingRound));
        console.log("lowestUsedTimestamp:", uint256(decoded.lowestUsedTimestamp));
        console.log("requestBody.transactionId:", vm.toString(decoded.requestBody.transactionId));
        console.log("requestBody.proofOwner:   ", decoded.requestBody.proofOwner);
        console.log("responseBody.blockNumber:    ", uint256(decoded.responseBody.blockNumber));
        console.log("responseBody.blockTimestamp: ", uint256(decoded.responseBody.blockTimestamp));
        console.log("responseBody.sourceAddress:   ", decoded.responseBody.sourceAddress);
        console.log("responseBody.sourceAddressHash:", vm.toString(decoded.responseBody.sourceAddressHash));
        console.log("responseBody.receivingAddressHash:", vm.toString(decoded.responseBody.receivingAddressHash));
        console.log("responseBody.spentAmount:   ", decoded.responseBody.spentAmount);
        console.log("responseBody.receivedAmount:", decoded.responseBody.receivedAmount);
        console.log("responseBody.hasMemoData:   ", decoded.responseBody.hasMemoData);
        console.log("responseBody.hasDestinationTag:", decoded.responseBody.hasDestinationTag);
        if (decoded.responseBody.hasDestinationTag) {
            console.log("responseBody.destinationTag:", decoded.responseBody.destinationTag);
        }
        console.log("responseBody.status:        ", decoded.responseBody.status);
        console.log("");
        console.log("merkleProof length:", merkleProof.length);
        for (uint256 i = 0; i < merkleProof.length; i++) {
            console.log("  [", i, "]", vm.toString(merkleProof[i]));
        }
        console.log("");

        // ── Assemble the Proof and call verifyXRPPayment ────────────────────────
        IXRPPayment.Proof memory proof = IXRPPayment.Proof({
            merkleProof: merkleProof,
            data: decoded
        });

        bool proved = IFdcVerification(FDC_VERIFICATION).verifyXRPPayment(proof);
        console.log(">>> verifyXRPPayment returned:", proved);
        require(proved, "verifyXRPPayment REVERTED or returned false");
        console.log("");
        console.log("=== FDC Stage 5 SUCCESS: real XRPPayment proof verified on Coston2 ===");
    }

    /// @dev Converts a "0x-hex" string into raw bytes. Falls back gracefully if
    ///      the bytes representation chosen by forge differs from what `vm.parseJsonBytes`
    ///      returns (legacy parser quirks).
    function _hexStringToBytes(string memory s) internal pure returns (bytes memory out) {
        bytes memory b = bytes(s);
        require(b.length >= 2 && b[0] == "0" && b[1] == "x", "needs 0x prefix");
        uint256 hexLen = b.length - 2;
        require(hexLen % 2 == 0, "odd hex length");
        out = new bytes(hexLen / 2);
        for (uint256 i = 0; i < hexLen; i += 2) {
            out[i / 2] = bytes1(uint8(_hexNib(b[2 + i]) * 16 + _hexNib(b[2 + i + 1])));
        }
    }

    function _hexNib(bytes1 c) internal pure returns (uint8 r) {
        if (c >= "0" && c <= "9") return uint8(c) - 48;
        if (c >= "a" && c <= "f") return uint8(c) - 87;
        if (c >= "A" && c <= "F") return uint8(c) - 55;
        revert("invalid hex nibble");
    }

    /// @dev Strips the leading "0x" and trims any trailing whitespace forge may
    ///      attach — purely for log readability of the requestBytes hash.
    function _hexStrStrip(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= 2 && b[0] == "0" && b[1] == "x") {
            bytes memory out = new bytes(b.length - 2);
            for (uint256 i = 0; i < out.length; i++) out[i] = b[i + 2];
            return string(out);
        }
        return s;
    }
}
