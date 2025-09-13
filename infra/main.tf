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

# DynamoDB access for your CRUD (broad to start; least-privilege later)
resource "aws_iam_role_policy_attachment" "lambda_dynamo" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
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
