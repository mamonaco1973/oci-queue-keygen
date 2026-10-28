# SSH Key Generator on OCI: API Gateway, Queue, Functions and NoSQL

An asynchronous **SSH key pair generator** with a browser front end, and the
OCI port of [`aws-sqs-keygen`](https://github.com/mamonaco1973/aws-sqs-keygen).
A client submits a request through an **OCI API Gateway** to a function that
puts it on an **OCI Queue** and returns an ID. A worker generates the key
pair and stores it in **OCI NoSQL**, and the client polls a second endpoint
until the result is ready. A single-page web app, served from a public
**Object Storage** bucket, does this from the browser.

OCI has no equivalent of the SQS-to-Lambda trigger, so the worker comes in
two interchangeable modes, chosen with `PROCESSING_MODE`:

| Mode | Worker | End to end |
|---|---|---|
| `sch` (default) | **Connector Hub** reads the queue and invokes a worker **Function**, with `batch_size_in_num = 1` | 0.8 to 2 s |
| `sch` | the same, at the service default `batch_size_in_num = 100` | about 61 s |
| `vm` | a **long-polling consumer daemon** on an Always Free micro VM | under a second |

| Piece | Where | Role |
|---|---|---|
| **keygen-gateway** / **keygen-api** | API Gateway, public | gateway in `keygen-public-subnet`; routes `POST /keygen`, `GET /result/{id}` (ID passed in an `X-Request-Id` header) and `GET /heartbeat`; CORS from any origin |
| **keygen-app** | OCI Functions | `keygen-post` and `keygen-get`, 256 MB, 60 s; in `sch` mode also `keygen-worker-fn`, 1 GB, 300 s. All three run one image, choosing a handler by `FUNCTION_TYPE` |
| **keygen-requests** | OCI Queue | 60 s visibility, 1 day retention, 30 s max poll wait; moves a message to the dead-letter queue after 5 deliveries |
| **keygen_results** | OCI NoSQL | keyed on `correlation_id`; table TTL of 1 day; 50 read and 50 write units |
| **keygen-queue-to-function** | Connector Hub (`sch`) | queue source, function target; batch size 1, batch time 60 s |
| **keygen-worker** | Compute (`vm`) | `VM.Standard.E2.1.Micro`, latest Canonical Ubuntu, public IP in its own `keygen-worker-vcn` (`10.1.0.0/16`); runs `consumer.py` as the `keygen-worker` systemd service |
| **keygen-functions** | OCIR | private repository for the functions image |
| **keygen-vcn** | VCN `10.0.0.0/16` | public subnet `10.0.0.0/24` for the gateway and functions; the security list allows TCP 443 in |
| **keygen-web-&lt;hex&gt;** | Object Storage | public-read bucket holding `index.html` and `favicon.ico` |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="A browser loads index.html from the public keygen-web Object Storage bucket and calls keygen-gateway, a public API Gateway. POST /keygen invokes keygen-post, which puts the request on the keygen-requests OCI Queue and returns a request ID; GET /result/{id} invokes keygen-get, which reads the keygen_results NoSQL table and reports pending until the row exists. In the default sch mode, Connector Hub reads the queue with a batch size of one and invokes keygen-worker-fn, which generates the key pair and writes the row. In vm mode, a micro VM long-polls the queue instead, writes the row, and deletes the message." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`01-queue/`**: the queue, the OCIR repository, and the functions' dynamic
  group `keygen-functions-dg` with its policy (`manage nosql-rows`,
  `use nosql-tables`, `use queues`).
- **`02-docker/`**: `build.sh` and the functions code in `code/` (`func.py`,
  `Dockerfile` based on `fnproject/python:3.11`).
- **`03-functions/`**: the VCN, `keygen-post` and `keygen-get`, the gateway,
  the NoSQL table, invoke logging, and the policies that let the Functions
  service pull images and API Gateway invoke functions.
- **`04-sch/`** (mode `sch`): the worker function, the connector, and a
  policy letting Connector Hub manage the queue and invoke functions.
- **`04-worker/`** (mode `vm`): the VM's VCN, the instance, its SSH key,
  `cloud-init.yaml.tmpl`, `consumer.py`, and the dynamic group
  `keygen-workers-dg` with its policy (`manage queues`, `manage nosql-rows`,
  `use nosql-tables`).
- **`05-webapp/`**: the web bucket and `index.html.tmpl`, which `apply.sh`
  fills in with the gateway URL.

The functions sign in with a **resource principal** and the VM with an
**instance principal**, so no keys are stored on either.

## Why the batch size matters

Connector Hub isn't an event trigger. It moves data in batches and flushes
when either the batch size or the batch time is reached, and the timer starts
when the first message of a batch arrives. With the service default of 100
messages, a single request never fills the batch, so every request waits out
the whole 60-second timer: 61.54 s end to end, measured. With
`batch_size_in_num = 1` the batch is full the moment a message lands and
flushes at once, so the timer never matters.

`batch_time_in_sec` can't go below 60; the API rejects smaller values
(including the 5 s shown in Oracle's
[queue-to-function example](https://docs.oracle.com/en-us/iaas/Content/connector-hub/queue-to-function.htm)),
and `04-sch` validates it. With a batch size of one that floor never comes
into play.

In `sch` mode Connector Hub owns reading and deleting the messages. In `vm`
mode `consumer.py` long-polls for up to 30 s at a time (a poll returns as
soon as a message arrives), takes up to 10 messages, writes each result, and
deletes the message; a failure leaves the message to reappear after 60 s and
eventually go to the dead-letter queue. The daemon also serves a health check
on port 8080 once it can reach NoSQL.

## API

There's no authentication.

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/keygen` | `{"key_type": "rsa" \| "ed25519", "key_bits": 2048 \| 4096}`, both optional | `202` `{"request_id": "<uuid>", "status": "queued"}` |
| GET | `/result/{id}` | none | `202` `{"status": "pending", "correlation_id": ...}` until the worker finishes, then `200` with the row |
| GET | `/heartbeat` | none | `200` `{"status": "ok"}`; served by `keygen-get`, which the web page pings once a minute to keep warm |

The finished row:

```json
{
  "correlation_id": "630f70c4-815c-41d1-ae52-6babf3a41b1f",
  "status": "complete",
  "key_type": "rsa",
  "public_key_b64": "c3NoLXJzYSBBQUFBQjNOemFDMXljMkVBQUFBREFRQUJBQUFCQVFD...",
  "private_key_b64": "LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb3dJQkFBS0NBUUVB...",
  "created_at": "2026-08-13T14:12:09.123456+00:00"
}
```

Both keys are base64-encoded. Decoded, the public key is in OpenSSH format
and the private key is an unencrypted PEM: traditional RSA format for RSA,
PKCS#8 for Ed25519. Any `key_type` other than `ed25519` produces RSA.

## Prerequisites

* [An OCI Account](https://cloud.oracle.com/)
* [Install OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm),
  configured with a `DEFAULT` profile in `~/.oci/config`
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install Docker](https://docs.docker.com/engine/install/), with the daemon
  running
* [Install jq](https://jqlang.github.io/jq/download/) and `envsubst`
* For `vm` mode only: room for one Always Free (or small) instance

Your user needs to create policies and dynamic groups at the tenancy root.
Set `OCI_COMPARTMENT_ID` to deploy into a compartment; otherwise everything
goes into the root compartment.

## Deploy

```bash
git clone https://github.com/mamonaco1973/oci-queue-keygen.git
cd oci-queue-keygen
./apply.sh                        # sch mode (default)
PROCESSING_MODE=vm ./apply.sh     # vm mode
```

`apply.sh` reads the tenancy, region and user from `~/.oci/config`. For the
OCIR login it uses the auth token cached in `~/.oci/ocir_token`, or creates
one named `keygen-ocir` and caches it there. Then it runs five phases:

1. **`01-queue`**: the queue, the repository and the functions' IAM.
2. **`02-docker/build.sh`**: builds the image, logs in to OCIR (retrying
   while a new token propagates) and pushes it.
3. **`03-functions`**: the network, `keygen-post`, `keygen-get`, the gateway
   and the table.
4. **`04-sch`** or **`04-worker`**, depending on the mode. The two modes
   would consume the same queue, so `apply.sh` refuses to deploy one while
   the other still has resources.
5. **`05-webapp`**: uploads `index.html` rendered with the gateway URL.

It ends by running `validate.sh`, which detects the mode from Terraform
state. In `vm` mode it first waits for the worker's health check. It retries
the submit until it gets a request ID (recycling `keygen-post` if its
resource principal token predates the policy), then polls every 5 seconds,
up to 60 times:

```
NOTE: Submitted keygen request (630f70c4-815c-41d1-ae52-6babf3a41b1f).
NOTE: Polling for result...
NOTE: Key generation complete.

============================================================================
KeyGen Quick Start - Validation Output
============================================================================

NOTE: Test Web URL:    https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/keygen-web-<hex>/o/index.html
NOTE: API Base URI:    https://<gateway-host>
```

## Try it

1. Open the **Test Web URL**, pick a key type and size, and generate a key
   pair. The page shows the elapsed time and logs `[timing]` lines to the
   browser console, so you can compare the modes from the same page.
2. Or call the API with `curl`:

   ```bash
   curl -s https://<gateway-host>/result/<id> \
     | jq -r .private_key_b64 | base64 -d > id_rsa && chmod 600 id_rsa
   ```

3. In `vm` mode, sign in to the worker and follow the daemon:

   ```bash
   $(terraform -chdir=04-worker output -raw worker_ssh_command)
   sudo journalctl -u keygen-worker -f
   ```

   If the tenancy is out of Always Free capacity, set
   `TF_VAR_instance_shape` to a small paid shape. Oracle may reclaim Always
   Free instances that stay below its utilization thresholds for a week, and
   a worker blocked in long polls can look idle.

## Teardown

```bash
./destroy.sh
```

`destroy.sh` destroys the phases in reverse, whichever phase-4 mode is
deployed, deletes the images before the repository, then deletes the
`keygen-ocir` auth token and `~/.oci/ocir_token`. Switch modes by destroying
first.

## Notes

- **Lab only.** The API has no authentication and allows CORS from any
  origin, the web bucket is public, and generated private keys stay in
  NoSQL for a day. Anyone with a request ID can fetch its private key.
- In `vm` mode the worker's security list opens SSH (22) and the health port
  (8080) to `0.0.0.0/0`. Its SSH key is written to
  `04-worker/worker_key.pem` (gitignored).
- `keygen-workers-dg` matches **every** instance in the compartment, which
  by default is the tenancy root, so any instance there gets the worker's
  queue and NoSQL permissions.
- `destroy.sh` lists images with only `--compartment-id`, so it deletes
  **every** container image in the compartment, not just `keygen-functions`.
