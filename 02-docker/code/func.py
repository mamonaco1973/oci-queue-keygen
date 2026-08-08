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

import io
import json
import os
import uuid

# Import only the specific SDK pieces we use rather than the whole `oci`
# package — trims cold-start import time on OCI Functions.
from fdk import response
from oci.auth.signers import get_resource_principals_signer
from oci.exceptions import ServiceError
from oci.nosql import NosqlClient
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
        "post": post_handler,
        "get":  get_handler,
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
    msg = {
        "correlation_id": corr_id,
        "key_type": body.get("key_type", "rsa"),
        "key_bits": int(body.get("key_bits", 2048)),
    }

    # OCI Queue message content is a plain string (no base64 required, unlike
    # Streaming) — the consumer reads it back verbatim.
    entry = PutMessagesDetailsEntry(content=json.dumps(msg))

    try:
        _queue_client().put_messages(
            queue_id=QUEUE_ID,
            put_messages_details=PutMessagesDetails(messages=[entry]),
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to enqueue request"})

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
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to retrieve result"})

    item = _row(resp.data.value)
    if not item:
        # Not written yet — the consumer is still processing.
        return _resp(ctx, 202, {"status": "pending", "correlation_id": corr_id})

    return _resp(ctx, 200, item)
