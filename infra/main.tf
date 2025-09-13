resource "aws_dynamodb_table" "items" {
  name         = "many-mailer-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
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
