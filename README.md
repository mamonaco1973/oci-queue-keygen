# OCI SSH KeyGen Microservice — Streaming, Service Connector, Functions, NoSQL, API Gateway

This project delivers a fully automated **serverless SSH key generation service**
on OCI, powered by **OCI Streaming**, **Service Connector Hub**, **OCI Functions**,
**OCI NoSQL Database**, and **API Gateway**.

It uses **Terraform**, **Docker**, and **Python (OCI SDK + cryptography)** to build
a **message-driven key generation pipeline** that asynchronously processes SSH
keypair requests and stores completed results in NoSQL — with no always-on
compute.

This is the OCI port of [`aws-sqs-keygen`](https://github.com/mamonaco1973/aws-sqs-keygen).

## Why Streaming instead of Queue?

The AWS original relies on an **SQS→Lambda event-source mapping**: a message on
the queue automatically invokes the worker. OCI has no direct equivalent — and
critically, **OCI Queue cannot be a Service Connector Hub source**. Service
Connector Hub is the only mechanism that auto-invokes a Function from a message
bus, and its only message-bearing source that can target Functions is
**Streaming**. So the bus here is Streaming, wired to the worker through a
Service Connector. (The `oci-queue-keygen` folder name is historical; the
service is more accurately `oci-streaming-keygen`.)

| AWS building block | OCI equivalent used here |
|--------------------|--------------------------|
| SQS queue | OCI Streaming stream |
| SQS→Lambda event-source mapping | Service Connector Hub (Streaming → Functions) |
| Lambda (post / get / worker) | OCI Functions (one image, three functions) |
| Amazon ECR | OCI Container Registry (OCIR) |
| DynamoDB (+ TTL) | OCI NoSQL Database (row TTL) |
| API Gateway (HTTP API) | OCI API Gateway |
| S3 static website | OCI Object Storage static site |
| IAM roles | Dynamic Group + policies + Resource Principals |

## Architecture

```
Browser / curl
     │
     ▼
OCI API Gateway (PUBLIC)
     ├── POST /keygen      → keygen-post ──put──► OCI Streaming (keygen-requests)
     │                                                    │
     │                                          Service Connector Hub
     │                                                    ▼
     │                                             keygen-worker ──► OCI NoSQL
     │                                                                   ▲
     └── GET /result/{id}  → keygen-get ──────────read───────────────────┘
```

1. **POST `/keygen`** — the post function generates a `request_id` (UUID4),
   publishes the request to Streaming, and returns **202 Accepted** immediately.
2. **Service Connector Hub** drains the stream and invokes the **worker**, which
   generates the keypair (`cryptography`) and writes it to NoSQL.
3. **GET `/result/{id}`** — the get function returns **202** while pending and
   **200** with the base64-encoded keypair once the worker has stored it.

Keys expire from NoSQL automatically after one day (table TTL).

## API Endpoints

### POST /keygen

Submits a key generation request. Body (all fields optional):

```json
{ "key_type": "rsa", "key_bits": 2048 }
```

`key_type` is `rsa` (default) or `ed25519`; `key_bits` applies to RSA only.
Returns:

```json
{ "request_id": "b1c9…", "status": "queued" }
```

### GET /result/{id}

Polls for the result. **202** while pending:

```json
{ "status": "pending", "correlation_id": "b1c9…" }
```

**200** once complete (keys base64-encoded):

```json
{
  "correlation_id": "b1c9…",
  "status": "complete",
  "key_type": "rsa",
  "public_key_b64": "…",
  "private_key_b64": "…",
  "created_at": "2026-08-07T…Z"
}
```

## Prerequisites

- `oci`, `terraform`, `docker`, `jq`, `envsubst` in your PATH
- OCI CLI configured (`~/.oci/config` with an API key)
- Docker daemon running (local image build)

## Deploy / Destroy / Validate

```bash
./apply.sh      # 4-phase deploy, then a smoke test
./destroy.sh    # tear everything down (reverse order)
./validate.sh   # smoke test only, after a deploy
```

Optional: `export OCI_COMPARTMENT_ID=ocid1.compartment...` to target a specific
compartment (defaults to the tenancy root).

`apply.sh` phases:

1. **01-stream** — OCIR repository + Streaming stream
2. **02-docker** — build the functions image, push to OCIR
3. **03-functions** — Functions, NoSQL, VCN, API Gateway, Service Connector, IAM
4. **04-webapp** — inject the API URL into the HTML, deploy to Object Storage

## Notes on latency

The pipeline is asynchronous. The Service Connector's batch window
(`batch_time_in_sec = 60`) plus a possible function cold start means the first
result can take up to a couple of minutes. `validate.sh` and the web client poll
patiently. Tune `batch_time_in_sec` / `batch_size_in_kbs` in
`03-functions/connector.tf` to trade latency against invocation count.

## Web Client

A static page hosted in Object Storage (`04-webapp`) lets you generate a keypair
from the browser: pick the key type/size, submit, and it polls until the keys
appear. The API base URL is injected at deploy time.
