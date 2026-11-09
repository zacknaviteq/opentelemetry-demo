# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Working-hours schedule: start at 08:00 and stop at 18:00 local time
# (Asia/Jerusalem, DST-aware) on var.schedule_days. The ALB and NAT gateway
# are not touched. site-control.yml remains a manual override.

data "archive_file" "scaler" {
  type        = "zip"
  source_file = "${path.module}/lambda/scaler.py"
  output_path = "${path.module}/.build/scaler.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scaler" {
  name               = "${var.name}-scaler"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_cloudwatch_log_group" "scaler" {
  name              = "/aws/lambda/${var.name}-scaler"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "scaler" {
  statement {
    sid       = "ScaleServices"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["${local.service_arn_prefix}/*"]
  }
  statement {
    sid       = "ListServices"
    actions   = ["ecs:ListServices"]
    resources = ["*"]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.scaler.arn}:*"]
  }
}

resource "aws_iam_role_policy" "scaler" {
  name   = "scale"
  role   = aws_iam_role.scaler.id
  policy = data.aws_iam_policy_document.scaler.json
}

resource "aws_lambda_function" "scaler" {
  function_name    = "${var.name}-scaler"
  role             = aws_iam_role.scaler.arn
  runtime          = "python3.13"
  architectures    = ["arm64"]
  handler          = "scaler.handler"
  filename         = data.archive_file.scaler.output_path
  source_code_hash = data.archive_file.scaler.output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      CLUSTER  = aws_ecs_cluster.this.name
      SERVICES = join(",", local.scheduled_services)
    }
  }

  depends_on = [aws_cloudwatch_log_group.scaler, aws_iam_role_policy.scaler]
}

# --- EventBridge Scheduler -------------------------------------------------------

data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "${var.name}-scheduler"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

data "aws_iam_policy_document" "scheduler" {
  statement {
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.scaler.arn]
  }
}

resource "aws_iam_role_policy" "scheduler" {
  name   = "invoke-scaler"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler.json
}

resource "aws_scheduler_schedule_group" "this" {
  name = var.name
}

locals {
  schedules = {
    start = var.schedule_start_hour
    stop  = var.schedule_stop_hour
  }
}

resource "aws_scheduler_schedule" "this" {
  for_each = local.schedules

  name                         = "${var.name}-${each.key}"
  group_name                   = aws_scheduler_schedule_group.this.name
  description                  = "${each.key} otel-demo services at ${each.value}:00 ${var.schedule_timezone} on ${var.schedule_days}"
  state                        = var.schedule_enabled ? "ENABLED" : "DISABLED"
  schedule_expression          = "cron(0 ${each.value} ? * ${var.schedule_days} *)"
  schedule_expression_timezone = var.schedule_timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = aws_lambda_function.scaler.arn
    role_arn = aws_iam_role.scheduler.arn
    input    = jsonencode({ action = each.key })

    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 3600
    }
  }
}
