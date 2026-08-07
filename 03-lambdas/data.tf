
# ================================================================================================
# File: data.tf
# ================================================================================================
# Purpose:
#   Resolves the ARNs and URLs for existing SQS queues used by the Lambda
#   key generation service. These data sources can reference either queues
#   created in the same Terraform workspace (via aws_sqs_queue.* resources)
#   or preexisting queues already deployed in AWS.
#
# Notes:
#   - Each data block retrieves both ARN and URL for the named queue.
#   - These values are consumed by the Lambda configuration to inject
#     environment variables and event source mappings.
# ================================================================================================

# -----------------------------------------------------------------------------------------------
# Data Source: keygen_input queue
# -----------------------------------------------------------------------------------------------
data "aws_sqs_queue" "keygen_input" {
  name = "keygen_input"
}


