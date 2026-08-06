#!/usr/bin/env python3
"""
Real XRPL testnet payment for the CreditGate FDC verify path.

Generates a sender + receiver keypair on the XRPL testnet, funds both from the
testnet faucet, sends a real 1 XRP Payment with a Memo containing the loan
commitment string, and writes the resulting transaction hash (32 bytes, hex,
no '0x') plus the addresses to JSON.

XRPL testnet JSON-RPC (per xrpl.org/docs/tutorials/public-servers, verified live 2026-08-06):
    https://s.altnet.rippletest.net:51234/

The 32-byte hash is the FDC `requestBody.transactionId` (bytes32) for a follow-up
SubmitLiveAttestation.s.sol run.
"""
import json
import sys
import time
import binascii

try:
    # The xrpl-py library exposes a parallel async API under `xrpl.asyncio.*`
    # (the sync `generate_faucet_wallet` calls `asyncio.run()` internally and
    # cannot be used from inside an already-running loop). Use the async stack
    # throughout.
    from xrpl.asyncio.clients import AsyncJsonRpcClient
    from xrpl.asyncio.wallet import generate_faucet_wallet
    from xrpl.wallet import Wallet
    from xrpl.models.transactions import Payment, Memo
    from xrpl.asyncio.transaction import (
        submit_and_wait, XRPLReliableSubmissionException,
    )
    from xrpl.utils import xrp_to_drops
    from xrpl.models.requests import AccountInfo
except ImportError as e:
    sys.stderr.write(
        "fatal: xrpl-py imports failed (%s). Install with `pip install xrpl-py`.\n" % e
    )
    raise

XRPL_TESTNET_URL = "https://s.altnet.rippletest.net:51234/"
LOAN_COMMITMENT_MEMO = "CREDITGATE-LOAN-REPAYMENT-FDC-VERIFY-2026-08-06"
OUTPUT_PATH = "evidence/xrpl/real-payment.json"


def fail(msg: str, code: int = 1):
    sys.stderr.write("fatal: " + msg + "\n")
    sys.exit(code)


def hexstr(b: bytes) -> str:
    """Hex without '0x' prefix (XRPL hashes are 64 hex chars = 32 bytes)."""
    return binascii.hexlify(b).decode()


def main():
    import asyncio

    async def run():
        print("=== XRPL testnet payment (FDC verify path) ===")
        print(f"JSON-RPC: {XRPL_TESTNET_URL}")
        client = AsyncJsonRpcClient(XRPL_TESTNET_URL)

        # 1. fund two wallets from the faucet (idempotent enough for tests; the
        #    faucet issues or refreshes existing accounts)
        print("\n[1/4] Funding sender from faucet ...")
        sender_wallet = await generate_faucet_wallet(client, debug=False)
        print("  sender address:", sender_wallet.classic_address)
        print("  sender   pubkey:", sender_wallet.public_key)

        print("\n[2/4] Funding receiver from faucet ...")
        # ----- receiver wallet: regenerate a fresh wallet keypair locally; the
        # faucet only ever talks to one address. Two faucet calls would give us
        # two different addresses we control (which is what we want here for a
        # live Payment). Pass the wallet object so the faucet funds THIS
        # specific address instead of creating one for us.
        receiver_wallet = Wallet.create()
        receiver_wallet = await generate_faucet_wallet(
            client, receiver_wallet, debug=False
        )
        print("  receiver address:", receiver_wallet.classic_address)

        # both wallets should now have positive testnet XRP
        async def get_xrp_balance(address):
            try:
                r = await client.request(AccountInfo(account=address, ledger_index="validated"))
                res = r.result
                if "account_data" not in res:
                    return 0
                return int(res["account_data"]["Balance"])
            except Exception:
                return 0
        n = 0
        while True:
            s_bal = await get_xrp_balance(sender_wallet.classic_address)
            r_bal = await get_xrp_balance(receiver_wallet.classic_address)
            print(f"  [{n}] sender={s_bal} drops, receiver={r_bal} drops")
            if s_bal > 0 and r_bal > 0:
                break
            if n >= 10:
                fail("faucet didn't fund both wallets in time")
            time.sleep(2); n += 1

        # 3. send a real Payment of 1 XRP from sender -> receiver, with a memo
        # -------------------------------------------------------------------------
        # The Memo is ASCII-encoded-in-hex per XRPL's MemoData convention
        # (Memo.MemoData is hex-encoded string). The FDC `IXRPPayment.Response`
        # exposes this as `firstMemoData` — exactly the loan commitment tie-in
        # that CreditGateVault picks up off-chain.
        memo_hex = hexstr(LOAN_COMMITMENT_MEMO.encode("utf-8"))
        print(f"\n[3/4] Building Payment tx (1 XRP) with Memo: {LOAN_COMMITMENT_MEMO!r}")
        tx = Payment(
            account=sender_wallet.classic_address,
            amount=xrp_to_drops(1),
            destination=receiver_wallet.classic_address,
            memos=[Memo(memo_data=memo_hex, memo_type=hexstr(b"loan-commitment"))],
        )
        # sign + submit + wait for validation (XRPL testnet finality ~3-5s)
        try:
            response = await submit_and_wait(tx, client, sender_wallet)
        except XRPLReliableSubmissionException as e:
            fail(f"submit_and_wait raised: {e}")
        result = response.result
        if "hash" not in result:
            fail(f"tx submission failed; full response: {json.dumps(result)}")
        tx_hash = result["hash"]
        status = result.get("meta", {}).get("TransactionResult", "unknown")
        ledger_index = result.get("ledger_index")
        print(f"  tx hash   : {tx_hash}  ({len(tx_hash)} hex chars = {len(tx_hash)//2} bytes)")
        print(f"  status    : {status}")
        print(f"  ledger    : {ledger_index}")

        # The IC-style messageIntegrityCode is meaningless at the XRPL layer;
        # we send a bytes32-aligned hash for the FDC consumer to see cleanly.
        # Confirm uppercase is OK by also writing the form with 0x prefix and
        # the same casing XRPL gives us.
        bytes32_hex = "0x" + tx_hash.lower().rjust(64, "0")

        # 4. write the artifact and a tiny log file so the FDC submit step can
        # ingest it from disk.
        out = {
            "xrplNetwork": "testnet",
            "xrplJsonRpcUrl": XRPL_TESTNET_URL,
            "loanCommitmentMemo": LOAN_COMMITMENT_MEMO,
            "memoTypeHex": hexstr(b"loan-commitment"),
            "sender": {
                "classicAddress": sender_wallet.classic_address,
                "publicKey": sender_wallet.public_key,
                "seed": sender_wallet.seed,            # testnet only; not real value
                "dropsBalance": s_bal,
            },
            "receiver": {
                "classicAddress": receiver_wallet.classic_address,
                "publicKey": receiver_wallet.public_key,
                "seed": receiver_wallet.seed,
                "dropsBalance": r_bal,
            },
            "payment": {
                "amountDrops": xrp_to_drops(1),
                "amountXrp": 1,
                "txHashHex": tx_hash,
                "txHashBytes32": bytes32_hex,
                "txHashBytes": 32,
                "status": status,
                "ledgerIndex": ledger_index,
            },
        }
        import os
        os.makedirs(os.path.dirname(OUTPUT_PATH), exist_ok=True)
        with open(OUTPUT_PATH, "w") as f:
            json.dump(out, f, indent=2)
        print(f"\n[4/4] wrote {OUTPUT_PATH}")
        print("\n=== REAL XRPL TESTNET TRANSACTION HASH ===")
        print(bytes32_hex)
        return out

    return asyncio.run(run())


if __name__ == "__main__":
    main()
