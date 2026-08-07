# ================================================================================
# File: lambda-sqs.tf
# ================================================================================
# Purpose:
#   Defines an AWS Lambda function (container image) that processes
#   SQS messages for SSH key generation. Automatically connects the
#   Lambda to the input queue trigger and injects environment vars.
#
# Prerequisites:
#   - Existing ECR repository containing your Lambda image.
#   - Existing SQS queues for input (REQ) and optionally output (RESP).
#
# Variables required:
#   - var.aws_region
#   - var.lambda_image_uri  (ECR image URI with tag)
#   - var.req_queue_arn, var.req_queue_url
#   - var.resp_queue_url
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_exec_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda container function. Grants base
#   permissions required for execution and service access.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_exec_role" {
  name = "sqs-keygen-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Principal = { Service = "lambda.amazonaws.com" }
        Effect = "Allow"
      }
    ]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy_attachment.lambda_basic_execution
# --------------------------------------------------------------------------------
# Description:
#   Attaches AWS-managed basic execution policy for CloudWatch Logs
#   support.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy_attachment.lambda_sqs_execution
# --------------------------------------------------------------------------------
# Description:
#   Attaches AWS-managed SQS execution policy allowing the Lambda to
#   poll messages from the configured SQS queue.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_sqs_execution" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_send_output_policy
# --------------------------------------------------------------------------------
# Description:
#   Inline IAM policy granting the Lambda permission to write keygen
#   results to the DynamoDB results table.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_send_output_policy" {
  name = "lambda-write-dynamo-policy"
  role = aws_iam_role.lambda_exec_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowWriteToDynamoDB",
        Effect = "Allow",
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:GetItem"
        ],
        Resource = aws_dynamodb_table.keygen_results.arn
      }
    ]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.sqs_keygen_lambda
# --------------------------------------------------------------------------------
# Description:
#   Deploys the Lambda function that processes SQS keygen requests.
#   Runs from a container image stored in Amazon ECR.
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "sqs_keygen_lambda" {
  function_name = "sqs-keygen-processor"
  role          = aws_iam_role.lambda_exec_role.arn
  package_type  = "Image"
  image_uri     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${data.aws_region.current.id}.amazonaws.com/ssh-keygen:keygen-worker-rc1"
  timeout       = 60
  memory_size   = 512

  # Inject environment variables
  environment {
    variables = {
      RESULTS_TABLE = aws_dynamodb_table.keygen_results.name
    }
  }

  tracing_config {
    mode = "PassThrough"
  }

  tags = {
    Name = "sqs-keygen-processor"
  }
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_event_source_mapping.sqs_trigger
# --------------------------------------------------------------------------------
# Description:
#   Connects the input SQS queue to the Lambda function. Messages
#   arriving in the queue automatically invoke the Lambda handler.
# --------------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = data.aws_sqs_queue.keygen_input.arn
  function_name    = aws_lambda_function.sqs_keygen_lambda.arn
  batch_size       = 10
  enabled          = true
}
