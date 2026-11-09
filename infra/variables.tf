variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account allowed for this configuration."
  type        = string
  default     = "960410382237"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "otel-demo"
}

variable "vpc_id" {
  description = "VPC to deploy into (default VPC)."
  type        = string
  default     = "vpc-043897a2ddd934611"
}

variable "public_subnet_ids" {
  description = "Existing public subnets (default VPC) for the ALB and the NAT gateway. The first one hosts the NAT gateway."
  type        = list(string)
  default = [
    "subnet-02e84cbb6f91489bf", # us-east-1a
    "subnet-0294fda90b78aab94", # us-east-1b
    "subnet-0086941979207149e", # us-east-1c
  ]
}

variable "private_subnets" {
  description = "Private subnets created for the ECS tasks (AZ => CIDR). CIDRs are unused ranges of the default VPC."
  type        = map(string)
  default = {
    "us-east-1a" = "172.31.96.0/20"
    "us-east-1b" = "172.31.112.0/20"
    "us-east-1c" = "172.31.128.0/20"
  }
}

variable "github_oidc_subjects" {
  description = <<-EOT
    Allowed GitHub OIDC `sub` claims for the deploy role. The repo uses GitHub's
    immutable subject format (repo:OWNER@OWNER_ID/REPO@REPO_ID:...); the legacy
    name-based format is kept in case the repo setting is reverted. Both are
    pinned to the main branch of zacknaviteq/opentelemetry-demo.
  EOT
  type        = list(string)
  default = [
    "repo:zacknaviteq@346338069/opentelemetry-demo@1435707629:ref:refs/heads/main",
    "repo:zacknaviteq/opentelemetry-demo:ref:refs/heads/main",
  ]
}

variable "ecr_images_to_keep" {
  description = "Images kept per service in ECR."
  type        = number
  default     = 5
}

variable "log_retention_days" {
  description = "Retention for all otel-demo CloudWatch log groups."
  type        = number
  default     = 14
}

variable "demo_version" {
  description = "Value of service.version in OTEL_RESOURCE_ATTRIBUTES (upstream IMAGE_VERSION)."
  type        = string
  default     = "3.1.0"
}

variable "trace_sampling_percentage" {
  description = "Percentage of traces exported to CloudWatch (X-Ray OTLP endpoint)."
  type        = number
  default     = 10
}

# --- Chatbot / Bedrock -------------------------------------------------------

variable "llm_model" {
  description = "Bedrock model ID used by the agent through the OpenAI-compatible endpoint."
  type        = string
  default     = "openai.gpt-oss-120b-1:0"
}

variable "llm_max_tokens" {
  description = "Max completion tokens per LLM call (cost guardrail)."
  type        = number
  default     = 2048
}

# --- Schedule ------------------------------------------------------------------

variable "schedule_enabled" {
  description = "Enable the working-hours start/stop schedules."
  type        = bool
  default     = true
}

variable "schedule_timezone" {
  description = "IANA timezone for the start/stop schedules (handles DST)."
  type        = string
  default     = "Asia/Jerusalem"
}

variable "schedule_days" {
  description = "Working days for the start/stop schedules (EventBridge cron day-of-week field)."
  type        = string
  default     = "SUN-THU"
}

variable "schedule_start_hour" {
  description = "Local hour at which services are started."
  type        = number
  default     = 8
}

variable "schedule_stop_hour" {
  description = "Local hour at which services are stopped."
  type        = number
  default     = 18
}

# --- Budget / alerts -----------------------------------------------------------

variable "monthly_budget_usd" {
  description = "Account-wide monthly cost budget."
  type        = number
  default     = 300
}

variable "alert_emails" {
  description = "Recipients of budget notifications and CloudWatch alarms."
  type        = list(string)
  default     = ["zack@naviteq.io"]
}
