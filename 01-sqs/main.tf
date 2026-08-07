# ==========================================================================================
# AWS Provider Configuration
# ------------------------------------------------------------------------------------------
# Purpose:
#   - Defines the AWS provider and its default region for all Terraform resources
#   - Ensures all modules and resources are deployed within the same region
#   - This configuration is required before any AWS resource declarations
# ==========================================================================================

provider "aws" {
  region = "us-east-1" # Primary AWS region (N. Virginia)
}


# ------------------------------------------------------------------------------
# AWS Data Sources
# ------------------------------------------------------------------------------
# Retrieve the current AWS account ID and active region for dynamic references.
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {} # Returns the AWS account ID and ARN
data "aws_region" "current" {}          # Returns the currently configured region
