# OCI Async SSH KeyGen Microservice

This project delivers an automated **asynchronous SSH key generation service**
on OCI, powered by **OCI Queue**, **OCI Functions**, **OCI NoSQL Database**,
**API Gateway**, and **Connector Hub**.

It uses **Terraform**, **Docker**, and **Python (OCI SDK + cryptography)** to
build a **message-driven key generation pipeline** that asynchronously processes
SSH keypair requests and stores completed results in NoSQL.

This is the OCI port of [`aws-sqs-keygen`](https://github.com/mamonaco1973/aws-sqs-keygen).

## There is no SQS→Lambda on OCI. There is something close.

The AWS original relies on an **SQS→Lambda event-source mapping**: a message on
the queue automatically invokes the worker in milliseconds. **OCI has no
first-class equivalent** — Queue has no native compute trigger, so nothing
auto-invokes a Function the way SQS does.

What OCI gives you instead is **Connector Hub**: a batching data-movement
service you point at the queue and aim at a Function. You configure thresholds,
not a trigger. It is *not* an event-source mapping — but configured correctly it
is close enough that the distinction stops mattering for this workload.

"Configured correctly" is doing real work in that sentence:

| Phase 4 mode | Configuration | End-to-end |
|---|---|---|
| `sch` *(default here)* | `batch_size_in_num = 1` | **0.8–2s** |
| `sch` | `batch_size_in_num = 100` *(service default)* | **~61s** |
| `vm` | 30s long poll | **sub-second** |

**Connector Hub flushes on whichever threshold is hit first, and the batch timer
starts when the first message of a batch arrives.** Set the batch size to one
message and the batch is full on arrival, so it flushes immediately and the
timer never matters. Leave it at the service default of 100 messages and a
single request never fills the batch — so it waits out the *entire* 60-second
timer, measured at 61.54s end to end.

That is a flat cost on every request, not an unlucky worst case: the window
opens when your message lands, so each lone request restarts the full 60s.

That single dropdown is the difference between a 1-second API and a 30-second
one, and nothing in the setup flow points at it. It is the most important thing
in this repository.

`batch_time_in_sec` has an API-enforced floor of 60 (asking for 5 is rejected
outright, despite Oracle's [queue-to-function
doc](https://docs.oracle.com/en-us/iaas/Content/connector-hub/queue-to-function.htm)
showing a 5-second example) — but with `batch_size_in_num = 1` that floor never
binds.

### The VM alternative

Before the batch-size finding, this project ran the worker as a **long-polling
consumer daemon on a micro-VM** — OCI Queue supports polling waits up to 30s
that return the instant a message appears, which is genuinely sub-second and
costs nothing on an always-free shape.

That mode still ships (`PROCESSING_MODE=vm`) and is still the fastest option.
It is no longer the *default*, because trading 1s for sub-second is rarely worth
owning, patching, and monitoring a server. Deploy it when latency actually
matters, or to reproduce the comparison yourself:

```bash
./apply.sh                        # default: sch — Connector Hub + worker Function
PROCESSING_MODE=vm ./apply.sh     # long-polling consumer on a micro-VM
```

Both modes serve the identical API and web client. The web client logs
millisecond timings to the **browser console** (`[timing] …`) and shows elapsed
time on the page, so the comparison is reproducible from the same UI.

The modes are mutually exclusive — they consume the same queue, so `apply.sh`
refuses to deploy one while the other is up. Run `./destroy.sh` (which tears
down whichever is deployed) before switching.

> **Cost footnote (vm mode):** `VM.Standard.E2.1.Micro` is Always Free eligible
> (up to two instances), so the worker is effectively $0. Oracle may reclaim
> Always Free compute that stays below its utilization thresholds over a 7-day
> window — a consumer blocked in long-poll can look idle — so treat the free
> shape as an excellent demo option, with a small paid shape
> (`export TF_VAR_instance_shape=...`) as the production fallback.

| AWS building block | OCI equivalent used here |
|--------------------|--------------------------|
| SQS queue | OCI Queue |
| SQS→Lambda event-source mapping | Connector Hub (batch size 1) — or a VM consumer |
| Lambda (post / get) | OCI Functions (one image, shared handlers) |
| Lambda (worker) | OCI Function (`sch`) / systemd daemon on a VM (`vm`) |
| Amazon ECR | OCI Container Registry (OCIR) |
| DynamoDB (+ TTL) | OCI NoSQL Database (row TTL) |
| API Gateway (HTTP API) | OCI API Gateway |
| S3 static website | OCI Object Storage static site |
| IAM roles | Dynamic Groups + policies + Resource/Instance Principals |

## Architecture

![OCI KeyGen Diagram](oci-queue-keygen.png)

1. **POST `/keygen`** — the post function generates a `request_id` (UUID4),
   puts the request on the Queue, and returns **202 Accepted** immediately.
2. **Connector Hub** reads the message (batch size 1, so it flushes at once) and
   invokes the **worker function**, which generates the keypair
   (`cryptography`) and writes it to NoSQL. Connector Hub owns the read/delete
   cycle — the function never acks.
   *In `vm` mode this stage is instead a micro-VM long-polling the Queue, which
   generates the keypair and deletes (acks) the message itself.*
3. **GET `/result/{id}`** — returns **202** while pending and **200** with the
   base64-encoded keypair once the worker has stored it.

Keys expire from NoSQL automatically after one day (table TTL). A `GET /heartbeat`
endpoint returns a fast 200; the web client pings it once a minute to keep the
result-polling function warm.

## API Endpoints

### POST /keygen

```json
{ "key_type": "rsa", "key_bits": 2048 }
```

`key_type` is `rsa` (default) or `ed25519`; `key_bits` applies to RSA only.
Returns `{ "request_id": "…", "status": "queued" }`.

### GET /result/{id}

**202** while pending: `{ "status": "pending", "correlation_id": "…" }`.
**200** once complete (keys base64-encoded):

```json
{
  "correlation_id": "…",
  "status": "complete",
  "key_type": "rsa",
  "public_key_b64": "…",
  "private_key_b64": "…",
  "created_at": "…Z"
}
```

## Prerequisites

- `oci`, `terraform`, `docker`, `jq`, `envsubst` in your PATH
- OCI CLI configured (`~/.oci/config` with an API key)
- Docker daemon running (local image build)
- For `PROCESSING_MODE=vm` only: capacity for one always-free (or small)
  compute instance in your tenancy

## Deploy / Destroy / Validate

```bash
./apply.sh      # 5-phase deploy (mode sch), then a smoke test
./destroy.sh    # tear everything down (reverse order, both modes)
./validate.sh   # smoke test only, after a deploy
```

Optional: `export OCI_COMPARTMENT_ID=ocid1.compartment...` (defaults to tenancy root).

`apply.sh` phases:

1. **01-queue** — OCIR repository + OCI Queue
2. **02-docker** — build the functions image, push to OCIR
3. **03-functions** — Functions (post/get), NoSQL, VCN, API Gateway, IAM
4. **04-sch** *(default)* — Connector Hub + worker Function, **or**
   **04-worker** *(mode `vm`)* — the queue-consumer VM (cloud-init installs +
   starts the daemon)
5. **05-webapp** — inject the API URL into the HTML, deploy to Object Storage

`validate.sh` detects the deployed mode from Terraform state, so it works
standalone regardless of which mode is up.

## The worker VM (mode `vm`)

`04-worker` provisions a micro-VM (default `VM.Standard.E2.1.Micro`, an
always-free shape) that runs [`consumer.py`](04-worker/consumer.py) as a systemd
service (`keygen-worker`). It authenticates via **instance principals** (no keys
on the box) and long-polls the Queue. A generated SSH key is written to
`04-worker/worker_key.pem` for debugging:

```bash
terraform -chdir=04-worker output -raw worker_ssh_command   # ssh in
sudo journalctl -u keygen-worker -f                          # tail the daemon
```

If your tenancy is out of always-free capacity, override the shape:
`export TF_VAR_instance_shape="VM.Standard.E4.Flex"` (note: not free).

## Web Client

A static page hosted in Object Storage (`05-webapp`) lets you generate a keypair
from the browser: pick the key type/size, submit, and it polls until the keys
appear. The API base URL is injected at deploy time.
