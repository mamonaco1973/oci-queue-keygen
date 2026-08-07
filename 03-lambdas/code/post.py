# ================================================================================
# Purpose:
#   Lambda function for the POST /keygen endpoint. Accepts key generation
#   requests from API Gateway, generates a unique correlation ID, and sends
#   the request to the SQS input queue for asynchronous processing.
#
# Environment Variables:
#   REQ_QUEUE_URL - SQS queue URL for key generation requests.
#
# Behavior:
#   - Parses JSON payload from API Gateway event.
#   - Generates a UUID4 correlation ID.
#   - Constructs and enqueues the request message.
#   - Returns HTTP 202 with the correlation ID for tracking.
# ================================================================================

import json
import os
import uuid
import boto3

# ------------------------------------------------------------------------------
# Initialize global SQS client (reused between invocations for efficiency)
# ------------------------------------------------------------------------------
sqs = boto3.client("sqs")

# ------------------------------------------------------------------------------
# Lambda Handler
# ------------------------------------------------------------------------------
def lambda_handler(event, context):
    """
    Handles POST /keygen requests from API Gateway.

    Parameters:
        event   (dict): API Gateway event containing JSON body.
        context (obj):  Lambda context object (unused).

    Returns:
        dict: HTTP response with 202 status and correlation ID.
    """

    # --------------------------------------------------------------------------
    # Parse the JSON payload from API Gateway event.
    # Example input:
    #   {
    #     "key_type": "rsa",
    #     "key_bits": 2048
    #   }
    # Body can be empty.
    # --------------------------------------------------------------------------
    body_raw = event.get("body")
    try:
        body = json.loads(body_raw) if body_raw else {}
    except Exception:
        body = {}

    # --------------------------------------------------------------------------
    # Generate a unique correlation ID for tracking.
    # --------------------------------------------------------------------------
    corr_id = str(uuid.uuid4())

    # --------------------------------------------------------------------------
    # Construct normalized message for the keygen worker Lambda.
    # --------------------------------------------------------------------------
    msg = {
        "correlation_id": corr_id,
        "key_type": body.get("key_type", "rsa"),
        "key_bits": body.get("key_bits", 2048)
    }

    # --------------------------------------------------------------------------
    # Send the message to the keygen input queue for async processing.
    # --------------------------------------------------------------------------
    sqs.send_message(
        QueueUrl=os.environ["REQ_QUEUE_URL"],
        MessageBody=json.dumps(msg)
    )

    # --------------------------------------------------------------------------
    # Return HTTP 202 Accepted response with correlation ID.
    # --------------------------------------------------------------------------
    return {
        "statusCode": 202,
        "body": json.dumps({
            "request_id": corr_id,
            "status": "queued"
        })
    }

# ================================================================================
# End of File
# ================================================================================
