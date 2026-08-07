# ================================================================================
# File: dynamodb.tf
# ================================================================================
# Purpose:
#   Creates a DynamoDB table used by the KeyGen service to store
#   key generation results and metadata. Each record is identified
#   by a unique correlation ID.
#
# Notes:
#   - PAY_PER_REQUEST billing mode eliminates capacity management.
#   - TTL automatically expires old records after a defined period.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_dynamodb_table.keygen_results
# --------------------------------------------------------------------------------
# Description:
#   Defines the DynamoDB table where the KeyGen processor stores
#   completed key generation results. The correlation_id field
#   uniquely identifies each request-response transaction.
#
# Configuration:
#   - Primary key: correlation_id (string)
#   - TTL field  : ttl (automatically deletes expired entries)
# --------------------------------------------------------------------------------
resource "aws_dynamodb_table" "keygen_results" {
  name         = "keygen_results"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "correlation_id"

  attribute {
    name = "correlation_id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = {
    Name = "keygen_results"
  }
}
