# ================================================================================
# app.py  (for Lambda container)
# ================================================================================
# Purpose:
#   Lambda function invoked by SQS trigger to process SSH key generation
#   requests. Each SQS message must contain:
#       {
#         "correlation_id": "abc123",
#         "key_type": "rsa" | "ed25519",
#         "key_bits": 2048
#       }
#
# Environment Variables:
#   RESULTS_TABLE - DynamoDB table name for storing keygen results.
#   AWS_REGION    - AWS region, defaults to us-east-1.
#
# Behavior:
#   - Generates SSH keypair for each request.
#   - Base64-encodes public and private keys.
#   - Writes result to DynamoDB for retrieval by GET endpoint.
#   - Logs progress to CloudWatch.
# ================================================================================

import json
import base64
import os
import time
import logging
import boto3
from cryptography.hazmat.primitives.asymmetric import rsa, ed25519
from cryptography.hazmat.primitives import serialization

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
RESULTS_TABLE = os.getenv("RESULTS_TABLE")

dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table = dynamodb.Table(RESULTS_TABLE)

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ------------------------------------------------------------------------------
# SSH Key Generation Logic
# ------------------------------------------------------------------------------
def generate_keypair(key_type: str = "rsa", key_bits: int = 2048):
    """Generate SSH keypair and return (public, private) strings."""
    if key_type == "rsa":
        priv = rsa.generate_private_key(public_exponent=65537, key_size=key_bits)
    elif key_type == "ed25519":
        priv = ed25519.Ed25519PrivateKey.generate()
    else:
        logger.warning(f"Unknown key type '{key_type}', defaulting to RSA.")
        priv = rsa.generate_private_key(public_exponent=65537, key_size=key_bits)

    pub_ssh = priv.public_key().public_bytes(
        serialization.Encoding.OpenSSH,
        serialization.PublicFormat.OpenSSH
    ).decode()

    if key_type == "ed25519":
        priv_format = serialization.PrivateFormat.PKCS8
    else:
        priv_format = serialization.PrivateFormat.TraditionalOpenSSL

    priv_pem = priv.private_bytes(
        serialization.Encoding.PEM,
        priv_format,
        serialization.NoEncryption()
    ).decode()

    return pub_ssh, priv_pem

# ------------------------------------------------------------------------------
# Lambda Handler
# ------------------------------------------------------------------------------
def lambda_handler(event, context):
    """Triggered automatically by SQS."""
    for record in event.get("Records", []):
        try:
            body = json.loads(record["body"])
            corr_id = body.get("correlation_id", "unknown")
            key_type = body.get("key_type", "rsa")
            key_bits = body.get("key_bits")
            if not key_bits:
                key_bits = 2048
            else:
                key_bits = int(key_bits)

            logger.info(f"Processing request {corr_id} ({key_type}-{key_bits})")

            # ------------------------------------------------------------------
            # Generate SSH keypair
            # ------------------------------------------------------------------
            pub, priv = generate_keypair(key_type, key_bits)

            # ------------------------------------------------------------------
            # Prepare result item for DynamoDB
            # ------------------------------------------------------------------
            result = {
                "correlation_id": corr_id,
                "status": "complete",
                "key_type": key_type,
                "public_key_b64": base64.b64encode(pub.encode()).decode(),
                "private_key_b64": base64.b64encode(priv.encode()).decode(),
                "ttl": int(time.time()) + 86400  # expire after 1 day
            }

            # ------------------------------------------------------------------
            # Store result in DynamoDB
            # ------------------------------------------------------------------
            table.put_item(Item=result)
            logger.info(f"Stored result in DynamoDB for {corr_id}")

        except Exception as e:
            logger.exception(f"Failed processing message: {e}")

    return {"statusCode": 200, "body": "Batch processed"}

# ================================================================================
# End of File
# ================================================================================
