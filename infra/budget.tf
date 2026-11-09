# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Account-wide budget: this is a linked account and cost-allocation tags can't be
# activated from it, so a Project=otel-demo filter would match nothing yet.
# Every resource is still tagged Project=otel-demo (provider default_tags).

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = {
      actual80    = { threshold = 80, type = "ACTUAL" }
      actual100   = { threshold = 100, type = "ACTUAL" }
      forecast100 = { threshold = 100, type = "FORECASTED" }
    }
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value.threshold
      threshold_type             = "PERCENTAGE"
      notification_type          = notification.value.type
      subscriber_email_addresses = var.alert_emails
    }
  }
}
