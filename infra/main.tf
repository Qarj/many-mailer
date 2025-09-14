resource "aws_dynamodb_table" "items" {
  name         = "many-mailer-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

resource "aws_iam_role" "lambda_exec" {
  name = "many-mailer-lambda-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "lambda.amazonaws.com" },
      Action   = "sts:AssumeRole"
    }]
  })
}

# CloudWatch Logs permissions for the function runtime
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Inline least-privilege IAM policy for Lambda access to the specific DynamoDB table
resource "aws_iam_role_policy" "lambda_dynamo_inline" {
  name = "many-mailer-lambda-dynamo-inline"
  role = aws_iam_role.lambda_exec.name

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ],
        Resource = aws_dynamodb_table.items.arn
      }
    ]
  })
}

resource "aws_lambda_function" "api" {
  function_name = "many-mailer-api"
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.handler"       # index.js exports handler
  runtime       = "nodejs20.x"
  filename      = "${path.module}/artifacts/lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/artifacts/lambda.zip")
  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.items.name
    }
  }
}
# Explicit log group for the Lambda with 7-day retention.
# If this log group already exists (created automatically by Lambda),
# import it with:
#   terraform import aws_cloudwatch_log_group.lambda_logs "/aws/lambda/many-mailer-api"
resource "aws_cloudwatch_log_group" "lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.api.function_name}"
  retention_in_days = 7
}


resource "aws_apigatewayv2_api" "http" {
  name          = "many-mailer-http"
  protocol_type = "HTTP"
  cors_configuration {
    allow_origins = ["https://qarj.github.io","http://localhost:7075"]
    allow_methods = ["GET","POST","PUT","DELETE","OPTIONS"]
    allow_headers = ["content-type","authorization"]
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "any_root" {
  api_id    = aws_apigatewayv2_api.http.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

resource "aws_apigatewayv2_stage" "prod" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "prod"
  auto_deploy = true
}

output "api_base_url" {
  value = aws_apigatewayv2_stage.prod.invoke_url
}
