#!/bin/bash
# ================================================================================
# File: destroy.sh
# ================================================================================
# Purpose:
#   Tears down all resources created by the KeyGen service deployment.
#   Sequentially destroys Terraform-managed components and deletes
#   the ECR repository if present.
#
# Notes:
#   - Requires Terraform, AWS CLI, and valid AWS credentials.
#   - Executes destruction in reverse order of creation.
# ================================================================================

# --------------------------------------------------------------------------------
# GLOBAL CONFIGURATION
# --------------------------------------------------------------------------------
# Sets the AWS region and enables strict Bash error handling:
#   -e : Exit on any command error
#   -u : Treat unset variables as errors
#   -o pipefail : Fail entire pipeline if any command fails
# --------------------------------------------------------------------------------
export AWS_DEFAULT_REGION="us-east-1"
set -euo pipefail

# --------------------------------------------------------------------------------
# DESTROY WEB APPLICATION
# --------------------------------------------------------------------------------
# Destroys the S3 static web app and supporting Terraform resources
# under the 04-webapp directory.
# --------------------------------------------------------------------------------
echo "NOTE: Destroying Web Application..."

cd 04-webapp || { echo "ERROR: Directory 04-webapp not found."; exit 1; }
terraform init
terraform destroy -auto-approve
cd .. || exit

# --------------------------------------------------------------------------------
# DESTROY LAMBDAS AND API GATEWAY
# --------------------------------------------------------------------------------
# Removes the Lambda functions and associated API Gateway routes
# created during deployment.
# --------------------------------------------------------------------------------
echo "NOTE: Destroying Lambdas and API Gateway..."

cd 03-lambdas || { echo "ERROR: Directory 03-lambdas not found."; exit 1; }
terraform init
terraform destroy -auto-approve
cd .. || exit

# --------------------------------------------------------------------------------
# DESTROY SQS AND ECR RESOURCES
# --------------------------------------------------------------------------------
# Deletes the ECR repository (if it exists) and destroys the SQS
# queues and related Terraform resources.
# --------------------------------------------------------------------------------
aws ecr delete-repository --repository-name "ssh-keygen" --force || {
  echo "WARN: Failed to delete ECR repository. It may not exist."
}

echo "NOTE: Destroying SQS and ECR..."

cd 01-sqs || { echo "ERROR: Directory 01-sqs not found."; exit 1; }
terraform init
terraform destroy -auto-approve
cd .. || exit

# --------------------------------------------------------------------------------
# COMPLETION
# --------------------------------------------------------------------------------
# Confirms successful teardown of all Terraform-managed resources.
# --------------------------------------------------------------------------------
echo "NOTE: Infrastructure teardown complete."

# ================================================================================
# END OF SCRIPT
# ================================================================================
