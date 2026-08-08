# CLAUDE.md — oci-queue-keygen

An asynchronous SSH key generation microservice on OCI, the port of
`aws-sqs-keygen`. A client submits a request through API Gateway; the post
function puts it on **OCI Queue**; a long-polling **consumer daemon on a
micro-VM** generates the keypair and stores it in **OCI NoSQL**; the client
polls a result endpoint until the keys are ready.

> **Design history:** the AWS original uses an SQS→Lambda event-source mapping
> (instant trigger). OCI has no equivalent — Queue can't trigger anything, and
> Service Connector Hub (the only thing that can invoke a Function) batches on a
> 60s-minimum window (~30s latency, unusable). So the worker is a long-polling
> VM consumer instead of a serverless function: `GetMessages` returns the
> instant a message arrives, and on an always-free shape it's effectively $0.
> An earlier Streaming+SCH iteration was abandoned for this reason. The repo may
> still be named for "queue"/"streaming"; the current design is **Queue + VM**.

---

## What This Project Does

| Method | Path | Handler | Behavior |
|--------|------|---------|----------|
| POST | `/keygen` | keygen-post (Function) | Put request on Queue, return 202 + `request_id` |
| GET | `/result/{id}` | keygen-get (Function) | Return the stored keypair, or 202 while pending |
| GET | `/heartbeat` | keygen-get (Function) | Fast 200 keep-alive (no NoSQL lookup) |
| — | (Queue consumer) | consumer.py (VM daemon) | Generate keypair, write result to NoSQL |

Keys are base64-encoded and expire from NoSQL after 1 day (table TTL).

---

## Architecture

```
Browser / curl
     │
     ▼
OCI API Gateway — keygen-gateway (PUBLIC)
     ├── POST /keygen      → Function: keygen-post ──put──► OCI Queue (keygen-requests)
     │                                                              │ long-poll
     │                                                              ▼
     │                                              Worker VM: keygen-worker
     │                                              systemd: consumer.py
     │                                              (instance principal auth)
     │                                                              │
     │                                                              ▼
     └── GET /result/{id}  → Function: keygen-get ◄──read──  OCI NoSQL (keygen_results)
         GET /heartbeat    → Function: keygen-get (X-Heartbeat → fast 200)
```

**One image, two functions:** `keygen-post` and `keygen-get` share a single OCIR
image; `FUNCTION_TYPE` routes the FDK `handler()`. The worker is NOT a function —
it's `consumer.py` running under systemd on a micro-VM.

**Async trigger:** none exists on OCI. The worker long-polls the Queue
(`GetMessages` with a 30s wait), so latency is near-zero in steady state.

**Path parameters:** API Gateway injects `${request.path[id]}` as `X-Request-Id`
for `/result/{id}`; the get function reads `ctx.Headers().get("x-request-id")`.
The `/heartbeat` route injects `X-Heartbeat` so the get function returns early.

---

## Repository Layout

```
01-queue/
  main.tf        OCI provider, variables
  queue.tf       OCI Queue (the message bus)
  registry.tf    OCIR repository (holds the functions image)
  outputs.tf     queue_id, queue_endpoint, repository_name
02-docker/
  code/
    func.py          post + get handlers; dispatches via FUNCTION_TYPE
    requirements.txt fdk + oci (no cryptography — keygen runs on the VM)
    Dockerfile       fnproject/python:3.11 multi-stage build
  build.sh           builds + pushes image; writes .build_output (IMAGE_PATH)
03-functions/
  main.tf        variables (image_path, queue_id, queue_endpoint)
  network.tf     VCN, public subnet, internet gateway, security list
  nosql.tf       keygen_results table (correlation_id PK, USING TTL 1 DAYS)
  functions.tf   Functions Application + post/get Function resources
  api.tf         API Gateway + deployment (POST /keygen, GET /result/{id}, /heartbeat)
  iam.tf         Dynamic Group + policies (functions→NoSQL+Queue, API GW→functions)
  logging.tf     Functions Application invoke logs
  outputs.tf     api_gateway_endpoint, nosql_table_name, ocir_image_path
04-worker/
  main.tf            provider (oci/tls/local), variables
  network.tf         self-contained VCN + public subnet (SSH + egress)
  compute.tf         Ubuntu micro-VM + generated SSH key + cloud-init
  cloud-init.yaml.tmpl installs deps, drops consumer.py + env, starts systemd
  consumer.py        long-polling Queue consumer (instance principal auth)
  iam.tf             Dynamic Group (by instance OCID) + Queue/NoSQL policy
  outputs.tf         worker_public_ip, worker_ssh_command
05-webapp/
  index.html.tmpl  Web UI — API_BASE injected at deploy time
  favicon.ico
  main.tf          OCI provider, variables
  storage.tf       Object Storage bucket (public) + object uploads
check_env.sh   Pre-flight: verify tools + OCI CLI connection
apply.sh       Full deployment (5 phases + validation)
destroy.sh     Teardown in reverse order; purges OCIR images + auth token
validate.sh    End-to-end smoke test via curl (POST then poll)
```

---

## Deployment

```bash
./apply.sh      # full deploy (optionally: export OCI_COMPARTMENT_ID=...)
./destroy.sh    # teardown
./validate.sh   # smoke test only (after deploy)
```

Phase hand-off (via `TF_VAR_*` in apply.sh): 01-queue exports `queue_id` +
`queue_endpoint` → 03-functions (post) and 04-worker (consumer); 03-functions
exports `nosql_table_name` → 04-worker.

---

## The Worker VM

`04-worker` runs `consumer.py` as the `keygen-worker` systemd service on a
micro-VM (default `VM.Standard.E2.1.Micro`, always-free). Auth is **instance
principals** — a dynamic group matches the instance OCID; the policy grants
`use queues` (consume/delete) and `manage nosql-rows`. Debug:

```bash
terraform -chdir=04-worker output -raw worker_ssh_command
sudo journalctl -u keygen-worker -f
```

Out of always-free capacity? `export TF_VAR_instance_shape="VM.Standard.E4.Flex"`
(not free) before `apply.sh`.

---

## Test Manually

```bash
BASE=$(cd 03-functions && terraform output -raw api_gateway_endpoint)
REQ=$(curl -s -X POST "$BASE/keygen" -H "Content-Type: application/json" \
  -d '{"key_type":"rsa","key_bits":2048}' | jq -r .request_id)
curl -s "$BASE/result/$REQ" | jq   # near-instant once the worker is running
```
