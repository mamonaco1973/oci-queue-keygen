# CLAUDE.md — oci-queue-keygen

An asynchronous SSH key generation microservice on OCI. This is the OCI port of
`aws-sqs-keygen`. A client submits a keygen request through API Gateway; the
request is published to OCI Streaming; a Service Connector Hub drains the stream
and invokes a worker Function that generates the keypair and stores it in OCI
NoSQL. The client polls a result endpoint until the keys are ready.

> **Naming note:** the message bus is OCI **Streaming**, not OCI Queue. OCI Queue
> cannot be a Service Connector Hub source, and Service Connector is the only way
> to auto-invoke a Function from a message bus (the analog of AWS's SQS→Lambda
> event-source mapping). Streaming is the sole Service Connector source that can
> target Functions, so it is used here. The repo folder is historical; a
> `oci-streaming-keygen` name is more accurate.

---

## What This Project Does

| Method | Path | Function | Behavior |
|--------|------|----------|----------|
| POST | `/keygen` | keygen-post | Publish request to Streaming, return 202 + `request_id` |
| GET | `/result/{id}` | keygen-get | Return the stored keypair, or 202 while pending |
| — | (Service Connector) | keygen-worker | Generate keypair, write result to NoSQL |

Keys are returned base64-encoded and expire from NoSQL after 1 day (table TTL).

---

## Architecture

```
Browser / curl
     │
     ▼
OCI API Gateway — keygen-gateway (PUBLIC)
     ├── POST /keygen       → Function: keygen-post ──put──► OCI Streaming (keygen-requests)
     │                                                              │
     │                                                   Service Connector Hub
     │                                                   (keygen-stream-to-worker)
     │                                                              ▼
     │                                                     Function: keygen-worker
     │                                                              │ Resource Principal
     │                                                              ▼
     └── GET /result/{id}   → Function: keygen-get ◄──read──  OCI NoSQL (keygen_results)
                                        ▲ injects X-Request-Id header
```

**One image, three functions:** all three OCI Functions share a single Docker
image in OCIR. A `FUNCTION_TYPE` env var (set per-function in Terraform) routes
the FDK `handler()` entry point to `post` / `get` / `worker` at runtime.

**Async trigger:** OCI has no native "message → invoke Function" for the Queue
service. Streaming + Service Connector Hub is the faithful analog to AWS's
SQS→Lambda event-source mapping. Worst-case dispatch latency ≈ the connector's
`batch_time_in_sec` (60s), so the first result can take a couple of minutes.

**Path parameters:** API Gateway does not forward URL path params to function
bodies. For `/result/{id}`, the deployment spec injects `${request.path[id]}` as
the `X-Request-Id` header; the function reads `ctx.Headers().get("x-request-id")`.

---

## Repository Layout

```
01-stream/
  main.tf        OCI provider, variables
  stream.tf      Streaming stream pool + stream (the message bus)
  registry.tf    OCIR repository (holds the functions image)
  outputs.tf     stream_id, stream_endpoint, repository_name
02-docker/
  code/
    func.py          post/get/worker handlers; dispatches via FUNCTION_TYPE
    requirements.txt fdk + oci + cryptography
    Dockerfile       fnproject/python:3.11 multi-stage build
  build.sh           builds + pushes image; writes .build_output (IMAGE_PATH)
03-functions/
  main.tf        OCI provider, variables (image_path, stream_id, stream_endpoint)
  network.tf     VCN, public subnet, internet gateway, security list
  nosql.tf       keygen_results table (correlation_id PK, USING TTL 1 DAYS)
  functions.tf   Functions Application + 3 Function resources
  api.tf         API Gateway + deployment (POST /keygen, GET /result/{id})
  connector.tf   Service Connector Hub (Streaming source → worker target)
  iam.tf         Dynamic Group + policies (functions, API GW, Service Connector)
  logging.tf     Functions Application invoke logs
  outputs.tf     api_gateway_endpoint, nosql_table_name, ocir_image_path
04-webapp/
  index.html.tmpl  Web UI — API_BASE injected at deploy time
  favicon.ico
  main.tf          OCI provider, variables
  storage.tf       Object Storage bucket (public) + object uploads
check_env.sh   Pre-flight: verify tools + OCI CLI connection
apply.sh       Full deployment (4 phases + validation)
destroy.sh     Teardown in reverse order; purges OCIR images + auth token
validate.sh    End-to-end smoke test via curl (POST then poll)
```

---

## Prerequisites

- `oci`, `terraform`, `docker`, `jq`, `envsubst` in PATH
- OCI CLI configured (`~/.oci/config` with API key)
- Docker daemon running (for local image build)
- Max 2 auth tokens per user — `apply.sh` creates/caches one at `~/.oci/ocir_token`

---

## Deployment

```bash
./apply.sh      # full deploy (optionally: export OCI_COMPARTMENT_ID=...)
./destroy.sh    # teardown
./validate.sh   # smoke test only (after deploy)
```

`apply.sh` runs four phases: 01-stream (OCIR + Streaming) → 02-docker (build +
push) → 03-functions (Functions, NoSQL, API GW, Service Connector, IAM) →
04-webapp (Object Storage site). Stream OCID + endpoint are captured from Phase 1
output and passed to Phase 3 as `TF_VAR_stream_id` / `TF_VAR_stream_endpoint`.

---

## Function Code

All handlers live in `02-docker/code/func.py`. A single `handler()` dispatches on
`FUNCTION_TYPE`:

- **post** — reads `{key_type, key_bits}`, generates a UUID4 correlation id,
  publishes a base64-encoded message to Streaming via `oci.streaming`, returns
  202 with `request_id`.
- **get** — reads the correlation id from `X-Request-Id`, `get_row` from NoSQL;
  200 with the keypair or 202 while pending.
- **worker** — invoked by Service Connector Hub with a batch of stream records;
  base64-decodes each message value, generates the keypair (`cryptography`
  RSA/ed25519), writes the result to NoSQL. Resource Principal auth throughout.

**NoSQL key format for get_row:** `key=[f"correlation_id:{id}"]`.

---

## Test Manually

```bash
BASE=$(cd 03-functions && terraform output -raw api_gateway_endpoint)

# Submit
REQ=$(curl -s -X POST "$BASE/keygen" -H "Content-Type: application/json" \
  -d '{"key_type":"rsa","key_bits":2048}' | jq -r .request_id)

# Poll (allow up to ~2 min for the Service Connector batch window)
curl -s "$BASE/result/$REQ" | jq
```
