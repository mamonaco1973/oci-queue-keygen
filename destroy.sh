#!/bin/bash
# ==============================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the KeyGen stack deployed by apply.sh, in reverse phase order:
#
#   Phase 5 (05-webapp):    Destroy Object Storage bucket and objects
#   Phase 4 (04-worker |    Destroy the queue processor — BOTH directories are
#            04-sch):       attempted, so a mode switch cannot strand resources
#   Phase 3 (03-functions): Destroy Functions, NoSQL, VCN, IAM, API Gateway
#   Phase 1 (01-queue):     Destroy Queue + OCIR repo (images purged first)
#
#   Phase 2 has no Terraform state — only the Docker image in OCIR, which is
#   deleted during the OCIR purge step before Phase 1 destroy.
#
# No environment variables required — all values derived from ~/.oci/config.
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Derive OCI identifiers (same logic as apply.sh)
# ------------------------------------------------------------------------------

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
USER_OCID=$(awk -F'=' '/^user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="$TENANCY_OCID"
fi

export TF_VAR_tenancy_ocid="$TENANCY_OCID"
export TF_VAR_compartment_id="$OCI_COMPARTMENT_ID"
export TF_VAR_region="$REGION"

# 03-functions and 04-worker declare queue/table variables that must resolve
# even for destroy (the values are unused for teardown). Pull them from state.
if [ -d 01-queue ]; then
  cd 01-queue
  export TF_VAR_queue_id="$(terraform output -raw queue_id 2>/dev/null || echo unused)"
  export TF_VAR_queue_endpoint="$(terraform output -raw queue_endpoint 2>/dev/null || echo unused)"
  cd ..
fi
if [ -d 03-functions ]; then
  cd 03-functions
  export TF_VAR_nosql_table_name="$(terraform output -raw nosql_table_name 2>/dev/null || echo keygen_results)"
  # 04-sch declares these as required with no default; they are unused for a
  # destroy but must still resolve, and 03-functions may already be gone.
  export TF_VAR_functions_application_id="$(terraform output -raw functions_application_id 2>/dev/null || echo unused)"
  export TF_VAR_image_path="$(terraform output -raw ocir_image_path 2>/dev/null || echo unused)"
  cd ..
fi

# ------------------------------------------------------------------------------
# Phase 5: Destroy static web application
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 5/5] Destroying web application..."

cd 05-webapp || { echo "ERROR: 05-webapp directory missing."; exit 1; }
terraform init
terraform destroy -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Phase 4: Destroy the queue processor (both modes)
# ------------------------------------------------------------------------------
# Deliberately mode-agnostic: destroy is also how you switch modes, and reading
# PROCESSING_MODE here would leave the *other* mode's resources running while
# apply.sh refuses to proceed because of them.  Directories with no state are
# skipped, so this is a no-op for whichever mode was never deployed.
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 4/5] Destroying queue processor..."

for phase4 in 04-worker 04-sch; do
  if [ ! -f "${phase4}/terraform.tfstate" ]; then
    echo "NOTE: ${phase4} has no state — skipping."
    continue
  fi
  if [ "$(jq -r '.resources | length' "${phase4}/terraform.tfstate" 2>/dev/null || echo 0)" = "0" ]; then
    echo "NOTE: ${phase4} state is empty — skipping."
    continue
  fi

  echo "NOTE: Destroying ${phase4}..."
  cd "${phase4}"
  terraform init
  terraform destroy -auto-approve || terraform destroy -auto-approve
  cd ..
done

# ------------------------------------------------------------------------------
# Phase 3: Destroy Functions, NoSQL, API Gateway
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 3/5] Destroying Functions, NoSQL, API Gateway..."

cd 03-functions || { echo "ERROR: 03-functions directory missing."; exit 1; }
terraform init
# Retry once — OCI IAM ETag optimistic locking causes spurious 412 failures
# on policy deletes when OCI modifies the resource between read and delete.
terraform destroy -auto-approve || terraform destroy -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Purge OCIR images before Phase 1 destroy
# ------------------------------------------------------------------------------
# Terraform cannot delete an OCIR repository while it still contains images.
# ------------------------------------------------------------------------------

echo "NOTE: Purging OCIR images from keygen-functions repository..."

IMAGE_IDS=$(oci artifacts container image list \
  --compartment-id "${OCI_COMPARTMENT_ID}" \
  --all \
  --query 'data.items[].id' \
  --output json 2>/dev/null | \
  jq -r '.[] // empty' 2>/dev/null || true)

if [[ -n "${IMAGE_IDS}" ]]; then
  echo "${IMAGE_IDS}" | while read -r IMG_ID; do
    echo "NOTE: Deleting image ${IMG_ID}..."
    oci artifacts container image delete \
      --image-id "${IMG_ID}" \
      --force 2>/dev/null || true
  done
else
  echo "NOTE: No OCIR images found to delete."
fi

# ------------------------------------------------------------------------------
# Phase 1: Destroy Queue and OCIR repository
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 1/5] Destroying Queue and OCIR repository..."

cd 01-queue || { echo "ERROR: 01-queue directory missing."; exit 1; }
terraform init
terraform destroy -auto-approve
cd ..

echo "NOTE: Infrastructure teardown complete."

# ------------------------------------------------------------------------------
# Delete OCIR auth token and remove local cache
# ------------------------------------------------------------------------------

echo "NOTE: Deleting OCIR auth token..."

TOKEN_FILE="${HOME}/.oci/ocir_token"

TOKEN_ID=$(oci iam auth-token list \
  --user-id "${USER_OCID}" \
  --query "data[?description=='keygen-ocir'].id | [0]" \
  --raw-output 2>/dev/null || echo "")

if [[ -n "${TOKEN_ID}" && "${TOKEN_ID}" != "null" ]]; then
  oci iam auth-token delete \
    --user-id "${USER_OCID}" \
    --auth-token-id "${TOKEN_ID}" \
    --force
  echo "NOTE: OCIR auth token deleted."
else
  echo "NOTE: No keygen-ocir auth token found — skipping."
fi

rm -f "${TOKEN_FILE}"
echo "NOTE: Removed cached token file ${TOKEN_FILE}."

# ==============================================================================
# End of script
# ==============================================================================
