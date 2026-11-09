locals {
  service_arn_prefix = "arn:${data.aws_partition.current.partition}:ecs:${var.region}:${var.account_id}:service/${var.name}"
  log_group_arn      = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${var.account_id}:log-group:/${var.name}/*"
  llm_model_arn      = "arn:${data.aws_partition.current.partition}:bedrock:${var.region}::foundation-model/${var.llm_model}"
}

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

# ---------------------------------------------------------------------------
# Task execution role: pull from our ECR repo, write awslogs
# ---------------------------------------------------------------------------
resource "aws_iam_role" "execution" {
  name               = "${var.name}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "execution" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid       = "EcrPull"
    actions   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [aws_ecr_repository.this.arn]
  }
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${local.log_group_arn}:*"]
  }
}

resource "aws_iam_role_policy" "execution" {
  name   = "execution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution.json
}

# ---------------------------------------------------------------------------
# Task roles: default (ECS Exec only), collector (CloudWatch/X-Ray), agent (Bedrock)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "task" {
  for_each = toset(["default", "collector", "agent"])

  name               = "${var.name}-task-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "ecs_exec" {
  statement {
    sid = "EcsExec"
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_exec" {
  for_each = aws_iam_role.task

  name   = "ecs-exec"
  role   = each.value.id
  policy = data.aws_iam_policy_document.ecs_exec.json
}

data "aws_iam_policy_document" "collector" {
  statement {
    sid = "OtelLogsAndEmf"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
    ]
    resources = [
      aws_cloudwatch_log_group.otel_logs.arn,
      "${aws_cloudwatch_log_group.otel_logs.arn}:*",
      aws_cloudwatch_log_group.metrics.arn,
      "${aws_cloudwatch_log_group.metrics.arn}:*",
    ]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "cloudwatch"
  role   = aws_iam_role.task["collector"].id
  policy = data.aws_iam_policy_document.collector.json
}

resource "aws_iam_role_policy_attachment" "collector_xray" {
  role       = aws_iam_role.task["collector"].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

data "aws_iam_policy_document" "agent" {
  statement {
    sid       = "InvokeChatModel"
    actions   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [local.llm_model_arn]
  }
  statement {
    sid       = "ShortTermApiKey"
    actions   = ["bedrock:CallWithBearerToken"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "agent" {
  name   = "bedrock"
  role   = aws_iam_role.task["agent"].id
  policy = data.aws_iam_policy_document.agent.json
}

# ---------------------------------------------------------------------------
# GitHub Actions OIDC deploy role (main branch only)
# The OIDC provider is owned by zacknaviteq/calc infra.
# ---------------------------------------------------------------------------
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_oidc_subjects
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name                 = "${var.name}-github-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_assume.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_deploy" {
  statement {
    sid       = "EcrAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
    ]
    resources = [aws_ecr_repository.this.arn]
  }
  statement {
    sid       = "EcsDeployAndScale"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = ["${local.service_arn_prefix}/*"]
  }
  statement {
    sid       = "EcsReadOnly"
    actions   = ["ecs:ListServices", "ecs:ListTasks", "ecs:DescribeTasks"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_deploy" {
  name   = "deploy"
  role   = aws_iam_role.github_deploy.id
  policy = data.aws_iam_policy_document.github_deploy.json
}
