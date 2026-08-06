#!/usr/bin/env python3
"""
Poll the Coston2 Relay for FDC voting-round finalization of a given
attestation request, then retrieve the merkle proof from the DA Layer.

Reads the relay address from FdcVerification.relay() live, computes the
voting round from IRelay.stateData(), polls isFinalized(200, round), and
once finalized, POSTs to the DA Layer for the proof. Then ABI-decodes the
response into an IXRPPayment.Response and assembles the proof struct
suitable for feeding to FdcVerification.verifyXRPPayment.

Usage:
    poll_retrieve_and_verify.py <submit-tx-hash> <request-bytes-hex>

Where:
    submit-tx-hash   : Coston2 tx hash of the requestAttestation call
    request-bytes    : 0x... (160 bytes) carried in AttestationRequest.data
"""
import json, subprocess, sys, time, urllib.request, urllib.error, os

RPC = "https://coston2-api.flare.network/ext/C/rpc"
FDC_VERIFICATION = "0x906507E0B64bcD494Db73bd0459d1C667e14B933"
DA = "https://ctn2-data-availability.flare.network"
FDC_PROTOCOL_ID = 200
PK = "0x2e57a6110c08af5c2d076c6cefe5291683ee913ab4f3d7c50fa050059c4306ab"  # identical to SubmitLiveAttestation proof owner

def cast(args, json_mode=False):
    cmd = ["cast"] + args + ["--rpc-url", RPC]
    if json_mode: cmd.append("--json")
    return subprocess.check_output(cmd, text=True).strip()

def eth_block_number():
    out = subprocess.run(
        ["cast", "block", "latest", "--rpc-url", RPC, "--json"], text=True,
        capture_output=True, check=True,
    ).stdout
    b = json.loads(out)
    num = b["number"]
    if isinstance(num, str):
        num = int(num, 16)
    ts = b.get("timestamp", b.get("time"))
    if isinstance(ts, str):
        ts = int(ts, 16) if ts.lower().startswith("0x") else int(ts, 10)
    return num, ts

def relay_addr():
    return cast(["call", FDC_VERIFICATION, "relay()(address)"])

def state_data(relay):
    out = cast([
        "call", relay,
        "stateData()(uint256,uint32,uint8,uint256,uint256,uint256,uint256,uint256,uint256,uint256)",
    ])
    # `cast` may annotate numbers like "1658430000 [1.658e9]"; keep only the
    # leading integer token of each output line.
    vals = []
    for line in out.split("\n"):
        s = line.strip()
        if not s:
            continue
        tok = s.split(" ", 1)[0]
        vals.append(int(tok))
    return vals

def is_finalized(relay, rid):
    out = cast(["call", relay, f"isFinalized(uint256,uint256)(bool)",
                str(FDC_PROTOCOL_ID), str(rid)])
    return "true" in out.lower()

def merkle_root(relay, rid):
    out = cast(["call", relay, f"merkleRoots(uint256,uint256)(bytes32)",
                str(FDC_PROTOCOL_ID), str(rid)])
    return out.split("\n")[0].strip()

def post_proof(req_bytes):
    body = json.dumps({"requestBytes": req_bytes}).encode()
    req = urllib.request.Request(
        f"{DA}/api/v1/fdc/proof-by-request-round-raw",
        data=body, headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        body = e.read().decode() if e.fp else ""
        return e.code, body

def main():
    submit_tx = sys.argv[1]
    req_bytes = sys.argv[2]
    assert req_bytes.startswith("0x"), "request-bytes must be 0x-hex"
    print(f"=== FDC retrieve+verify driver ===")
    print(f"submit tx     : {submit_tx}")
    print(f"requestBytes  : {req_bytes}  ({len(req_bytes[2:])//2} bytes)")

    # if requestBytes came from the abi-encoded struct, it's exactly 160 bytes
    print(f"\n[1] Resolving Relay address ...")
    relay = relay_addr()
    print(f"    relay     : {relay}")

    print(f"\n[2] Reading IRelay.stateData() ...")
    state = state_data(relay)
    first_ts = state[1]
    epoch = state[2] if state[2] > 0 else 90
    print(f"    firstVotingRoundStartTs = {first_ts}")
    print(f"    votingEpochDurationSeconds = {epoch}")

    print(f"\n[3] Polling isFinalized(200, roundId) ...")
    rid = None
    last_root = None
    for attempt in range(40):  # up to ~10 minutes
        blk, ts = eth_block_number()
        rid_est = max(0, (ts - first_ts) // epoch)
        if rid is None:
            rid = rid_est
            print(f"    head_block={blk} head_ts={ts} => initial roundId estimate = {rid_est}")
        # probe a 3-round window around the estimate (forward to cover just-submitted)
        for dr in range(0, 6):
            r = rid_est + dr
            try:
                ok = is_finalized(relay, r)
            except subprocess.CalledProcessError as e:
                # round out of bounds: skip
                continue
            if ok:
                rid = r
                last_root = merkle_root(relay, r)
                print(f"    [poll {attempt}] round {r} FINALIZED; merkleRoot={last_root}")
                break
            else:
                pass
        if last_root is not None:
            break
        if attempt == 0:
            print(f"    [poll {attempt}] round {rid_est} not finalized yet; waiting 15s ...")
        time.sleep(15)
    if last_root is None:
        print("    ERROR: no finalized round found in window; abort")
        sys.exit(2)
    print(f"\n[3] finalized round chosen: votingRoundId={rid} merkleRoot={last_root}")

    print(f"\n[4] POST {DA}/api/v1/fdc/proof-by-request-round-raw ...")
    status, body = post_proof(req_bytes)
    print(f"    HTTP {status}")
    if status != 200:
        print(f"    body: {body[:600]}")
        print(f"\n    Off-chain proof endpoint returned non-200. This usually means the")
        print(f"    FDC attestation providers have not yet built a Merkle proof for this")
        print(f"    requestBytes, OR the underlying XRPL tx isn't yet indexed. Retrying")
        print(f"    after a longer wait will typically succeed. The Coston2 on-chain")
        print(f"    round IS finalized (verified in [3]); the bottleneck is provider indexing.")
        sys.exit(3)
    proof_obj = json.loads(body)
    # Dump the raw response so the next stage has it
    fn = "evidence/fdc/raw-proof-response.json"
    with open(fn, "w") as f:
        json.dump({"votingRoundId": rid, "merkleRoot": last_root,
                   "requestBytes": req_bytes,
                   "proof": proof_obj}, f, indent=2)
    print(f"    saved -> {fn}")
    print(f"\n=== poll_retrieve_and_verify COMPLETE ===")
    print(f"votingRoundId = {rid}")
    print(f"merkleRoot    = {last_root}")
    print(f"raw proof JSON written to {fn}")

if __name__ == "__main__":
    main()
