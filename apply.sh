# ================================================================================
# File: apply.sh
# ================================================================================
# Purpose:
#   Automates full deployment of the KeyGen service, including SQS, ECR,
#   Lambda, API Gateway, and static web components. Each step validates
#   its environment and applies Terraform modules in order.
#
# Notes:
#   - Requires AWS CLI, Terraform, and Docker to be installed.
#   - Assumes valid AWS credentials and permissions are configured.
# ================================================================================

# --------------------------------------------------------------------------------
# GLOBAL CONFIGURATION
# --------------------------------------------------------------------------------
# Sets the AWS region and enforces strict Bash error handling:
#   -e : Exit immediately on command failure
#   -u : Treat unset variables as errors
#   -o pipefail : Catch errors in piped commands
# --------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
set -euo pipefail

# --------------------------------------------------------------------------------
# ENVIRONMENT PRE-CHECK
# --------------------------------------------------------------------------------
# Ensures that required tools, variables, and credentials exist before
# proceeding with resource deployment.
# --------------------------------------------------------------------------------
echo "NOTE: Running environment validation..."
./check_env.sh
if [ $? -ne 0 ]; then
  echo "ERROR: Environment validation failed. Exiting."
  exit 1
fi

# --------------------------------------------------------------------------------
# BUILD SQS AND ECR RESOURCES
# --------------------------------------------------------------------------------
# Initializes and applies the Terraform configuration that creates
# SQS queues and ECR repositories required for the KeyGen workflow.
# --------------------------------------------------------------------------------
echo "NOTE: Building SQS and ECR resources..."

cd 01-sqs || { echo "ERROR: 01-sqs not found."; exit 1; }

terraform init
terraform apply -auto-approve

cd .. || exit

# --------------------------------------------------------------------------------
# BUILD SSH-KEYGEN DOCKER IMAGE AND PUSH TO ECR
# --------------------------------------------------------------------------------
# Builds the ssh-keygen container image and uploads it to Amazon ECR.
# Used later by the Lambda or ECS processor components.
# --------------------------------------------------------------------------------
echo "NOTE: Building ssh-keygen Docker image and pushing to ECR..."

cd 02-docker/ssh-keygen || {
  echo "ERROR: ssh-keygen directory missing."
  exit 1
}

# Retrieve AWS account ID for ECR references
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
  echo "ERROR: Failed to retrieve AWS Account ID. Exiting."
  exit 1
fi

# Authenticate Docker with AWS ECR using token-based login
aws ecr get-login-password --region ${AWS_DEFAULT_REGION} | \
docker login --username AWS --password-stdin \
"${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com" || {
  echo "ERROR: Docker authentication failed. Exiting."
  exit 1
}

# ================================================================================
# BUILD AND PUSH RSTUDIO DOCKER IMAGE (IF MISSING FROM ECR)
# ================================================================================
# Verifies whether the required image exists in ECR and builds/pushes it
# only if not found. Prevents redundant uploads.
# ================================================================================
IMAGE_TAG="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_DEFAULT_REGION}.amazonaws.com/ssh-keygen:keygen-worker-rc1"

echo "NOTE: Checking if image already exists in ECR..."

# Query ECR for the image
if aws ecr describe-images \
    --repository-name ssh-keygen \
    --image-ids imageTag="keygen-worker-rc1" \
    --region "${AWS_DEFAULT_REGION}" >/dev/null 2>&1; then
  echo "NOTE: Image already exists in ECR: ${IMAGE_TAG}"
else
  echo "WARNING: Image not found in ECR. Building and pushing..."

  docker buildx build \
  	--platform linux/amd64 \
  	--provenance=false \
  	--sbom=false \
  	--output type=docker \
  	-t "${IMAGE_TAG}" . || 
  {
    echo "ERROR: Docker build failed. Exiting."
    exit 1
  }

  docker push "${IMAGE_TAG}" || {
    echo "ERROR: Docker push failed. Exiting."
    exit 1
  }

  echo "NOTE: Image successfully built and pushed to ECR: ${IMAGE_TAG}"
fi

cd ../.. || exit

# --------------------------------------------------------------------------------
# BUILD LAMBDAS AND API GATEWAY
# --------------------------------------------------------------------------------
# Deploys the Lambda functions and API Gateway endpoints via Terraform.
# --------------------------------------------------------------------------------
echo "NOTE: Building Lambdas and API gateway..."

cd 03-lambdas || { echo "ERROR: 03-lambdas directory missing."; exit 1; }

terraform init
terraform apply -auto-approve

cd .. || exit

# --------------------------------------------------------------------------------
# BUILD SIMPLE WEB APPLICATION
# --------------------------------------------------------------------------------
# Creates a static web client that communicates with the deployed API
# Gateway. Substitutes the API URL into the HTML template.
# --------------------------------------------------------------------------------
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='keygen-api'].ApiId" \
  --output text)

if [[ -z "${API_ID}" || "${API_ID}" == "None" ]]; then
  echo "ERROR: No API found with name 'keygen-api'"
  exit 1
fi

URL=$(aws apigatewayv2 get-api \
  --api-id "${API_ID}" \
  --query "ApiEndpoint" \
  --output text)

export API_BASE="${URL}"
echo "NOTE: API Gateway URL - ${API_BASE}"

echo "NOTE: Building Simple Web Application..."

cd 04-webapp || { echo "ERROR: 04-webapp directory missing."; exit 1; }

envsubst '${API_BASE}' < index.html.tmpl > index.html || {
  echo "ERROR: Failed to generate index.html file. Exiting."
  exit 1
}

terraform init
terraform apply -auto-approve

cd .. || exit

# --------------------------------------------------------------------------------
# BUILD VALIDATION
# --------------------------------------------------------------------------------
# Optionally runs post-deployment validation once implemented.
# --------------------------------------------------------------------------------
echo "NOTE: Running build validation..."
./validate.sh

# ================================================================================
# END OF SCRIPT
# ================================================================================
