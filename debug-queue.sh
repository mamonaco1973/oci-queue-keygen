#!/bin/bash
# ==============================================================================
# debug-queue.sh — can the queue take a message at all?
# ==============================================================================
# Splits the "Failed to enqueue request" failure in half by publishing with
# YOUR user credentials instead of the function's Resource Principal, using the
# exact queue OCID and endpoint Terraform handed the function.
#
#   Succeeds -> queue + endpoint are fine; the problem is the function's principal.
#   Fails    -> the OCID/endpoint pair is wrong and the function never could work.
#
# Not idempotent: a success leaves one real message on the queue, which the
# worker will pick up and write a row for under correlation_id 'cli-test'.
# ==============================================================================
set -euo pipefail

cd "$(dirname "$0")/01-queue"
QUEUE_ID=$(terraform output -raw queue_id)
QUEUE_ENDPOINT=$(terraform output -raw queue_endpoint)
cd ..

echo "NOTE: queue_id       - ${QUEUE_ID}"
echo "NOTE: queue_endpoint - ${QUEUE_ENDPOINT}"
echo "NOTE: Publishing a test message as your user..."

set +e
OUT=$(oci queue messages put-messages \
  --queue-id "${QUEUE_ID}" \
  --endpoint "${QUEUE_ENDPOINT}" \
  --messages '[{"content":"{\"correlation_id\":\"cli-test\",\"key_type\":\"rsa\",\"key_bits\":2048}"}]' 2>&1)
RC=$?
set -e

echo "${OUT}"

if [ ${RC} -eq 0 ]; then
  echo "RESULT: PASS — queue and endpoint are good. Problem is the function principal."
else
  echo "RESULT: FAIL (exit ${RC}) — queue OCID/endpoint pair is the problem."
fi
exit ${RC}
