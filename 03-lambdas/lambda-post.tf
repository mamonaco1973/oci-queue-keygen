# ================================================================================
# File: lambda_post.tf
# ================================================================================
# Purpose:
#   Deploys the "Requester" Lambda function that enqueues key
#   generation requests to the SQS input queue. This function is
#   invoked by the API Gateway POST /keygen route.
#
# Notes:
#   - Uses Python 3.11 runtime.
#   - Sends messages to the keygen_input SQS queue.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_post_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function during execution.
#   The trust policy allows the Lambda service to assume this
#   role at runtime.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_post_role" {
  name = "lambda-post-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
      Effect = "Allow"
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy_attachment.lambda_post_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to grant
#   CloudWatch Logs access for the Lambda function.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_post_basic" {
  role       = aws_iam_role.lambda_post_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_post_sqs
# --------------------------------------------------------------------------------
# Description:
#   Inline IAM policy that allows the Lambda function to send
#   messages to the keygen_input SQS queue.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_post_sqs" {
  name = "lambda-requester-sqs"
  role = aws_iam_role.lambda_post_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = data.aws_sqs_queue.keygen_input.arn
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.lambda_post
# --------------------------------------------------------------------------------
# Description:
#   Deploys the "keygen-post" Lambda function. The function
#   enqueues key generation requests into the input SQS queue.
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_post" {
  function_name    = "keygen-post"
  role             = aws_iam_role.lambda_post_role.arn
  runtime          = "python3.11"
  handler          = "post.lambda_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      REQ_QUEUE_URL = data.aws_sqs_queue.keygen_input.url
    }
  }
}
