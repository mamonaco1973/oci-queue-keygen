# ================================================================================
# File: api.tf
# ================================================================================
# Purpose:
#   Provides REST-style endpoints for the key generation workflow:
#     - POST /keygen      → Enqueue key generation request
#     - GET  /result/{id} → Retrieve key generation result
#
# Notes:
#   - Uses HTTP API (v2) for simplicity and cost efficiency.
#   - Each route integrates directly with a Lambda function.
# ================================================================================

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_api.keygen_api
# --------------------------------------------------------------------------------
# Description:
#   Creates an HTTP API that exposes the KeyGen Lambda endpoints.
#   CORS configuration allows client access during development.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "keygen_api" {
  name          = "keygen-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins  = ["*"]              # Restrict to domain in production
    allow_methods  = ["GET", "POST", "OPTIONS"]
    allow_headers  = ["content-type"]
    expose_headers = ["content-type"]
    max_age        = 300
  }
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_integration.post_keygen_integration
# --------------------------------------------------------------------------------
# Description:
#   Connects POST /keygen route to the keygen-post Lambda function.
#   Uses AWS_PROXY integration for full event passthrough.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "post_keygen_integration" {
  api_id                 = aws_apigatewayv2_api.keygen_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_post.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_integration.get_result_integration
# --------------------------------------------------------------------------------
# Description:
#   Connects GET /result/{id} route to the keygen-get Lambda function.
#   Uses AWS_PROXY integration for full event passthrough.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_integration" "get_result_integration" {
  api_id                 = aws_apigatewayv2_api.keygen_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.lambda_get.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_route.post_keygen_route
# --------------------------------------------------------------------------------
# Description:
#   Defines the POST /keygen route mapped to the POST integration.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_route" "post_keygen_route" {
  api_id    = aws_apigatewayv2_api.keygen_api.id
  route_key = "POST /keygen"
  target    = "integrations/${aws_apigatewayv2_integration.post_keygen_integration.id}"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_route.get_result_route
# --------------------------------------------------------------------------------
# Description:
#   Defines the GET /result/{id} route mapped to the GET integration.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_route" "get_result_route" {
  api_id    = aws_apigatewayv2_api.keygen_api.id
  route_key = "GET /result/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.get_result_integration.id}"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_apigatewayv2_stage.keygen_stage
# --------------------------------------------------------------------------------
# Description:
#   Creates the default stage for automatic API deployment.
# --------------------------------------------------------------------------------
resource "aws_apigatewayv2_stage" "keygen_stage" {
  api_id      = aws_apigatewayv2_api.keygen_api.id
  name        = "$default"
  auto_deploy = true
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_permission.allow_post_invoke
# --------------------------------------------------------------------------------
# Description:
#   Grants API Gateway permission to invoke the keygen-post Lambda.
# --------------------------------------------------------------------------------
resource "aws_lambda_permission" "allow_post_invoke" {
  statement_id  = "AllowAPIGatewayInvokePost"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_post.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.keygen_api.execution_arn}/*/*"
}

# --------------------------------------------------------------------------------
# RESOURCE: aws_lambda_permission.allow_get_invoke
# --------------------------------------------------------------------------------
# Description:
#   Grants API Gateway permission to invoke the keygen-get Lambda.
# --------------------------------------------------------------------------------
resource "aws_lambda_permission" "allow_get_invoke" {
  statement_id  = "AllowAPIGatewayInvokeGet"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_get.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.keygen_api.execution_arn}/*/*"
}

# --------------------------------------------------------------------------------
# OUTPUT: keygen_api_endpoint (optional)
# --------------------------------------------------------------------------------
# output "keygen_api_endpoint" {
#   description = "Invoke URL for the Keygen API Gateway"
#   value       = aws_apigatewayv2_stage.keygen_stage.invoke_url
# }
