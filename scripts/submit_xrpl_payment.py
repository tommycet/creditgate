#!/usr/bin/env python3
"""Submit a real Payment to the XRPL testnet and print the transaction hash."""
import json, sys

from xrpl.clients import JsonRpcClient
from xrpl.wallet import generate_faucet_wallet
from xrpl.models.transactions import Payment
from xrpl.transaction import submit_and_wait, autofill_and_sign
from xrpl.utils import xrp_to_drops

client = JsonRpcClient("https://s.altnet.rippletest.net:51234")
print("Connected to XRPL testnet")

sender = generate_faucet_wallet(client, debug=True)
print(f"Sender address: {sender.address}")

# self-transfer (back to same address) - simplest valid payment
payment = Payment(
    account=sender.address,
    amount=xrp_to_drops(1),
    destination=sender.address,
)
signed = autofill_and_sign(payment, sender, client)
print(f"Signed tx hash: {signed.hash}")

result = submit_and_wait(payment, client, sender)
print(f"Engine result: {result.result.get('engine_result', 'unknown')}")

txn_hash = signed.hash
print(f"\n=== XRPL TX HASH ===")
print(txn_hash)
