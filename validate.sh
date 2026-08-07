#!/bin/bash
# ==============================================================================
# validate.sh - KeyGen Quick Start Validation
# ------------------------------------------------------------------------------
# Purpose:
#   - Discover API Gateway endpoint via AWS CLI.
#   - Retrieve static website URL from Terraform output.
#   - Submit keygen request and validate async processing.
#   - Print quick-start endpoints for testing.
#
# Fast-Fail Behavior:
#   - Script exits immediately on command failure, unset variables,
#     or failed pipelines.
#
# Requirements:
#   - curl, jq, Terraform, and AWS CLI installed and authenticated.
#   - Terraform deployment completed successfully.
# ==============================================================================
set -euo pipefail
export AWS_DEFAULT_REGION="us-east-1"

# ------------------------------------------------------------------------------
# Step 0: Retrieve static website URL from Terraform
# ------------------------------------------------------------------------------
cd ./04-webapp || exit 1
website_url="$(terraform output -raw website_https_url)"
cd ..

# ------------------------------------------------------------------------------
# Step 1: Discover API Gateway endpoint
# ------------------------------------------------------------------------------
echo "NOTE: Locating API Gateway endpoint..."

api_id="$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='keygen-api'].ApiId" \
  --output text)"

if [[ -z "${api_id}" || "${api_id}" == "None" ]]; then
  echo "ERROR: No API found with name 'keygen-api'"
  exit 1
fi

api_url="$(aws apigatewayv2 get-api \
  --api-id "${api_id}" \
  --query "ApiEndpoint" \
  --output text)"

echo "NOTE: API Gateway URL - ${api_url}"

# ------------------------------------------------------------------------------
# Step 2: Submit SSH key generation request
# ------------------------------------------------------------------------------
KEY_TYPE="${KEY_TYPE:-rsa}"
KEY_BITS="${KEY_BITS:-2048}"

req_payload="$(
  jq -n \
    --arg kt "${KEY_TYPE}" \
    --arg kb "${KEY_BITS}" \
    '{ key_type: $kt, key_bits: ($kb | tonumber) }'
)"

echo "NOTE: Sending request - key_type=${KEY_TYPE}, key_bits=${KEY_BITS}"

response="$(
  curl -s -X POST "${api_url}/keygen" \
    -H "Content-Type: application/json" \
    -d "${req_payload}"
)"

request_id="$(echo "${response}" | jq -r '.request_id // empty')"

if [[ -z "${request_id}" ]]; then
  echo "ERROR: No request_id returned."
  echo "NOTE: Response was: ${response}"
  exit 1
fi

echo "NOTE: Submitted keygen request (${request_id})."
echo "NOTE: Polling for result..."

# ------------------------------------------------------------------------------
# Step 3: Poll result endpoint until complete
# ------------------------------------------------------------------------------
MAX_ATTEMPTS=30
SLEEP_SECONDS=2

for ((i=1; i<=MAX_ATTEMPTS; i++)); do
  result="$(curl -s "${api_url}/result/${request_id}")"
  status="$(echo "${result}" | jq -r '.status // empty')"

  if [[ "${status}" == "complete" ]]; then
    echo "NOTE: Key generation complete."
    break
  fi

  if [[ "${status}" == "error" ]]; then
    echo "ERROR: Service reported an error."
    echo "${result}" | jq
    exit 1
  fi

  echo "NOTE: Attempt ${i}/${MAX_ATTEMPTS}: pending..."
  sleep "${SLEEP_SECONDS}"

  if [[ "${i}" -eq "${MAX_ATTEMPTS}" ]]; then
    echo "ERROR: Key generation did not complete."
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

if [ -n "${website_url}" ] && [ "${website_url}" != "None" ]; then
  echo "NOTE: Test Web URL:    ${website_url}"
else
  echo "WARN: Static website URL not found"
fi

if [ -n "${api_url}" ] && [ "${api_url}" != "None" ]; then
  echo "NOTE: API Base URI:    ${api_url}"
else
  echo "WARN: API Gateway endpoint not found"
fi

echo ""
echo "NOTE: Validation complete."
echo ""