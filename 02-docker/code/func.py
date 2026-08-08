"""
func.py — OCI Function handlers for the async SSH KeyGen service.

A single container image is deployed as three separate OCI Functions, each
distinguished by the FUNCTION_TYPE environment variable set in Terraform.
The handler() entry point dispatches to the correct operation at runtime.

Handler → OCI Function → trigger:
    post    →  keygen-post    →  API Gateway  POST /keygen
    get     →  keygen-get     →  API Gateway  GET  /result/{id}
    worker  →  keygen-worker  →  Service Connector Hub (Streaming source)

Flow:
    POST /keygen publishes a request to OCI Streaming and returns 202 with a
    correlation id.  A Service Connector Hub drains the stream and invokes the
    worker, which generates the keypair and writes the result to OCI NoSQL.
    GET /result/{id} polls NoSQL until the result is present.  This mirrors the
    AWS SQS→Lambda event-source-mapping design (Streaming replaces SQS because
    it is the only Service Connector source that can target Functions).

Path parameters:
    OCI API Gateway injects {id} as the X-Request-Id request header via its
    header transformation policy.  The get handler reads it from ctx.Headers()
    rather than parsing the URL directly.

Storage:
    OCI NoSQL Database, single primary key `correlation_id`.  Rows auto-expire
    via the table's TTL (1 day), matching the AWS DynamoDB TTL.

Authentication:
    Resource Principal signer — credentials are derived automatically from the
    Function's identity inside OCI.  No secrets in code.  Dynamic Group + IAM
    policies grant NoSQL row management and Streaming publish rights.

Environment variables:
    FUNCTION_TYPE     Routes to the correct handler (post/get/worker)
    NOSQL_TABLE_NAME  OCI NoSQL table name              (get, worker)
    COMPARTMENT_ID    Compartment OCID for SDK calls    (get, worker)
    STREAM_ID         OCID of the requests stream       (post)
    STREAM_ENDPOINT   Streaming messages endpoint       (post)
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
from oci.streaming import StreamClient
from oci.streaming.models import PutMessagesDetails, PutMessagesDetailsEntry
from cryptography.hazmat.primitives.asymmetric import rsa, ed25519
from cryptography.hazmat.primitives import serialization

# ---------------------------------------------------------------------------
# Module-level config + singletons (reused across warm invocations)
# ---------------------------------------------------------------------------

TABLE_NAME      = os.environ.get("NOSQL_TABLE_NAME", "keygen_results").strip()
COMPARTMENT_ID  = os.environ.get("COMPARTMENT_ID", "").strip()
STREAM_ID       = os.environ.get("STREAM_ID", "").strip()
STREAM_ENDPOINT = os.environ.get("STREAM_ENDPOINT", "").strip()

# Resource Principal signer provides credentials inside OCI Functions without
# any key files.  Initialised once per container so the token is reused warm.
_signer = get_resource_principals_signer()
_nosql  = NosqlClient(config={}, signer=_signer)

# StreamClient is region/endpoint-specific — only the post function publishes,
# but building it lazily keeps the get/worker containers from needing the
# endpoint.  Cached at module scope after first use.
_stream = None


def _stream_client() -> StreamClient:
    """Return a cached StreamClient bound to the stream's messages endpoint."""
    global _stream
    if _stream is None:
        _stream = StreamClient(
            config={}, signer=_signer, service_endpoint=STREAM_ENDPOINT
        )
    return _stream


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
        # Default (and fallback) is RSA with the requested modulus size.
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


# ---------------------------------------------------------------------------
# Route dispatcher
# ---------------------------------------------------------------------------

def handler(ctx, data: io.BytesIO = None):
    """OCI Function entry point — dispatches by FUNCTION_TYPE.

    A single image serves all three roles; Terraform sets FUNCTION_TYPE per
    function so one build backs the whole service.

    Args:
        ctx  : FDK invoke context.
        data : Request body (HTTP body for post/get; stream batch for worker).

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
# post — POST /keygen: enqueue a request onto Streaming
# ---------------------------------------------------------------------------

def post_handler(ctx, data: io.BytesIO = None):
    """Accept a keygen request and publish it to OCI Streaming.

    Generates a correlation id, normalises the payload, and puts a single
    message on the stream.  Returns 202 immediately — the worker processes it
    asynchronously.  The client polls GET /result/{id} for the outcome.

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

    # Streaming's PutMessages API expects base64-encoded key/value strings;
    # the service stores the decoded bytes, so the worker base64-decodes once.
    entry = PutMessagesDetailsEntry(
        key=base64.b64encode(corr_id.encode()).decode(),
        value=base64.b64encode(json.dumps(msg).encode()).decode(),
    )

    try:
        _stream_client().put_messages(
            stream_id=STREAM_ID,
            put_messages_details=PutMessagesDetails(messages=[entry]),
        )
    except ServiceError:
        return _resp(ctx, 500, {"error": "Failed to enqueue request"})

    return _resp(ctx, 202, {"request_id": corr_id, "status": "queued"})


# ---------------------------------------------------------------------------
# get — GET /result/{id}: read the result from NoSQL
# ---------------------------------------------------------------------------

def get_handler(ctx, data: io.BytesIO = None):
    """Return the keygen result for a correlation id, or a pending status.

    Args:
        ctx  : FDK invoke context (X-Request-Id header carries {id}).
        data : HTTP request body (ignored).

    Returns:
        fdk.response.Response: 200 with the result, 202 while pending,
        400 if the id is missing, 500 on lookup error.
    """
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
        # Not written yet — the worker is still processing.
        return _resp(ctx, 202, {"status": "pending", "correlation_id": corr_id})

    return _resp(ctx, 200, item)


# ---------------------------------------------------------------------------
# worker — Service Connector Hub target: generate keys, write to NoSQL
# ---------------------------------------------------------------------------

def _iter_messages(data: io.BytesIO):
    """Yield decoded request dicts from a Service Connector Hub batch.

    SCH delivers a JSON array of stream records; each record's `value` is the
    base64-encoded original message.  We base64-decode it back to the JSON the
    post handler published.  Defensive against a single object or a raw payload.

    Args:
        data: FDK data stream containing the SCH batch.

    Yields:
        dict: {"correlation_id", "key_type", "key_bits"} per message.
    """
    try:
        raw = data.getvalue() if data else b"[]"
        payload = json.loads(raw or b"[]")
    except (ValueError, json.JSONDecodeError):
        return

    records = payload if isinstance(payload, list) else [payload]
    for rec in records:
        try:
            if isinstance(rec, dict) and "value" in rec:
                decoded = base64.b64decode(rec["value"])
                yield json.loads(decoded)
            elif isinstance(rec, dict):
                # Already the message body (no envelope).
                yield rec
        except Exception:
            # Skip malformed records rather than failing the whole batch.
            continue


def worker_handler(ctx, data: io.BytesIO = None):
    """Process a batch of keygen requests delivered by Service Connector Hub.

    For each request: generate the keypair, base64-encode both keys, and write
    the result to NoSQL.  Row TTL (set on the table) expires results after a day.

    Args:
        ctx  : FDK invoke context.
        data : SCH batch (JSON array of stream records).

    Returns:
        fdk.response.Response: 200 once the batch is processed.
    """
    processed = 0
    for msg in _iter_messages(data):
        corr_id  = str(msg.get("correlation_id", "")).strip()
        if not corr_id:
            continue
        key_type = str(msg.get("key_type", "rsa"))
        key_bits = int(msg.get("key_bits", 2048))

        try:
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
                update_row_details=UpdateRowDetails(
                    value=item,
                    compartment_id=COMPARTMENT_ID,
                ),
            )
            processed += 1
        except (ServiceError, Exception):
            # Log-and-continue: one bad request must not drop the batch.
            continue

    return _resp(ctx, 200, {"processed": processed})
