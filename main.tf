provider "aws" {
  alias  = "source"
  region = var.region
}

# Make sure data resource is configured correctly
data "aws_region" "current" {
  provider = aws.source
}

resource "aws_cloudwatch_log_group" "source_log_group" {
  provider = aws.source
  name     = var.source_log_group_name
}

resource "aws_iam_role" "log_forwarder_role" {
  name = "LogForwarderLambdaRole"

  assume_role_policy = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Action": "sts:AssumeRole",
        "Principal": { "Service": "lambda.amazonaws.com" },
        "Effect": "Allow"
      }
    ]
  }
  EOF
}

resource "aws_iam_role_policy" "log_forwarder_policy" {
  role = aws_iam_role.log_forwarder_role.id

  policy = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "kinesis:PutRecord",
          "kinesis:PutRecords"
        ],
        "Resource": "${var.kinesis_stream_arn}"
      },
      {
        "Effect": "Allow",
        "Action": [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ],
        "Resource": "*"
      }
    ]
  }
  EOF
}

resource "aws_lambda_function" "log_forwarder" {
  function_name = var.log_forwarder_lambda_name
  handler       = "index.handler"
  runtime       = "python3.8"
  role          = aws_iam_role.log_forwarder_role.arn
  filename      = "lambda/log_forwarder.zip"
}

# Add explicit permission for CloudWatch Logs to invoke Lambda
resource "aws_lambda_permission" "allow_cloudwatch_to_invoke_lambda" {
  statement_id  = "AllowCloudWatchLogsToInvokeLambda"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.log_forwarder.function_name
  principal     = "logs.amazonaws.com"
  source_arn    = aws_cloudwatch_log_group.source_log_group.arn
}

resource "aws_iam_role" "log_subscription_role" {
  name = var.log_subscription_role_name

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": { "Service": "logs.${data.aws_region.current.name}.amazonaws.com" },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_iam_policy" "log_subscription_policy" {
  name = "LogSubscriptionPolicy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "kinesis:PutRecord"
      ],
      "Resource": "${var.kinesis_stream_arn}"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "log_subscription_policy_attachment" {
  role       = aws_iam_role.log_subscription_role.name
  policy_arn = aws_iam_policy.log_subscription_policy.arn
}

resource "aws_iam_policy" "log_subscription_invoke_lambda_policy" {
  policy = <<EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "lambda:InvokeFunction",
        "Resource": "${aws_lambda_function.log_forwarder.arn}"
      }
    ]
  }
  EOF
}

resource "aws_iam_role_policy_attachment" "log_subscription_invoke_lambda_policy_attachment" {
  role       = aws_iam_role.log_subscription_role.name
  policy_arn = aws_iam_policy.log_subscription_invoke_lambda_policy.arn
}

resource "aws_cloudwatch_log_subscription_filter" "log_subscription" {
  provider             = aws.source
  name                 = "CentralLogStreamSubscription"
  log_group_name       = aws_cloudwatch_log_group.source_log_group.name
  filter_pattern       = ""
  destination_arn      = aws_lambda_function.log_forwarder.arn

  depends_on = [aws_lambda_permission.allow_cloudwatch_to_invoke_lambda]
}
