# ================================================================================
# Purpose:
#   Lambda function for the GET /result/{id} endpoint. Retrieves key
#   generation results from the DynamoDB table using the provided
#   correlation ID and returns either a completed result or a pending
#   status response.
#
# Environment Variables:
#   RESULTS_TABLE - DynamoDB table name for keygen results.
#
# Behavior:
#   - Reads correlation ID from API Gateway path parameters.
#   - Performs a DynamoDB GetItem() lookup.
#   - Returns HTTP 200 if the item exists (status: complete).
#   - Returns HTTP 202 if the item is not yet found (status: pending).
# ================================================================================

import os
import json
import boto3
import logging
import decimal

# ------------------------------------------------------------------------------
# Initialize DynamoDB client and table reference
# ------------------------------------------------------------------------------
dynamodb = boto3.resource("dynamodb")
table_name = os.getenv("RESULTS_TABLE")
table = dynamodb.Table(table_name)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ------------------------------------------------------------------------------
# Helper: Convert Decimal types to JSON-compatible values
# ------------------------------------------------------------------------------
def decimal_default(obj):
    """Converts DynamoDB Decimal objects to int or float for JSON dumps."""
    if isinstance(obj, decimal.Decimal):
        if obj % 1 == 0:
            return int(obj)
        else:
            return float(obj)
    raise TypeError

# ------------------------------------------------------------------------------
# Lambda Handler
# ------------------------------------------------------------------------------
def lambda_handler(event, context):
    """
    Handles GET /result/{id} requests from API Gateway.

    Parameters:
        event   (dict):  API Gateway event with pathParameters.id
        context (obj):   Lambda context object (unused)

    Returns:
        dict: HTTP response with status code and JSON body.
    """

    # --------------------------------------------------------------------------
    # Extract correlation ID from path parameters
    # --------------------------------------------------------------------------
    path_params = event.get("pathParameters", {}) or {}
    corr_id = path_params.get("id")
    if not corr_id:
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Missing correlation_id"})
        }

    logger.info(f"Fetching result for correlation_id: {corr_id}")

    # --------------------------------------------------------------------------
    # Query DynamoDB table for result item
    # --------------------------------------------------------------------------
    try:
        response = table.get_item(Key={"correlation_id": corr_id})
    except Exception as e:
        logger.exception(f"DynamoDB get_item failed: {e}")
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Internal server error"})
        }

    item = response.get("Item")

    # --------------------------------------------------------------------------
    # Return result if found, otherwise pending status
    # --------------------------------------------------------------------------
    if item:
        logger.info(f"Result found for {corr_id}")
        return {
            "statusCode": 200,
            "body": json.dumps(item, default=decimal_default)
        }

    logger.info(f"No result yet for {corr_id}")
    return {
        "statusCode": 202,
        "body": json.dumps({
            "status": "pending",
            "correlation_id": corr_id
        })
    }

# ================================================================================
# End of File
# ================================================================================
