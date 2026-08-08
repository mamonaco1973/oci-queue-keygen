#!/bin/bash
# ==============================================================================
# validate.sh — KeyGen end-to-end smoke test
# ------------------------------------------------------------------------------
# Purpose:
#   - Read the API Gateway endpoint and website URL from Terraform outputs.
#   - Submit a keygen request and poll until the worker writes the result.
#   - Print quick-start endpoints.
#
# Requirements:
#   - curl, jq, terraform, OCI CLI (authenticated); deployment completed.
#
# Note on timing:
#   The async path is API GW → post fn → Queue → VM consumer (long-poll) → NoSQL.
#   Steady-state latency is near-instant, but on the FIRST deploy the worker's
#   cloud-init needs a minute or two to install deps and start the daemon, so
#   the poll loop is patient.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Step 0: Read endpoints from Terraform outputs
# ------------------------------------------------------------------------------
cd 03-functions || exit 1
api_url="$(terraform output -raw api_gateway_endpoint)"
cd ..

website_url="N/A"
if [ -d 05-webapp ]; then
  cd 05-webapp
  website_url="$(terraform output -raw website_url 2>/dev/null || echo "N/A")"
  cd ..
fi

echo "NOTE: API Gateway URL - ${api_url}"

# ------------------------------------------------------------------------------
# Step 0b: Wait for the worker to report healthy before submitting
# ------------------------------------------------------------------------------
# The worker's /health endpoint returns 200 only after its first successful
# authorized queue poll — i.e. deps installed, instance-principal auth
# propagated, queue reachable.  This distinguishes "still booting" from "broken"
# and avoids submitting into a void on a fresh deploy.
# ------------------------------------------------------------------------------
worker_ip=""
if [ -d 04-worker ]; then
  cd 04-worker
  worker_ip="$(terraform output -raw worker_public_ip 2>/dev/null || echo "")"
  cd ..
fi

if [ -n "${worker_ip}" ]; then
  echo "NOTE: Waiting for worker health at http://${worker_ip}:8080/health ..."
  # ~30 min: cloud-init deps install is quick, but a brand-new dynamic group +
  # instance principal can take many minutes to propagate on a fresh deploy.
  HEALTH_ATTEMPTS=30      # 30 checks
  HEALTH_INTERVAL=60      # 60s apart = up to 30 minutes
  for ((h=1; h<=HEALTH_ATTEMPTS; h++)); do
    if curl -fsS -m 5 "http://${worker_ip}:8080/health" >/dev/null 2>&1; then
      echo "NOTE: Worker is ready."
      break
    fi
    echo "NOTE: Worker not ready yet (${h}/${HEALTH_ATTEMPTS}) — waiting ${HEALTH_INTERVAL}s..."
    sleep "${HEALTH_INTERVAL}"
    if [[ "${h}" -eq "${HEALTH_ATTEMPTS}" ]]; then
      echo "ERROR: Worker never became healthy after ~30 min — check 'journalctl -u keygen-worker' on the VM."
      exit 1
    fi
  done
else
  echo "WARN: worker_public_ip output not found — skipping health gate."
fi

# ------------------------------------------------------------------------------
# Step 1: Submit an SSH key generation request
# ------------------------------------------------------------------------------
KEY_TYPE="${KEY_TYPE:-rsa}"
KEY_BITS="${KEY_BITS:-2048}"

req_payload="$(jq -n \
  --arg kt "${KEY_TYPE}" \
  --arg kb "${KEY_BITS}" \
  '{ key_type: $kt, key_bits: ($kb | tonumber) }')"

echo "NOTE: Sending request - key_type=${KEY_TYPE}, key_bits=${KEY_BITS}"

response="$(curl -s -X POST "${api_url}/keygen" \
  -H "Content-Type: application/json" \
  -d "${req_payload}")"

request_id="$(echo "${response}" | jq -r '.request_id // empty')"

if [[ -z "${request_id}" ]]; then
  echo "ERROR: No request_id returned."
  echo "NOTE: Response was: ${response}"
  exit 1
fi

echo "NOTE: Submitted keygen request (${request_id})."
echo "NOTE: Polling for result..."

# ------------------------------------------------------------------------------
# Step 2: Poll the result endpoint until complete
# ------------------------------------------------------------------------------
MAX_ATTEMPTS=60
SLEEP_SECONDS=5

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
  result="$(curl -s "${api_url}/result/${request_id}")"
  status="$(echo "${result}" | jq -r '.status // empty')"

  if [[ "${status}" == "complete" ]]; then
    echo "NOTE: Key generation complete."
    break
  fi

  echo "NOTE: Attempt ${i}/${MAX_ATTEMPTS}: pending..."
  sleep "${SLEEP_SECONDS}"

  if [[ "${i}" -eq "${MAX_ATTEMPTS}" ]]; then
    echo "ERROR: Key generation did not complete in time."
    exit 1
  fi
done

# ------------------------------------------------------------------------------
# Final Quick Start Output
# ------------------------------------------------------------------------------
echo ""
echo "============================================================================"
echo "KeyGen Quick Start - Validation Output"
echo "============================================================================"
echo ""
echo "NOTE: Test Web URL:    ${website_url}"
echo "NOTE: API Base URI:    ${api_url}"
echo ""
echo "NOTE: Validation complete."
echo ""
