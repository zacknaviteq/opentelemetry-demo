# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# CloudWatch for logs, metrics and traces:
#   - container stdout/stderr: awslogs -> /otel-demo/<service> (ecs.tf)
#   - OTel logs:    collector -> CloudWatch Logs OTLP endpoint -> /otel-demo/otel-logs
#   - OTel metrics: collector -> awsemf (filtered to span metrics) -> namespace OtelDemo
#   - OTel traces:  collector -> X-Ray OTLP endpoint (10% sampled) -> Transaction Search (aws/spans)

resource "aws_cloudwatch_log_group" "otel_logs" {
  name              = "/${var.name}/otel-logs"
  retention_in_days = var.log_retention_days
}

# Stream used by the collector's OTLP logs exporter (x-aws-log-stream: otel).
resource "aws_cloudwatch_log_stream" "otel_logs" {
  name           = "otel"
  log_group_name = aws_cloudwatch_log_group.otel_logs.name
}

resource "aws_cloudwatch_log_group" "metrics" {
  name              = "/${var.name}/metrics"
  retention_in_days = var.log_retention_days
}

# --- Transaction Search (account/region-wide setting) ---------------------------

# X-Ray creates the aws/spans log group itself ("aws/" names are reserved, so
# Terraform cannot pre-create it). Its retention is set after it appears.

data "aws_iam_policy_document" "xray_to_logs" {
  statement {
    sid     = "TransactionSearchXRayAccess"
    actions = ["logs:PutLogEvents"]
    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${var.account_id}:log-group:aws/spans:*",
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${var.account_id}:log-group:/aws/application-signals/data:*",
    ]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:xray:${var.region}:${var.account_id}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "xray" {
  policy_name     = "TransactionSearchXRayAccess"
  policy_document = data.aws_iam_policy_document.xray_to_logs.json
}

resource "aws_xray_trace_segment_destination" "this" {
  destination = "CloudWatchLogs"

  depends_on = [aws_cloudwatch_log_resource_policy.xray]
}

# --- Alerts --------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid     = "CloudWatchAndEventBridgePublish"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "events.amazonaws.com"]
    }
    resources = [aws_sns_topic.alerts.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}

locals {
  alarm_defaults = {
    period              = 300
    evaluation_periods  = 3
    datapoints_to_alarm = 3
    treat_missing_data  = "notBreaching" # services are scaled to 0 outside working hours
  }
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.name}-ecs-cpu-high"
  alarm_description   = "Cluster average CPU > 80% for 15 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name }
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  datapoints_to_alarm = local.alarm_defaults.datapoints_to_alarm
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_memory" {
  alarm_name          = "${var.name}-ecs-memory-high"
  alarm_description   = "Cluster average memory > 85% for 15 minutes"
  namespace           = "AWS/ECS"
  metric_name         = "MemoryUtilization"
  dimensions          = { ClusterName = aws_ecs_cluster.this.name }
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 85
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  datapoints_to_alarm = local.alarm_defaults.datapoints_to_alarm
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name}-alb-5xx"
  alarm_description   = "More than 20 ALB/target 5xx responses per 5 minutes, 3 periods in a row"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 20
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  datapoints_to_alarm = local.alarm_defaults.datapoints_to_alarm
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "total"
    expression  = "FILL(elb, 0) + FILL(target, 0)"
    label       = "5xx"
    return_data = true
  }

  metric_query {
    id = "elb"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.this.arn_suffix }
      stat        = "Sum"
      period      = local.alarm_defaults.period
    }
  }

  metric_query {
    id = "target"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.this.arn_suffix }
      stat        = "Sum"
      period      = local.alarm_defaults.period
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_unhealthy" {
  alarm_name          = "${var.name}-alb-unhealthy-targets"
  alarm_description   = "frontend-proxy target unhealthy for 15 minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.proxy.arn_suffix }
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = local.alarm_defaults.period
  evaluation_periods  = local.alarm_defaults.evaluation_periods
  datapoints_to_alarm = local.alarm_defaults.datapoints_to_alarm
  treat_missing_data  = local.alarm_defaults.treat_missing_data
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

# Spot interruptions: ECS task state change with the Spot stop code.
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.name}-spot-interruption"
  description = "Fargate Spot task interrupted in the ${var.name} cluster"

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [aws_ecs_cluster.this.arn]
      stopCode   = ["SpotInterruption"]
    }
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption_sns" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sns_topic.alerts.arn

  input_transformer {
    input_paths = {
      group = "$.detail.group"
      task  = "$.detail.taskArn"
    }
    input_template = "\"otel-demo: Fargate Spot interrupted <group> (<task>). ECS will start a replacement.\""
  }
}

# Count interruptions as a metric for the dashboard (log group as target).
resource "aws_cloudwatch_log_group" "spot_events" {
  name              = "/aws/events/${var.name}-spot-interruptions"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "events_to_logs" {
  statement {
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
    }
    resources = ["${aws_cloudwatch_log_group.spot_events.arn}:*"]
  }
}

resource "aws_cloudwatch_log_resource_policy" "events" {
  policy_name     = "${var.name}-eventbridge-to-logs"
  policy_document = data.aws_iam_policy_document.events_to_logs.json
}

resource "aws_cloudwatch_event_target" "spot_interruption_logs" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_cloudwatch_log_group.spot_events.arn

  depends_on = [aws_cloudwatch_log_resource_policy.events]
}

# --- Dashboard -----------------------------------------------------------------

locals {
  dash_services = ["frontend-proxy", "frontend", "cart", "checkout", "product-catalog", "agent", "otel-collector", "kafka"]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = var.name

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title   = "ECS CPU % (key services)"
          region  = var.region
          view    = "timeSeries"
          stat    = "Average"
          period  = 300
          metrics = [for s in local.dash_services : ["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", s]]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "ECS memory % (key services)"
          region  = var.region
          view    = "timeSeries"
          stat    = "Average"
          period  = 300
          metrics = [for s in local.dash_services : ["AWS/ECS", "MemoryUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", s]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ALB requests / 5xx / latency"
          region = var.region
          view   = "timeSeries"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = "p95", yAxis = "right" }],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Healthy / unhealthy frontend-proxy targets"
          region = var.region
          view   = "timeSeries"
          stat   = "Maximum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", aws_lb_target_group.proxy.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", aws_lb_target_group.proxy.arn_suffix, "LoadBalancer", aws_lb.this.arn_suffix],
          ]
        }
      },
      {
        type = "log", x = 0, y = 12, width = 12, height = 6
        properties = {
          title  = "Spot interruptions"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.spot_events.name}' | fields @timestamp, detail.group, detail.taskArn | sort @timestamp desc | limit 50"
        }
      },
      {
        type = "log", x = 12, y = 12, width = 12, height = 6
        properties = {
          title  = "Span calls per service (OtelDemo EMF)"
          region = var.region
          view   = "table"
          query  = "SOURCE '${aws_cloudwatch_log_group.metrics.name}' | filter ispresent(`traces.span.metrics.calls`) | stats sum(`traces.span.metrics.calls`) as calls by `service.name`, `status.code` | sort calls desc"
        }
      },
    ]
  })
}
