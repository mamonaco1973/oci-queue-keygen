#!/bin/bash
# ==============================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the async SSH KeyGen service on OCI.
#
#   Phase 1 (01-queue):     Creates OCIR repository + OCI Queue
#   Phase 2 (02-docker):    Builds the functions image and pushes it to OCIR
#   Phase 3 (03-functions): Deploys Functions (post/get), NoSQL, VCN, IAM, API GW
#   Phase 4:                Deploys the queue processor — see PROCESSING_MODE
#   Phase 5 (05-webapp):    Injects API URL into HTML and deploys to Object Storage
#
# No environment variables are required.  Everything is derived automatically
# from ~/.oci/config and the OCI CLI.  An OCIR auth token is created on the
# first run and saved to ~/.oci/ocir_token for reuse on subsequent runs.
#
# Optional env vars:
#   OCI_COMPARTMENT_ID  Defaults to tenancy OCID from ~/.oci/config when unset
#   PROCESSING_MODE     vm (default) | sch — which Phase 4 to deploy
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Processing mode — how a queued request reaches compute
# ------------------------------------------------------------------------------
#   vm  → 04-worker: a long-polling consumer daemon on a micro-VM.
#   sch → 04-sch:    Connector Hub batching Queue → worker Function.
#
# The two are mutually exclusive and live in separate state, so this is a shell
# variable rather than a Terraform one: it decides which directory Phase 4
# enters, which Terraform cannot do from inside a module.
# ------------------------------------------------------------------------------

PROCESSING_MODE="${PROCESSING_MODE:-vm}"

case "${PROCESSING_MODE}" in
  vm)  PHASE4_DIR="04-worker"; PHASE4_OTHER="04-sch"    ;;
  sch) PHASE4_DIR="04-sch";    PHASE4_OTHER="04-worker" ;;
  *)
    echo "ERROR: PROCESSING_MODE must be 'vm' or 'sch' (got '${PROCESSING_MODE}')."
    exit 1
    ;;
esac

# Refuse to run alongside the other mode.  Both consume the same queue, so a
# stranded VM would silently steal messages from the connector (or vice versa)
# and the latency numbers would be measuring a race, not a design.
if [ -f "${PHASE4_OTHER}/terraform.tfstate" ] && \
   [ "$(jq -r '.resources | length' "${PHASE4_OTHER}/terraform.tfstate" 2>/dev/null || echo 0)" != "0" ]; then
  echo "ERROR: ${PHASE4_OTHER} still has deployed resources."
  echo "NOTE: Both modes consume the same queue — run ./destroy.sh first,"
  echo "NOTE: then re-apply with PROCESSING_MODE=${PROCESSING_MODE}."
  exit 1
fi

# validate.sh gates the worker health check on this, so it must be inherited.
export PROCESSING_MODE

echo "NOTE: Processing mode - ${PROCESSING_MODE} (Phase 4 = ${PHASE4_DIR})"

# ------------------------------------------------------------------------------
# Environment validation
# ------------------------------------------------------------------------------

echo "NOTE: Running environment validation..."
./check_env.sh

# ------------------------------------------------------------------------------
# Derive OCI identifiers from ~/.oci/config
# ------------------------------------------------------------------------------

TENANCY_OCID=$(awk -F'=' '/^tenancy[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
REGION=$(awk -F'=' '/^region[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)
USER_OCID=$(awk -F'=' '/^user[[:space:]]*=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' ~/.oci/config)

# Compartment falls back to tenancy root when OCI_COMPARTMENT_ID is not set.
if [ -z "${OCI_COMPARTMENT_ID:-}" ]; then
  OCI_COMPARTMENT_ID="$TENANCY_OCID"
  echo "NOTE: OCI_COMPARTMENT_ID not set — using tenancy OCID as compartment."
fi

NAMESPACE=$(oci os ns get --query 'data' --raw-output)

# OCIR username: namespace/username-string (not OCID).
USER_NAME=$(oci iam user get --user-id "${USER_OCID}" --query 'data.name' --raw-output)
OCIR_USERNAME="${NAMESPACE}/${USER_NAME}"
OCIR_HOST="${REGION}.ocir.io"

echo "NOTE: Region      - ${REGION}"
echo "NOTE: Namespace   - ${NAMESPACE}"
echo "NOTE: Compartment - ${OCI_COMPARTMENT_ID}"
echo "NOTE: OCIR user   - ${OCIR_USERNAME}"

# ------------------------------------------------------------------------------
# OCIR auth token — created once, cached in ~/.oci/ocir_token
# ------------------------------------------------------------------------------
# OCI auth tokens can only be read at creation time.  On first run this block
# creates one via the OCI CLI and writes it to the cache file.  Max 2 tokens
# per user — delete old ones in the Console if creation fails.
# ------------------------------------------------------------------------------

TOKEN_FILE="${HOME}/.oci/ocir_token"

if [ -f "${TOKEN_FILE}" ] && [ -s "${TOKEN_FILE}" ]; then
  echo "NOTE: Using cached OCIR token from ${TOKEN_FILE}"
  OCIR_TOKEN=$(cat "${TOKEN_FILE}")
else
  echo "NOTE: No cached OCIR token found — creating one via OCI CLI..."
  OCIR_TOKEN=$(oci iam auth-token create \
    --user-id "${USER_OCID}" \
    --description "keygen-ocir" \
    --query 'data.token' \
    --raw-output)

  echo "${OCIR_TOKEN}" > "${TOKEN_FILE}"
  chmod 600 "${TOKEN_FILE}"
  echo "NOTE: OCIR token created and saved to ${TOKEN_FILE}"
fi

# Export Terraform variables shared across all phases.
export TF_VAR_tenancy_ocid="$TENANCY_OCID"
export TF_VAR_compartment_id="$OCI_COMPARTMENT_ID"
export TF_VAR_region="$REGION"

# Export OCIR vars for 02-docker/build.sh.
export OCIR_HOST OCIR_TOKEN OCIR_USERNAME NAMESPACE

# ------------------------------------------------------------------------------
# Phase 1: Create OCIR repository and Queue
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 1/5] Creating OCIR repository and Queue..."

cd 01-queue || { echo "ERROR: 01-queue directory missing."; exit 1; }
terraform init
terraform apply -auto-approve

# Capture queue identifiers to hand to Phase 3 (post fn) and Phase 4 (consumer).
QUEUE_ID=$(terraform output -raw queue_id)
QUEUE_ENDPOINT=$(terraform output -raw queue_endpoint)
cd ..

export TF_VAR_queue_id="${QUEUE_ID}"
export TF_VAR_queue_endpoint="${QUEUE_ENDPOINT}"
echo "NOTE: Queue OCID     - ${QUEUE_ID}"
echo "NOTE: Queue endpoint - ${QUEUE_ENDPOINT}"

# ------------------------------------------------------------------------------
# Phase 2: Build and push Docker image
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 2/5] Building and pushing Docker image..."

./02-docker/build.sh

# Source the image path written by build.sh and pass it to Phase 3.
# shellcheck source=/dev/null
source 02-docker/.build_output
export TF_VAR_image_path="${IMAGE_PATH}"

# ------------------------------------------------------------------------------
# Phase 3: Deploy Functions, NoSQL, and API Gateway
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 3/5] Deploying Functions, NoSQL, and API Gateway..."

cd 03-functions || { echo "ERROR: 03-functions directory missing."; exit 1; }
terraform init
terraform apply -auto-approve
API_BASE=$(terraform output -raw api_gateway_endpoint)
NOSQL_TABLE_NAME=$(terraform output -raw nosql_table_name)
FUNCTIONS_APP_ID=$(terraform output -raw functions_application_id)
cd ..

export TF_VAR_nosql_table_name="${NOSQL_TABLE_NAME}"
# Only 04-sch consumes this, but exporting unconditionally keeps the phase
# hand-off uniform across modes.
export TF_VAR_functions_application_id="${FUNCTIONS_APP_ID}"
echo "NOTE: API Gateway endpoint - ${API_BASE}"

# ------------------------------------------------------------------------------
# Phase 4: Deploy the queue processor (mode-dependent)
# ------------------------------------------------------------------------------
# Needs the queue (Phase 1) and NoSQL table (Phase 3), both exported above.
# 04-sch additionally needs the image path and Functions Application OCID.
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 4/5] Deploying queue processor (${PROCESSING_MODE})..."

cd "${PHASE4_DIR}" || { echo "ERROR: ${PHASE4_DIR} directory missing."; exit 1; }
terraform init
terraform apply -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Phase 5: Build and deploy the static web application
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 5/5] Deploying static web application..."

cd 05-webapp || { echo "ERROR: 05-webapp directory missing."; exit 1; }

export API_BASE
envsubst '${API_BASE}' < index.html.tmpl > index.html || {
  echo "ERROR: Failed to generate index.html"
  exit 1
}

terraform init
terraform apply -auto-approve
cd ..

# ------------------------------------------------------------------------------
# Post-deployment validation
# ------------------------------------------------------------------------------
# Functions cold-start on first call and the worker's cloud-init takes a minute
# to install deps + start the daemon; validate.sh polls with retries to absorb
# both, so no fixed pre-wait is needed here.
# ------------------------------------------------------------------------------

echo "NOTE: Running post-deployment validation..."
./validate.sh

# ==============================================================================
# End of script
# ==============================================================================
