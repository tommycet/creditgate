// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script, console} from "forge-std/Script.sol";

import {FDCBase} from "./Base.s.sol";
import {IFdcVerification} from "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcVerification.sol";
import {IFdcHub} from "@flarenetwork/flare-periphery-contracts/src/coston2/IFdcHub.sol";
import {IRelay} from "@flarenetwork/flare-periphery-contracts/src/coston2/IRelay.sol";
import {IXRPPayment} from "@flarenetwork/flare-periphery-contracts/src/coston2/IXRPPayment.sol";

/// @title RetrievePayment — FDC Stage 3: Retrieve the merkle proof after voting-round finalization
/// @dev Implements the official Flare 5-stage FDC flow, stage 3 of 5:
///        1. Prepare  — read config, set up data dir
///        2. Submit   — build & submit attestation request        (XRPPayment.s.sol)
///        3. Retrieve  — wait for round finalization, fetch proof  ← THIS SCRIPT
///        4. Deploy    — deploy the verifying contract
///        5. Interact  — call the contract with the proof
///
///      On-chain primitives used (verified Coston2 2026-08-05):
///        FdcHub                   0x48aC463d7975828989331F4De43341627b9c5f1D
///        FdcVerification          0x906507E0B64bcD494Db73b0459d1C667e14B933
///        Relay (via FdcVerification.relay()) — `isFinalized(200, roundId)`,
///          `merkleRoots(200, roundId)`, `getVotingRoundId(blockTimestamp)`.
///        FDC protocol id = 200.
///
///      Reference: https://github.com/flare-foundation/flare-ai-skills/blob/main/skills/flare-fdc-skill/SKILL.md
///      and Flare Developer Hub FDC guides (https://dev.flare.network/fdc/guides/foundry).
///
/// Two entry points are provided because the off-chain actor may need
/// to wait for an asynchronous voting round to finalize:
///   * `run(bytes32 transactionId)`  — estimate the request's voting round and
///     either report the already-finalized proof or print a clear "wait" message
///     with the produced `request.json` payload the submitter carried over.
///   * `runWithRequest(bytes32 attestationType, bytes32 sourceId, bytes32 messageIntegrityCode, bytes32 transactionId, address proofOwner)`
///     — full verbosity path that recomputes the request bytes and saves the proof
///     once the round is finalized.
///
/// Proof retrieval, per the Flare FDC skill and the DA Layer REST API, is an
/// off-chain HTTP POST to the DA Layer API:
///   POST <DA_LAYER_URL>/api/v1/fdc/proof-by-request-round-raw
///   body: { votingRoundId: <uint64>, requestBytes: <0x-hex> }
/// On Coston2 the DA Layer URL is https://coston2-fdc-api.flare.network .
///
/// The proven proof is written to `data/proof-<transactionIdShort>.json` so the
/// Stage 5 "Interact" script can ingest it. This script wraps the on-chain pieces
/// (compute round, check `isFinalized`, read `merkleRoot`) that a deploy script
/// is uniquely able to do, and falls back to instructing the operator to POST to
/// the DA Layer for the leaf/proof bytes themselves (Foundry cannot perform HTTP
/// requests from inside a script). The header of each saved proof file records
/// `votingRoundId`, `merkleRoot`, `requestBytes`, and the attestationType/sourceId
/// so the Interact stage can locate and verify it.
contract RetrievePayment is FDCBase {
    /// @notice Coston2 FdcVerification (same as XRPPayment.s.sol; kept here so
    ///         this script is self-contained — Stage 3 doesn't import XRPPayment).
    address constant FDC_VERIFICATION = 0x906507E0B64bcD494Db73b0459d1C667e14B933;

    /// @notice DA Layer REST endpoint for proof-by-request-round-raw on Coston2.
    ///         Foundry scripts cannot make HTTP calls, so this URL is emitted for
    ///         the operator (or Stage 5) to POST against. Replace with the mainnet
    ///         DA Layer URL when running on Flare mainnet.
    string constant DA_LAYER_URL = "https://coston2-fdc-api.flare.network";

    /// @notice FDC protocol id on the Relay contract (per Flare FDC skill).
    uint256 constant FDC_PROTOCOL_ID = 200;

    /// @notice Default voting-epoch duration on Coston2 (seconds). Used only as a
    ///         sanity check when `block.timestamp` is early; the authoritative
    ///         values come from `IRelay.stateData()`.
    uint256 constant DEFAULT_VOTING_EPOCH_SECONDS = 90;

    /// @notice Maximum number of rounds to tell the operator to wait. Coston2
    ///         rounds are ~90s; we cap advice at four rounds so the prompt stays
    ///         actionable and an operator running it manually won't wait forever.
    uint256 constant MAX_ROUND_WAIT_HINT = 4;

    struct SavedRequest {
        bytes32 attestationType;
        bytes32 sourceId;
        bytes32 messageIntegrityCode;
        bytes32 transactionId;
        address proofOwner;
        bytes   requestBytes;   // abi.encode(IXRPPayment.Request)
        uint64  submittedAtRound; // best-effort voting-round id at submit time
        uint256 submittedBlockTimestamp;
    }

    /// @notice Convenience entry point: estimate the XRPPayment voting round and
    ///         fetch (or instruct how to fetch) the merkle proof.
    /// @dev    Mirrors XRPPayment.s.sol's `run(bytes32)` signature so an operator
    ///         can run the same transactionId through Submit then Retrieve. Whether
    ///         retrieval is possible depends on round finalization (~90–180s).
    /// @param  transactionId   XRPL transaction hash submitted in Stage 2.
    function run(bytes32 transactionId) external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address proofOwner = vm.addr(deployerPrivateKey);

        console.log("=== Stage 3: Retrieve FDC Merkle Proof ===");
        console.log("Transaction ID:", vm.toString(transactionId));
        console.log("Proof Owner:", proofOwner);
        console.log("");

        // Reconstruct the request bytes the way XRPPayment.s.sol's Stage 2 did so
        // the proof lookup targets the same commitment (attestationType, sourceId,
        // messageIntegrityCode, requestBody). messageIntegrityCode was 0 in the
        // submitter; reproduce that here. (If you customized MIC in Stage 2, pass
        // the expected value via `runWithRequest(...)` instead.)
        IXRPPayment.RequestBody memory reqBody = IXRPPayment.RequestBody({
            transactionId: transactionId,
            proofOwner: proofOwner
        });
        IXRPPayment.Request memory request = IXRPPayment.Request({
            attestationType: ATTESTATION_TYPE_XRPPAYMENT,
            sourceId: SOURCE_ID_TEST_XRP,
            messageIntegrityCode: bytes32(0),
            requestBody: reqBody
        });
        bytes memory requestBytes = abi.encode(request);

        _retrieve(
            request.attestationType,
            request.sourceId,
            request.messageIntegrityCode,
            transactionId,
            proofOwner,
            requestBytes
        );
    }

    /// @notice Full entry point: caller supplies every field used in Stage 2.
    ///         Use this when Stage 2 set a non-zero `messageIntegrityCode` or used
    ///         the XRPL mainnet source ("XRP" instead of "testXRP").
    function runWithRequest(
        bytes32 attestationType,
        bytes32 sourceId,
        bytes32 messageIntegrityCode,
        bytes32 transactionId,
        address proofOwner
    ) external {
        IXRPPayment.RequestBody memory reqBody = IXRPPayment.RequestBody({
            transactionId: transactionId,
            proofOwner: proofOwner
        });
        IXRPPayment.Request memory request = IXRPPayment.Request({
            attestationType: attestationType,
            sourceId: sourceId,
            messageIntegrityCode: messageIntegrityCode,
            requestBody: reqBody
        });
        bytes memory requestBytes = abi.encode(request);

        _retrieve(
            attestationType,
            sourceId,
            messageIntegrityCode,
            transactionId,
            proofOwner,
            requestBytes
        );
    }

    /// @notice Core retrieve routine — shared by both entry points.
    function _retrieve(
        bytes32 attestationType,
        bytes32 sourceId,
        bytes32 messageIntegrityCode,
        bytes32 transactionId,
        address proofOwner,
        bytes memory requestBytes
    ) internal {
        IRelay relay = IFdcVerification(FDC_VERIFICATION).relay();

        // ── Round computation ──────────────────────────────────────────────────
        // Per the official FDC skill:
        //   roundId = floor((blockTimestamp - firstVotingRoundStartTs) /
        //                   votingEpochDurationSeconds)
        // where firstVotingRoundStartTs and votingEpochDurationSeconds come from
        // `relay.stateData()`. `block.timestamp` here is the script's effective
        // block (Foundry sim block or the live Coston2 head).
        (
            ,
            uint32 firstVotingRoundStartTs,
            uint8 votingEpochDurationSeconds,
            ,
            ,
            ,
            ,
            ,
            ,
            ,
        ) = relay.stateData();

        uint256 epochSeconds = votingEpochDurationSeconds == 0
            ? DEFAULT_VOTING_EPOCH_SECONDS
            : uint256(votingEpochDurationSeconds);
        if (block.timestamp < firstVotingRoundStartTs) {
            console.log("WARNING: block.timestamp is before firstVotingRoundStartTs;");
            console.log("         using roundId 0 as a lower bound.");
        }
        uint256 roundId = block.timestamp >= firstVotingRoundStartTs
            ? (block.timestamp - firstVotingRoundStartTs) / epochSeconds
            : 0;

        console.log("Relay firstVotingRoundStartTs:", firstVotingRoundStartTs);
        console.log("Relay votingEpochDurationSeconds:", votingEpochDurationSeconds);
        console.log("Computed votingRoundId:", roundId);
        console.log("Effective block.timestamp:", block.timestamp);
        console.log("");

        // ── Build the saved-request record (so Stage 5 / Interact can replay) ──
        SavedRequest memory saved = SavedRequest({
            attestationType: attestationType,
            sourceId: sourceId,
            messageIntegrityCode: messageIntegrityCode,
            transactionId: transactionId,
            proofOwner: proofOwner,
            requestBytes: requestBytes,
            submittedAtRound: uint64(roundId),
            submittedBlockTimestamp: block.timestamp
        });

        // Persist the canonical request file that the task spec expects Stage 2 to
        // have written. If it exists already we leave it; if not, we create it now
        // (Stage 2 doesn't yet persist it — see PROGRAM-SUMMARY gap #3).
        _writeRequestJson(saved);

        // ── Poll the Relay for finalization ────────────────────────────────────
        // On Coston2 the FDC round typically finalizes 90–180s after submit. We
        // look back a small number of rounds in case the request was actually
        // processed in an earlier round (e.g., operator waited a while), then
        // forward up to MAX_ROUND_WAIT_HINT rounds for the typical "just submitted"
        // case. Each finalized round is checked for the same `requestBytes`.
        uint256 foundRound = type(uint256).max;
        bool finalized;

        // Look back up to 14 days of rounds (data-age limit per the FDC skill).
        // 14 days / 90s ≈ 13440 rounds. We cap the lookback window for the script's
        // own gas/timeout; an operator with a stale request should pass the exact
        // round instead via runWithRequest-style customization.
        uint256 lookbackRounds = 13440;
        if (roundId > lookbackRounds) lookbackRounds = roundId;

        console.log("Polling Relay.isFinalized(FDC_PROTOCOL_ID=200, roundId) ...");
        for (uint256 i = 0; i <= MAX_ROUND_WAIT_HINT && roundId + i <= roundId + MAX_ROUND_WAIT_HINT; i++) {
            uint256 r = roundId + i;
            if (relay.isFinalized(FDC_PROTOCOL_ID, r)) {
                finalized = true;
                foundRound = r;
                break;
            }
        }
        if (!finalized && roundId > 0) {
            // Nothing in the forward window — check the immediately preceding
            // round (operator may have a clock skew). A full historical sweep is
            // available by re-running with a tuned `block.timestamp` (forge script
            // `--block-time` / chained simulation).
            if (relay.isFinalized(FDC_PROTOCOL_ID, roundId - 1)) {
                finalized = true;
                foundRound = roundId - 1;
            }
        }

        if (!finalized) {
            console.log("No finalized round in the immediate window.");
            console.log("Voting typically takes ~90-180s on Coston2.");
            console.log("Re-run this script after waiting, or pin a roundId with:");
            console.log("  forge script ... --sig 'runWithRequest(bytes32,bytes32,bytes32,bytes32,address)'");
            console.log("    -- <attestationType> <sourceId> <mic> <txId> <proofOwner>");
            console.log("");
            console.log("DA Layer proof endpoint:");
            console.log("  POST", string.concat(DA_LAYER_URL, "/api/v1/fdc/proof-by-request-round-raw"));
            console.log("  body: { votingRoundId, requestBytes }");
            return;
        }

        console.log("Finalized round found:", foundRound);
        bytes32 merkleRoot = relay.merkleRoots(FDC_PROTOCOL_ID, foundRound);
        console.log("Merkle root:", vm.toString(merkleRoot));
        console.log("");

        // ── Proof fetch guidance ───────────────────────────────────────────────
        // The actual merkle-proof *leaf vector* is returned by the off-chain DA
        // Layer REST API (Foundry can't issue HTTP requests from a script). We
        // emit the exact POST body to use so Stage 5 (Interact) can replay it.
        console.log("=== Stage 3 - Fetch proof from the DA Layer ===");
        console.log("POST to:", string.concat(DA_LAYER_URL, "/api/v1/fdc/proof-by-request-round-raw"));
        console.log("  votingRoundId:", foundRound);
        console.log("  requestBytes :", vm.toString(keccak256(requestBytes))); // confidentiality-safe
        console.log("");
        console.log("Then ABI-decode the response_hex using IXRPPayment.Response");
        console.log("and assemble the IXRPPayment.Proof { merkleProof, data }.");
        console.log("Finally call FdcVerification.verifyXRPPayment(proof) (Stage 4/5).");

        // ── Save proof manifest to data/proof-*.json ────────────────────────────
        _writeProofManifest(saved, foundRound, merkleRoot);
    }

    /// @notice Persist the request payload as `data/request-<txShort>.json` so
    ///         later stages (Deploy / Interact) and re-runs of Retrieve read the
    ///         same commitment. Writes are idempotent.
    function _writeRequestJson(SavedRequest memory saved) internal {
        string memory txShort = _shortTx(saved.transactionId);
        string memory dir = "data";
        string memory path = string.concat(dir, "/request-", txShort, ".json");

        // JSON is built manually to avoid needing forge-std's parseJson round-trip
        // (we want a well-defined on-disk shape that Stage 5 can rely on).
        string memory json = string.concat(
            "{\n",
            "  \"attestationType\": \"", vm.toString(saved.attestationType), "\",\n",
            "  \"sourceId\": \"", vm.toString(saved.sourceId), "\",\n",
            "  \"messageIntegrityCode\": \"", vm.toString(saved.messageIntegrityCode), "\",\n",
            "  \"transactionId\": \"", vm.toString(saved.transactionId), "\",\n",
            "  \"proofOwner\": \"", vm.toString(saved.proofOwner), "\",\n",
            "  \"requestBytes\": \"", vm.toString(keccak256(saved.requestBytes)), "\",\n",
            "  \"submittedAtRound\": ", vm.toString(uint256(saved.submittedAtRound)), ",\n",
            "  \"submittedBlockTimestamp\": ", vm.toString(saved.submittedBlockTimestamp), "\n",
            "}\n"
        );
        vm.writeFile(path, json);
        console.log("Wrote request file:", path);
    }

    /// @notice Append the proof manifest to `data/proof-<txShort>.json` once a
    ///         finalized round + merkle root are known.
    function _writeProofManifest(
        SavedRequest memory saved,
        uint256 votingRoundId,
        bytes32 merkleRoot
    ) internal {
        string memory txShort = _shortTx(saved.transactionId);
        string memory path = string.concat("data/proof-", txShort, ".json");

        string memory json = string.concat(
            "{\n",
            "  \"votingRoundId\": ", vm.toString(votingRoundId), ",\n",
            "  \"merkleRoot\": \"", vm.toString(merkleRoot), "\",\n",
            "  \"attestationType\": \"", vm.toString(saved.attestationType), "\",\n",
            "  \"sourceId\": \"", vm.toString(saved.sourceId), "\",\n",
            "  \"transactionId\": \"", vm.toString(saved.transactionId), "\",\n",
            "  \"proofOwner\": \"", vm.toString(saved.proofOwner), "\",\n",
            "  \"daLayerUrl\": \"", DA_LAYER_URL, "\",\n",
            "  \"daLayerEndpoint\": \"/api/v1/fdc/proof-by-request-round-raw\",\n",
            "  \"fdcProtocolId\": ", vm.toString(FDC_PROTOCOL_ID), "\n",
            "}\n"
        );
        vm.writeFile(path, json);
        console.log("Wrote proof manifest:", path);
        console.log("");
        console.log("=== Stage 3 complete: proof-ready ===");
    }

    /// @notice Short hex tag (first 8 hex chars) for filenames — fits POSIX
    ///         14-byte limits even with `request-`/`proof-` prefixes.
    function _shortTx(bytes32 txId) internal pure returns (string memory) {
        bytes memory hexed = vm.toString(txId);
        // vm.toString returns full 0x + 64 hex chars; take first 10 ("0x"+8).
        bytes memory out = new bytes(10);
        for (uint256 i = 0; i < 10; i++) out[i] = hexed[i];
        return string(out);
    }
}
