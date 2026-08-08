#!/usr/bin/env python3
"""
consumer.py — long-polling OCI Queue consumer for the KeyGen service.

Runs as a systemd service on a micro-VM (04-worker).  This replaces the
serverless worker: OCI has no native "message → invoke Function" trigger, and
Service Connector Hub batches on a 60s-minimum window (far too slow).  A process
that long-polls the queue receives messages within milliseconds, so on an
always-free shape the worker is both fast and effectively free.

Auth:
    Instance Principals — the VM's own identity, granted by a dynamic group +
    policy in 04-worker/iam.tf.  No key files or secrets on the box.

Config (from /etc/keygen/keygen.env via the systemd unit):
    QUEUE_ID          OCID of the requests queue
    QUEUE_ENDPOINT    Queue messages endpoint (data plane)
    NOSQL_TABLE_NAME  OCI NoSQL table name
    COMPARTMENT_ID    Compartment OCID for NoSQL calls
    OCI_REGION        Region identifier (for the NoSQL client)
"""

import json
import base64
import os
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import oci
from oci.auth.signers import InstancePrincipalsSecurityTokenSigner
from oci.queue import QueueClient
from oci.nosql import NosqlClient
from oci.nosql.models import UpdateRowDetails
from cryptography.hazmat.primitives.asymmetric import rsa, ed25519
from cryptography.hazmat.primitives import serialization

QUEUE_ID       = os.environ["QUEUE_ID"]
QUEUE_ENDPOINT = os.environ["QUEUE_ENDPOINT"]
TABLE_NAME     = os.environ.get("NOSQL_TABLE_NAME", "keygen_results")
COMPARTMENT_ID = os.environ["COMPARTMENT_ID"]
REGION         = os.environ.get("OCI_REGION", "")

# Long-poll wait (max 30s): GetMessages returns the instant a message arrives,
# or after this timeout if the queue stays empty — near-zero idle cost.
POLL_WAIT_SECONDS = 30
VISIBILITY_SECONDS = 60   # hide a message while we process it
BATCH_LIMIT = 10

_signer = InstancePrincipalsSecurityTokenSigner()
# QueueClient talks to the queue's data-plane endpoint directly.
_queue = QueueClient(config={}, signer=_signer, service_endpoint=QUEUE_ENDPOINT)
# NoSQL client needs a region to resolve its endpoint under instance principals.
_nosql = NosqlClient(config={"region": REGION}, signer=_signer)

# ---------------------------------------------------------------------------
# Health endpoint
# ---------------------------------------------------------------------------
# A tiny HTTP server so validate.sh (and humans) can tell the worker is not
# just booted but genuinely able to process: _ready flips to True only after
# the FIRST successful authorized queue poll — proving deps installed, instance-
# principal auth propagated, and the queue is reachable.  Until then it 503s.

HEALTH_PORT = int(os.environ.get("HEALTH_PORT", "8080"))
_ready = False


class _HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802 - http.server naming
        code = 200 if _ready else 503
        body = (b'{"status":"ready"}' if _ready else b'{"status":"starting"}')
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # silence per-request access logging
        pass


def _start_health_server() -> None:
    """Serve the health endpoint forever (runs in a daemon thread)."""
    HTTPServer(("0.0.0.0", HEALTH_PORT), _HealthHandler).serve_forever()


def generate_keypair(key_type: str = "rsa", key_bits: int = 2048):
    """Generate an SSH keypair and return (public_openssh, private_pem).

    Args:
        key_type : "rsa" or "ed25519"; unknown values fall back to RSA.
        key_bits : RSA modulus size (ignored for ed25519).

    Returns:
        tuple[str, str]: OpenSSH public key and PEM private key.
    """
    if key_type == "ed25519":
        priv = ed25519.Ed25519PrivateKey.generate()
        priv_format = serialization.PrivateFormat.PKCS8
    else:
        priv = rsa.generate_private_key(public_exponent=65537, key_size=key_bits)
        priv_format = serialization.PrivateFormat.TraditionalOpenSSL

    pub_ssh = priv.public_key().public_bytes(
        serialization.Encoding.OpenSSH,
        serialization.PublicFormat.OpenSSH,
    ).decode()

    priv_pem = priv.private_bytes(
        serialization.Encoding.PEM,
        priv_format,
        serialization.NoEncryption(),
    ).decode()

    return pub_ssh, priv_pem


def process(content: str) -> None:
    """Generate a keypair for one queue message and store it in NoSQL.

    Args:
        content: The message body (JSON) published by the post function.
    """
    msg = json.loads(content)
    corr_id = str(msg.get("correlation_id", "")).strip()
    if not corr_id:
        return
    key_type = str(msg.get("key_type", "rsa"))
    key_bits = int(msg.get("key_bits", 2048))

    pub, priv = generate_keypair(key_type, key_bits)
    item = {
        "correlation_id":  corr_id,
        "status":          "complete",
        "key_type":        key_type,
        "public_key_b64":  base64.b64encode(pub.encode()).decode(),
        "private_key_b64": base64.b64encode(priv.encode()).decode(),
        "created_at":      datetime.now(timezone.utc).isoformat(),
    }
    _nosql.update_row(
        table_name_or_id=TABLE_NAME,
        update_row_details=UpdateRowDetails(value=item, compartment_id=COMPARTMENT_ID),
    )
    print(f"processed {corr_id} ({key_type}-{key_bits})", flush=True)


def main() -> None:
    """Drain the queue forever: long-poll → process → delete (ack)."""
    global _ready
    print("keygen consumer starting", flush=True)

    # Health endpoint comes up immediately (serving 503 until the first
    # successful poll below flips _ready to True).
    threading.Thread(target=_start_health_server, daemon=True).start()

    while True:
        try:
            resp = _queue.get_messages(
                QUEUE_ID,
                timeout_in_seconds=POLL_WAIT_SECONDS,
                visibility_in_seconds=VISIBILITY_SECONDS,
                limit=BATCH_LIMIT,
            )
            # A successful poll proves auth + connectivity — signal readiness.
            if not _ready:
                _ready = True
                print("worker ready (first successful poll)", flush=True)
            for m in (resp.data.messages or []):
                try:
                    process(m.content)
                    # Ack: delete only after a successful write, so a crash mid-
                    # process lets the message reappear and be retried.
                    _queue.delete_message(QUEUE_ID, m.receipt)
                except Exception as exc:  # noqa: BLE001 - keep the loop alive
                    print(f"process error: {exc}", flush=True)
        except Exception as exc:  # noqa: BLE001 - transient poll/API errors
            print(f"poll error: {exc}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
