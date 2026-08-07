# ================================================================================
# File: lambda_get.tf
# ================================================================================
# Purpose:
#   Deploys the "Responder" Lambda function that retrieves key
#   generation results from DynamoDB. This function is invoked by
#   the API Gateway GET /result/{id} route.
#
# Notes:
#   - Uses Python 3.11 runtime.
#   - Reads from the DynamoDB table created for keygen results.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role.lambda_get_role
# --------------------------------------------------------------------------------
# Description:
#   IAM role assumed by the Lambda function at runtime. The trust
#   policy allows the Lambda service to assume this role.
# --------------------------------------------------------------------------------
resource "aws_iam_role" "lambda_get_role" {
  name = "lambda-get-role"

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
# RESOURCE: aws_iam_role_policy_attachment.lambda_get_basic
# --------------------------------------------------------------------------------
# Description:
#   Attaches the AWS-managed basic execution policy to allow the
#   Lambda function to write logs to Amazon CloudWatch.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy_attachment" "lambda_get_basic" {
  role       = aws_iam_role.lambda_get_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_iam_role_policy.lambda_get_dynamo
# --------------------------------------------------------------------------------
# Description:
#   Inline IAM policy granting DynamoDB read access to the KeyGen
#   results table. Required for retrieving stored key pairs.
# --------------------------------------------------------------------------------
resource "aws_iam_role_policy" "lambda_get_dynamo" {
  name = "lambda-get-dynamo"
  role = aws_iam_role.lambda_get_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect   = "Allow",
      Action   = ["dynamodb:GetItem"],
      Resource = aws_dynamodb_table.keygen_results.arn
    }]
  })
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_function.lambda_get
# --------------------------------------------------------------------------------
# Description:
#   Deploys the "keygen-get" Lambda function. The function reads
#   DynamoDB entries using correlation_id and returns results to
#   API Gateway.
# --------------------------------------------------------------------------------
resource "aws_lambda_function" "lambda_get" {
  function_name    = "keygen-get"
  role             = aws_iam_role.lambda_get_role.arn
  runtime          = "python3.11"
  handler          = "get.lambda_handler"
  filename         = data.archive_file.lambdas_zip.output_path
  source_code_hash = data.archive_file.lambdas_zip.output_base64sha256
  timeout          = 15

  environment {
    variables = {
      RESULTS_TABLE = aws_dynamodb_table.keygen_results.name
    }
  }
}

# --------------------------------------------------------------------------------
# DATA: archive_file.lambdas_zip
# --------------------------------------------------------------------------------
# Description:
#   Packages Lambda source code from the local "code" directory
#   into a ZIP archive for deployment.
# --------------------------------------------------------------------------------
data "archive_file" "lambdas_zip" {
  type        = "zip"
  source_dir  = "${path.module}/code"
  output_path = "${path.module}/lambdas.zip"
}
