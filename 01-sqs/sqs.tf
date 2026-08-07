# ================================================================================
# File: sqs.tf
# ================================================================================
# Purpose:
#   Creates an Amazon SQS queue for the key generation pipeline.
#   The queue receives key generation requests from client services.
#
# Notes:
#   - SQS is fully managed; no VPC configuration is required.
#   - Messages can be sent via AWS SDK, CLI, Lambda, or ECS services.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_sqs_queue.keygen_input
# --------------------------------------------------------------------------------
# Description:
#   Defines the input queue that receives key generation requests.
#
# Configuration:
#   - Visibility timeout: 60s (locks message during processing)
#   - Retention period : 1 day (86400s)
#   - Long polling     : 10s (reduces API calls and latency)
# --------------------------------------------------------------------------------
resource "aws_sqs_queue" "keygen_input" {
  name                      = "keygen_input"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 86400
  delay_seconds              = 0
  max_message_size           = 262144
  receive_wait_time_seconds  = 10

  tags = {
    Name        = "keygen_input"
    Environment = "dev"
    Purpose     = "keygen-service"
  }
}
