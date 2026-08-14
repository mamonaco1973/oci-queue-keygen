"""
func.py — OCI Function handlers for the async SSH KeyGen API surface.

A single container image is deployed as two OCI Functions, distinguished by the
FUNCTION_TYPE environment variable set in Terraform.  The handler() entry point
dispatches to the correct operation at runtime.

Handler → OCI Function → trigger:
    post  →  keygen-post  →  API Gateway  POST /keygen
    get   →  keygen-get   →  API Gateway  GET  /result/{id}  and  GET /heartbeat

The actual key generation runs OFF these functions, in a long-polling consumer
on a micro-VM (04-worker) — OCI has no native "message → invoke Function"
trigger, so the worker is a cheap always-on process, not a function.

Flow:
    POST /keygen publishes a request to OCI Queue and returns 202 with a
    correlation id.  The VM consumer drains the queue, generates the keypair,
    and writes the result to OCI NoSQL.  GET /result/{id} polls NoSQL until the
    result is present.

Path parameters:
    OCI API Gateway injects {id} as the X-Request-Id request header via its
    header transformation policy.  The get handler reads it from ctx.Headers().

Storage:
    OCI NoSQL Database, single primary key `correlation_id`.  Rows auto-expire
    via the table's TTL (1 day), matching the AWS DynamoDB TTL.

Authentication:
    Resource Principal signer — credentials are derived automatically from the
    Function's identity inside OCI.  No secrets in code.

Environment variables:
    FUNCTION_TYPE     Routes to the correct handler (post/get)
    NOSQL_TABLE_NAME  OCI NoSQL table name              (get)
    COMPARTMENT_ID    Compartment OCID for SDK calls     (get)
    QUEUE_ID          OCID of the requests queue         (post)
    QUEUE_ENDPOINT    Queue messages endpoint            (post)
"""

import base64
import io
import json
import os
import uuid
from datetime import datetime, timezone

# Import only the specific SDK pieces we use rather than the whole `oci`
# package — trims cold-start import time on OCI Functions.
from fdk import response
from oci.auth.signers import get_resource_principals_signer
from oci.exceptions import ServiceError
from oci.nosql import NosqlClient
from oci.nosql.models import UpdateRowDetails
from oci.queue import QueueClient
from oci.queue.models import PutMessagesDetails, PutMessagesDetailsEntry

# ---------------------------------------------------------------------------
# Module-level config + singletons (reused across warm invocations)
# ---------------------------------------------------------------------------

TABLE_NAME     = os.environ.get("NOSQL_TABLE_NAME", "keygen_results").strip()
COMPARTMENT_ID = os.environ.get("COMPARTMENT_ID", "").strip()
QUEUE_ID       = os.environ.get("QUEUE_ID", "").strip()
QUEUE_ENDPOINT = os.environ.get("QUEUE_ENDPOINT", "").strip()

# Resource Principal signer provides credentials inside OCI Functions without
# any key files.  Initialised once per container so the token is reused warm.
_signer = get_resource_principals_signer()
_nosql  = NosqlClient(config={}, signer=_signer)

# Only the post function publishes; build the QueueClient lazily so the get
# container never needs the endpoint.  Cached at module scope after first use.
_queue = None


def _queue_client() -> QueueClient:
    """Return a cached QueueClient bound to the queue's messages endpoint."""
    global _queue
    if _queue is None:
        _queue = QueueClient(
            config={}, signer=_signer, service_endpoint=QUEUE_ENDPOINT
        )
    return _queue


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _resp(ctx, status: int, body: dict) -> response.Response:
    """Build an FDK Response with a JSON payload.

    Args:
        ctx    : FDK invoke context.
        status : HTTP status code.
        body   : JSON-serializable response dict.

    Returns:
        fdk.response.Response
    """
    return response.Response(
        ctx,
        status_code=status,
        headers={"Content-Type": "application/json"},
        response_data=json.dumps(body),
    )


def _request_id(ctx) -> str:
    """Extract the correlation id from the X-Request-Id header.

    OCI API Gateway injects ${request.path[id]} as X-Request-Id for the
    /result/{id} route.  FDK exposes headers via ctx.Headers(); normalise the
    key casing and flatten list-valued headers.

    Args:
        ctx: FDK invoke context.

    Returns:
        str: Trimmed correlation id, or empty string if absent.
    """
    try:
        headers = ctx.Headers() or {}
        val = headers.get("x-request-id") or headers.get("X-Request-Id") or ""
        if isinstance(val, list):
            val = val[0] if val else ""
        return str(val).strip()
    except Exception:
        return ""


def _row(value) -> dict:
    """Safely convert an OCI NoSQL row value to a plain dict."""
    return dict(value) if value else {}


# ---------------------------------------------------------------------------
# Route dispatcher
# ---------------------------------------------------------------------------

def handler(ctx, data: io.BytesIO = None):
    """OCI Function entry point — dispatches by FUNCTION_TYPE.

    A single image serves both API roles; Terraform sets FUNCTION_TYPE per
    function so one build backs the whole API surface.

    Args:
        ctx  : FDK invoke context.
        data : HTTP request body.

    Returns:
        fdk.response.Response
    """
    func_type = os.environ.get("FUNCTION_TYPE", "").strip()
    dispatch = {
        "post":   post_handler,
        "get":    get_handler,
        "worker": worker_handler,
    }
    fn = dispatch.get(func_type)
    if fn is None:
        return _resp(ctx, 400, {"error": f"Unknown FUNCTION_TYPE: {func_type}"})
    return fn(ctx, data)


# ---------------------------------------------------------------------------
# post — POST /keygen: enqueue a request onto the Queue
# ---------------------------------------------------------------------------

def post_handler(ctx, data: io.BytesIO = None):
    """Accept a keygen request and publish it to OCI Queue.

    Generates a correlation id, normalises the payload, and puts a single
    message on the queue.  Returns 202 immediately — the VM consumer processes
    it asynchronously.  The client polls GET /result/{id} for the outcome.

    Args:
        ctx  : FDK invoke context.
        data : JSON body {"key_type": "rsa"|"ed25519", "key_bits": 2048}.

    Returns:
        fdk.response.Response: 202 with the correlation id, 500 on publish error.
    """
    try:
        raw = data.getvalue() if data else b"{}"
        body = json.loads(raw or b"{}")
    except (ValueError, json.JSONDecodeError):
        body = {}

    corr_id = str(uuid.uuid4())
    # key_bits may arrive missing or null (the web client sends null for the
    # ed25519 option) — coerce to the default rather than crashing on int(None).
    key_bits = body.get("key_bits") or 2048
    msg = {
        "correlation_id": corr_id,
        "key_type": body.get("key_type", "rsa"),
        "key_bits": int(key_bits),
    }

    # OCI Queue message content is a plain string (no base64 required, unlike
    # Streaming) — the consumer reads it back verbatim.
    entry = PutMessagesDetailsEntry(content=json.dumps(msg))

    try:
        _queue_client().put_messages(
            queue_id=QUEUE_ID,
            put_messages_details=PutMessagesDetails(messages=[entry]),
        )
    except ServiceError as exc:
        # Log the whole error, not just a friendly string: OCI masks authz
        # failures as 404 NotAuthorizedOrNotFound, so the status and code are
        # the only way to tell a policy problem from a wrong queue OCID. The
        # code is echoed to the caller because validate.sh is the first thing
        # to see a failure and it should not require a trip to the console.
        print(
            f"post: put_messages failed status={exc.status} code={exc.code} "
            f"queue_id={QUEUE_ID!r} endpoint={QUEUE_ENDPOINT!r} "
            f"opc_request_id={getattr(exc, 'request_id', None)} "
            f"message={exc.message}",
            flush=True,
        )
        return _resp(ctx, 500, {
            "error": "Failed to enqueue request",
            "code": exc.code,
            "status": exc.status,
        })

    return _resp(ctx, 202, {"request_id": corr_id, "status": "queued"})


# ---------------------------------------------------------------------------
# get — GET /result/{id}: read the result from NoSQL (also serves /heartbeat)
# ---------------------------------------------------------------------------

def get_handler(ctx, data: io.BytesIO = None):
    """Return the keygen result for a correlation id, or a pending status.

    Also serves GET /heartbeat: API Gateway injects the X-Heartbeat header for
    that route, and we return a fast 200 without a NoSQL lookup to keep this
    (the result-polling) function warm.

    Args:
        ctx  : FDK invoke context (X-Request-Id header carries {id}).
        data : HTTP request body (ignored).

    Returns:
        fdk.response.Response: 200 with the result, 202 while pending,
        400 if the id is missing, 500 on lookup error.
    """
    # Heartbeat/health probe — return immediately without touching NoSQL.
    try:
        headers = ctx.Headers() or {}
        if headers.get("x-heartbeat") or headers.get("X-Heartbeat"):
            return _resp(ctx, 200, {"status": "ok"})
    except Exception:
        pass

    corr_id = _request_id(ctx)
    if not corr_id:
        return _resp(ctx, 400, {"error": "request id is required"})

    try:
        resp = _nosql.get_row(
            table_name_or_id=TABLE_NAME,
            key=[f"correlation_id:{corr_id}"],
            compartment_id=COMPARTMENT_ID,
        )
    except ServiceError as exc:
        # Same reasoning as post_handler: a bare message here turns a policy
        # or table-name problem into an unreadable 500.
        print(
            f"get: get_row failed status={exc.status} code={exc.code} "
            f"table={TABLE_NAME!r} message={exc.message}",
            flush=True,
        )
        return _resp(ctx, 500, {
            "error": "Failed to retrieve result",
            "code": exc.code,
            "status": exc.status,
        })

    item = _row(resp.data.value)
    if not item:
        # Not written yet — the consumer is still processing.
        return _resp(ctx, 202, {"status": "pending", "correlation_id": corr_id})

    return _resp(ctx, 200, item)


# ---------------------------------------------------------------------------
# worker — Connector Hub target (PROCESSING_MODE=sch only)
# ---------------------------------------------------------------------------
# The serverless alternative to the 04-worker VM consumer.  Connector Hub reads
# the Queue on a batch schedule and invokes this function with a JSON list of
# messages.  Deployed only by 04-sch; in VM mode this handler is never reached.
#
# Two behavioural differences from consumer.py that are NOT incidental:
#
#   1. Batching — one invocation carries up to `batch_size_in_num` messages,
#      so this iterates where the consumer handles one message at a time.
#   2. Acking — Connector Hub owns the read/delete cycle.  This function must
#      NOT delete messages; raising instead signals failure so the connector
#      can redeliver.  The VM consumer, by contrast, deletes explicitly.
#
# generate_keypair() is duplicated from 04-worker/consumer.py rather than
# shared: the two run in different deployment units (container image vs. a file
# dropped by cloud-init) with no common package.  Keep them in step.
# ---------------------------------------------------------------------------

def _generate_keypair(key_type: str = "rsa", key_bits: int = 2048):
    """Generate an SSH keypair and return (public_openssh, private_pem).

    `cryptography` is imported here rather than at module scope so the post and
    get containers never pay its import cost at cold start — which would
    otherwise skew the VM-vs-SCH latency comparison this mode exists to make.

    Args:
        key_type : "rsa" or "ed25519"; unknown values fall back to RSA.
        key_bits : RSA modulus size (ignored for ed25519).

    Returns:
        tuple[str, str]: OpenSSH public key and PEM private key.
    """
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ed25519, rsa

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


def _iter_requests(payload):
    """Yield request dicts from a Connector Hub batch payload.

    The connector delivers a JSON list per invocation, but the element shape for
    a QueueSource is not contractually pinned in the docs: an entry may be the
    queue message envelope ({"content": "<json>"}), the decoded request itself,
    or a bare JSON string.  All three are normalised here so a change in the
    envelope degrades to a logged skip rather than a silently dropped batch.

    Args:
        payload: Parsed JSON body delivered by Connector Hub.

    Yields:
        dict: One keygen request ({"correlation_id", "key_type", "key_bits"}).
    """
    entries = payload if isinstance(payload, list) else [payload]

    for entry in entries:
        if isinstance(entry, str):
            try:
                entry = json.loads(entry)
            except ValueError:
                print(f"worker: skipping unparseable entry: {entry!r}")
                continue

        if not isinstance(entry, dict):
            print(f"worker: skipping unexpected entry type: {type(entry)}")
            continue

        # Queue message envelope — the request is JSON inside `content`.
        if "correlation_id" not in entry and "content" in entry:
            try:
                entry = json.loads(entry["content"])
            except (ValueError, TypeError):
                print(f"worker: skipping bad content: {entry.get('content')!r}")
                continue

        if isinstance(entry, dict) and entry.get("correlation_id"):
            yield entry
        else:
            print(f"worker: skipping entry with no correlation_id: {entry!r}")


def worker_handler(ctx, data: io.BytesIO = None):
    """Generate keypairs for a Connector Hub batch and store them in NoSQL.

    Args:
        ctx  : FDK invoke context.
        data : JSON list of queue messages delivered by Connector Hub.

    Returns:
        fdk.response.Response: 200 with a per-batch processed count.

    Raises:
        Exception: Propagated when a write fails, so Connector Hub treats the
            invocation as failed and can redeliver the batch.
    """
    try:
        raw = data.getvalue() if data else b"[]"
        payload = json.loads(raw or b"[]")
    except (ValueError, json.JSONDecodeError):
        return _resp(ctx, 400, {"error": "Malformed batch payload"})

    processed = 0
    for req in _iter_requests(payload):
        corr_id  = str(req["correlation_id"]).strip()
        key_type = str(req.get("key_type", "rsa"))
        # May arrive null from the web client's ed25519 option — coerce rather
        # than crash on int(None), matching post_handler.
        key_bits = int(req.get("key_bits") or 2048)

        pub, priv = _generate_keypair(key_type, key_bits)

        # Let a write failure propagate: a 5xx tells Connector Hub the batch
        # was not handled, which is the only retry lever available here.
        _nosql.update_row(
            table_name_or_id=TABLE_NAME,
            update_row_details=UpdateRowDetails(
                value={
                    "correlation_id":  corr_id,
                    "status":          "complete",
                    "key_type":        key_type,
                    "public_key_b64":  base64.b64encode(pub.encode()).decode(),
                    "private_key_b64": base64.b64encode(priv.encode()).decode(),
                    "created_at":      datetime.now(timezone.utc).isoformat(),
                },
                compartment_id=COMPARTMENT_ID,
            ),
        )
        processed += 1
        print(f"worker: processed {corr_id} ({key_type}-{key_bits})")

    return _resp(ctx, 200, {"processed": processed})
