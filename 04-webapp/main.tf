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
