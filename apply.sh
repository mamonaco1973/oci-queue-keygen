#!/bin/bash
# ==============================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the async SSH KeyGen service on OCI.
#
#   Phase 1 (01-stream):    Creates OCIR repository + Streaming stream
#   Phase 2 (02-docker):    Builds the functions image and pushes it to OCIR
#   Phase 3 (03-functions): Deploys Functions, NoSQL, VCN, IAM, API Gateway,
#                           and the Service Connector (Streaming → worker)
#   Phase 4 (04-webapp):    Injects API URL into HTML and deploys to Object Storage
#
# No environment variables are required.  Everything is derived automatically
# from ~/.oci/config and the OCI CLI.  An OCIR auth token is created on the
# first run and saved to ~/.oci/ocir_token for reuse on subsequent runs.
#
# Optional env var:
#   OCI_COMPARTMENT_ID  Defaults to tenancy OCID from ~/.oci/config when unset
# ==============================================================================

set -euo pipefail

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
# Phase 1: Create OCIR repository and Streaming stream
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 1/4] Creating OCIR repository and Streaming stream..."

cd 01-stream || { echo "ERROR: 01-stream directory missing."; exit 1; }
terraform init
terraform apply -auto-approve

# Capture stream identifiers to hand to Phase 3 (post fn + Service Connector).
STREAM_ID=$(terraform output -raw stream_id)
STREAM_ENDPOINT=$(terraform output -raw stream_endpoint)
cd ..

export TF_VAR_stream_id="${STREAM_ID}"
export TF_VAR_stream_endpoint="${STREAM_ENDPOINT}"
echo "NOTE: Stream OCID     - ${STREAM_ID}"
echo "NOTE: Stream endpoint - ${STREAM_ENDPOINT}"

# ------------------------------------------------------------------------------
# Phase 2: Build and push Docker image
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 2/4] Building and pushing Docker image..."

./02-docker/build.sh

# Source the image path written by build.sh and pass it to Phase 3.
# shellcheck source=/dev/null
source 02-docker/.build_output
export TF_VAR_image_path="${IMAGE_PATH}"

# ------------------------------------------------------------------------------
# Phase 3: Deploy Functions, NoSQL, API Gateway, and Service Connector
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 3/4] Deploying Functions, NoSQL, API Gateway, Connector..."

cd 03-functions || { echo "ERROR: 03-functions directory missing."; exit 1; }
terraform init
terraform apply -auto-approve
API_BASE=$(terraform output -raw api_gateway_endpoint)
cd ..

echo "NOTE: API Gateway endpoint - ${API_BASE}"

# ------------------------------------------------------------------------------
# Phase 4: Build and deploy the static web application
# ------------------------------------------------------------------------------

echo "NOTE: [Phase 4/4] Deploying static web application..."

cd 04-webapp || { echo "ERROR: 04-webapp directory missing."; exit 1; }

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
# OCI Functions pull the container image from OCIR on first invocation.
# Wait briefly to allow the cold start to complete before hitting the API.
# ------------------------------------------------------------------------------

echo "NOTE: Waiting 60s for function cold start readiness..."
sleep 60

echo "NOTE: Running post-deployment validation..."
./validate.sh

# ==============================================================================
# End of script
# ==============================================================================
