terraform {
  required_version = ">= 0.14"
}

provider "aws" {
  region  = var.region
}

variable "region" {
  type = string
  default = "eu-central-1"
}

data "aws_caller_identity" "current" {}

# TODO: Add S3 Backend (maybe with a deploy script?)


### S3 Bucket ###
resource "aws_s3_bucket" "NateBotNewsletters" {
  bucket = "natebot-newsletter-bucket-${data.aws_caller_identity.current.account_id}"
  acl    = "private"
}

resource "aws_s3_bucket_public_access_block" "NateBotNewslettersPrivateBlock" {
  bucket = aws_s3_bucket.NateBotNewsletters.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

### Dynamo DB Table ###
resource "aws_dynamodb_table" "NatebotEmailTable" {
  name = "NatebotEmailTable"
  hash_key         = "Email"
  billing_mode     = "PAY_PER_REQUEST"

  attribute {
    name = "Email"
    type = "S"
  }
}

### IAM User ###
resource "aws_iam_user" "NateBotUser" {
  name = "NateBotUser"
  path = "/"
}

resource "aws_iam_access_key" "NateBotUserKey" {
  user = aws_iam_user.NateBotUser.name
}

resource "aws_iam_user_policy_attachment" "NateBotPolicyAttachment" {
  user       = aws_iam_user.NateBotUser.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayInvokeFullAccess"
}

output "NateBotUserSecretId" {
  value = aws_iam_access_key.NateBotUserKey.id
}

output "NateBotUserSecret" {
  value = aws_iam_access_key.NateBotUserKey.secret
}

### Lambda: Address Handler ###
resource "aws_iam_role" "NateBotAddressHandlerRole" {
  name = "NateBotAddressHandlerRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "NateBotAddressHandlerRoleAttach1" {
  role       = aws_iam_role.NateBotAddressHandlerRole.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "NateBotAddressHandlerRoleAttach2" {
  role       = aws_iam_role.NateBotAddressHandlerRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "NateBotAddressHandlerRoleAttach3" {
  role       = aws_iam_role.NateBotAddressHandlerRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSESFullAccess"
}

data "archive_file" "NateBotAddressHandlerZip" {
  source_file  = "${path.module}/../lib/addressHandlerLambda.py"
  output_path = "${path.module}/../lib/addressHandlerLambda.zip"
  type        = "zip"
}

resource "aws_lambda_function" "NateBotAddressHandler" {
  filename      = data.archive_file.NateBotAddressHandlerZip.output_path
  function_name = "NateBotAddressHandler"
  role          = aws_iam_role.NateBotAddressHandlerRole.arn
  handler       = "addressHandlerLambda.lambda_handler"
  source_code_hash = data.archive_file.NateBotAddressHandlerZip.output_base64sha256
  runtime = "python3.8"
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.NateBotAddressHandler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.NateBotAPI.id}/*/${aws_api_gateway_method.NateBotAPIMethod.http_method}${aws_api_gateway_resource.NateBotAPISignup.path}"
}

### API Gateway ###
resource "aws_api_gateway_rest_api" "NateBotAPI" {
  name = "NateBotAPI"
  description = "API for NateBot address handler"

}

resource "aws_api_gateway_resource" "NateBotAPISignup" {
  rest_api_id = aws_api_gateway_rest_api.NateBotAPI.id
  parent_id   = aws_api_gateway_rest_api.NateBotAPI.root_resource_id
  path_part   = "signup"
}

resource "aws_api_gateway_method" "NateBotAPIMethod" {
  rest_api_id   = aws_api_gateway_rest_api.NateBotAPI.id
  resource_id   = aws_api_gateway_resource.NateBotAPISignup.id
  http_method   = "POST"
  authorization = "AWS_IAM"
}

resource "aws_api_gateway_integration" "NateBotAPIIntegration" {
  rest_api_id             = aws_api_gateway_rest_api.NateBotAPI.id
  resource_id             = aws_api_gateway_resource.NateBotAPISignup.id
  http_method             = aws_api_gateway_method.NateBotAPIMethod.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.NateBotAddressHandler.invoke_arn
}

resource "aws_api_gateway_method_response" "NateBotAPIResponse" {
  rest_api_id = aws_api_gateway_rest_api.NateBotAPI.id
  resource_id = aws_api_gateway_resource.NateBotAPISignup.id
  http_method = aws_api_gateway_method.NateBotAPIMethod.http_method
  status_code = "200"
}

resource "aws_api_gateway_deployment" "NateBotDeployment" {
  depends_on = [aws_api_gateway_integration.NateBotAPIIntegration]

  rest_api_id = aws_api_gateway_rest_api.NateBotAPI.id
  stage_name  = "prod"

  lifecycle {
    create_before_destroy = true
  }
}

output "NateBotApiURL" {
  value = aws_api_gateway_deployment.NateBotDeployment.invoke_url
}

### Lambda: Email Sender ###
resource "aws_iam_role" "NateBotEmailSenderRole" {
  name = "NateBotEmailSenderRole"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "NateBotEmailSenderRoleAttach1" {
  role       = aws_iam_role.NateBotEmailSenderRole.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy_attachment" "NateBotEmailSenderRoleAttach2" {
  role       = aws_iam_role.NateBotEmailSenderRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "NateBotEmailSenderRoleAttach3" {
  role       = aws_iam_role.NateBotEmailSenderRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_role_policy_attachment" "NateBotEmailSenderRoleAttach4" {
  role       = aws_iam_role.NateBotEmailSenderRole.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSESFullAccess"
}

data "archive_file" "NateBotEmailSenderZip" {
  source_file  = "${path.module}/../lib/emailSenderLambda.py"
  output_path = "${path.module}/../lib/emailSenderLambda.zip"
  type        = "zip"
}

resource "aws_lambda_function" "NateBotEmailSender" {
  filename      = data.archive_file.NateBotEmailSenderZip.output_path
  function_name = "NateBotEmailSender"
  role          = aws_iam_role.NateBotEmailSenderRole.arn
  handler       = "emailSenderLambda.lambda_handler"
  source_code_hash = data.archive_file.NateBotEmailSenderZip.output_base64sha256
  runtime = "python3.8"
}

resource "aws_cloudwatch_event_rule" "every_hour" {
    name = "every-hour"
    description = "Fires every hour"
    schedule_expression = "rate(1 hour)"
}

resource "aws_cloudwatch_event_target" "fire_email_handler_lambda_hourly" {
    rule = aws_cloudwatch_event_rule.every_hour.name
    target_id = "NateBotEmailSender"
    arn = aws_lambda_function.NateBotEmailSender.arn
}

resource "aws_lambda_permission" "allow_cloudwatch_to_call_email_handler" {
    statement_id = "AllowExecutionFromCloudWatch"
    action = "lambda:InvokeFunction"
    function_name = aws_lambda_function.NateBotEmailSender.function_name
    principal = "events.amazonaws.com"
    source_arn = aws_cloudwatch_event_rule.every_hour.arn
}

### Lambda: Email Sender ###
resource "aws_ses_email_identity" "from_email" {
  email = "chancebair@gmail.com"
}