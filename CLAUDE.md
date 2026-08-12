# CLAUDE.md — oci-queue-keygen

An asynchronous SSH key generation microservice on OCI, the port of
`aws-sqs-keygen`. A client submits a request through API Gateway; the post
function puts it on **OCI Queue**; a long-polling **consumer daemon on a
micro-VM** generates the keypair and stores it in **OCI NoSQL**; the client
polls a result endpoint until the keys are ready.

> **Design history:** the AWS original uses an SQS→Lambda event-source mapping
> (instant trigger). OCI has no first-class equivalent — Queue has no native
> compute trigger, and Service Connector Hub can bridge Queue→Functions but is a
> batching service, not an event-source mapping. So the default worker is a
> long-polling VM consumer instead of a serverless function: `GetMessages`
> returns the instant a message arrives, and on an always-free shape it's
> effectively $0 (with the idle-reclaim caveat). An earlier Streaming+SCH
> iteration was abandoned for this reason. The repo may still be named for
> "queue"/"streaming"; the default design is **Queue + VM**.
>
> **Both paths now ship.** `PROCESSING_MODE=vm|sch` selects Phase 4, so the
> latency claim is measured rather than asserted.
>
> **60s is an API-enforced floor on `target.batchTimeInSec`, not a default.**
> Confirmed 2026-08-12: `batch_time_in_sec = 5` is rejected at create time with
> `400-InvalidParameter, target.batchTimeInSec must be greater than or equal to
> 60`. Oracle's queue-to-function doc shows a 5s example — it does not apply to
> this target. So the original "~30s observed" figure is correct and defensible:
> uniform arrival in a 60s window averages half the window. `batch_size_in_num`
> is the only remaining latency lever, and whether size=1 short-circuits the
> time window is an open empirical question this mode exists to answer.

---

## What This Project Does

| Method | Path | Handler | Behavior |
|--------|------|---------|----------|
| POST | `/keygen` | keygen-post (Function) | Put request on Queue, return 202 + `request_id` |
| GET | `/result/{id}` | keygen-get (Function) | Return the stored keypair, or 202 while pending |
| GET | `/heartbeat` | keygen-get (Function) | Fast 200 keep-alive (no NoSQL lookup) |
| — | (Queue consumer, mode `vm`) | consumer.py (VM daemon) | Generate keypair, write result to NoSQL |
| — | (Connector target, mode `sch`) | keygen-worker-fn (Function) | Same, for a batch of messages |

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

**One image, three handlers:** `keygen-post`, `keygen-get` and (in `sch` mode)
`keygen-worker-fn` all share a single OCIR image; `FUNCTION_TYPE` routes the FDK
`handler()`. In the default `vm` mode the worker is NOT a function — it's
`consumer.py` running under systemd on a micro-VM.

**Async trigger:** none exists on OCI. In `vm` mode the worker long-polls the
Queue (`GetMessages` with a 30s wait), so latency is near-zero in steady state.
In `sch` mode Connector Hub batches instead — see the mode notes below.

**`cryptography` is imported lazily** inside the worker handler, not at module
scope, so post/get cold start is unchanged by its presence in the image. Do not
hoist that import: it would slow the very path the mode comparison measures.

**Mode differences that are not incidental** (both are talking points, not
implementation noise):

- *Batching* — SCH delivers a JSON **list** per invoke; `consumer.py` handles
  one message at a time.
- *Acking* — SCH owns the read/delete cycle, so `worker_handler` must never
  delete and signals failure by raising. `consumer.py` deletes explicitly after
  a successful write.

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
04-worker/       Phase 4 when PROCESSING_MODE=vm (default)
  main.tf            provider (oci/tls/local), variables
  network.tf         self-contained VCN + public subnet (SSH + egress)
  compute.tf         Ubuntu micro-VM + generated SSH key + cloud-init
  cloud-init.yaml.tmpl installs deps, drops consumer.py + env, starts systemd
  consumer.py        long-polling Queue consumer (instance principal auth)
  iam.tf             Dynamic Group (by instance OCID) + Queue/NoSQL policy
  outputs.tf         worker_public_ip, worker_ssh_command
04-sch/          Phase 4 when PROCESSING_MODE=sch — the serverless alternative
  main.tf            provider, variables, batch tuning (batch_time_in_sec etc.)
  functions.tf       keygen-worker-fn in the 03-functions application
  sch.tf             Connector Hub: QueueSource plugin → functions target
  iam.tf             any-user policy scoped to the serviceconnector principal
  outputs.tf         connector_id, connector_state, batch_settings
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
./apply.sh                        # full deploy, mode vm (default)
PROCESSING_MODE=sch ./apply.sh    # full deploy, mode sch
./destroy.sh                      # teardown (tears down BOTH phase-4 dirs)
./validate.sh                     # smoke test only (after deploy)
```

Modes are mutually exclusive — both consume the same queue, so `apply.sh` aborts
if the other mode still has state. `destroy.sh` is deliberately mode-agnostic
(it is also how you switch), so it never strands the mode you are leaving.

Phase hand-off (via `TF_VAR_*` in apply.sh): 01-queue exports `queue_id` +
`queue_endpoint` → 03-functions (post), 04-worker (consumer), 04-sch (source);
03-functions exports `nosql_table_name` → both phase-4 dirs, plus
`functions_application_id` + the 02-docker `image_path` → 04-sch.

`validate.sh` is a pass/fail smoke test on a 5s poll — too coarse to compare the
modes. The **web client** is the instrument: it logs `[timing]` lines to the
browser console and puts the elapsed time in the status line.

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
