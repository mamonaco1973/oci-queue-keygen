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
#   The async path is API GW → Streaming → Service Connector Hub → worker.
#   The connector's batch window (~60s) plus a possible cold start means the
#   first result can take a couple of minutes — the poll loop is patient.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Step 0: Read endpoints from Terraform outputs
# ------------------------------------------------------------------------------
cd 03-functions || exit 1
api_url="$(terraform output -raw api_gateway_endpoint)"
cd ..

website_url="N/A"
if [ -d 04-webapp ]; then
  cd 04-webapp
  website_url="$(terraform output -raw website_url 2>/dev/null || echo "N/A")"
  cd ..
fi

echo "NOTE: API Gateway URL - ${api_url}"

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
