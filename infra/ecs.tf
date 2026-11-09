resource "aws_ecs_cluster" "this" {
  name = var.name

  # Container Insights is billed per metric; ECS service CPU/memory metrics in
  # AWS/ECS are free and enough for the alarms below.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }
}

resource "aws_cloudwatch_log_group" "service" {
  for_each = local.task_specs

  name              = "/${var.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_service_discovery_service" "this" {
  for_each = local.task_specs

  name = each.key

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {}
}

# local.services mixes object shapes, so flatten it into a uniformly typed map
# (container definitions pre-rendered as JSON) that for_each accepts.
locals {
  task_specs = {
    for svc, cfg in local.services : svc => {
      cpu        = cfg.cpu
      memory     = cfg.memory
      capacity   = cfg.capacity
      role       = cfg.role
      always_off = try(cfg.always_off, false)
      volumes    = join(",", try(cfg.volumes, []))
      containers = jsonencode([
        for c in cfg.containers : { for k, v in {
          name         = c.name
          image        = "${aws_ecr_repository.this.repository_url}:latest-${c.image}"
          essential    = try(c.essential, true)
          command      = try(c.command, null)
          user         = try(c.user, null)
          dependsOn    = try(c.depends_on, null)
          mountPoints  = try(c.mounts, [])
          volumesFrom  = []
          portMappings = [for p in try(c.ports, []) : { containerPort = p, hostPort = p, protocol = "tcp" }]
          environment  = [for name in sort(keys(c.env)) : { name = name, value = c.env[name] }]
          linuxParameters = {
            initProcessEnabled = true # needed for ECS Exec
          }
          logConfiguration = {
            logDriver = "awslogs"
            options = {
              awslogs-group         = "/${var.name}/${svc}"
              awslogs-region        = var.region
              awslogs-stream-prefix = c.name
            }
          }
          systemControls = []
        } : k => v if v != null }
      ])
    }
  }
}

resource "aws_ecs_task_definition" "this" {
  for_each = local.task_specs

  family                   = "${var.name}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = each.value.cpu
  memory                   = each.value.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task[each.value.role].arn
  container_definitions    = each.value.containers

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  dynamic "volume" {
    for_each = toset(compact(split(",", each.value.volumes)))
    content {
      name = volume.value
    }
  }

  depends_on = [aws_cloudwatch_log_group.service]
}

resource "aws_ecs_service" "this" {
  for_each = local.task_specs

  name                   = each.key
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this[each.key].arn
  desired_count          = 0 # owned by the schedule / site-control after creation
  enable_execute_command = true
  propagate_tags         = "SERVICE"

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = each.key == "frontend-proxy" ? 120 : null

  deployment_circuit_breaker {
    enable   = true
    rollback = false
  }

  dynamic "capacity_provider_strategy" {
    for_each = each.value.capacity == "ondemand" ? [1] : []
    content {
      capacity_provider = "FARGATE"
      weight            = 1
      base              = 0
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = each.value.capacity == "spot" ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
      base              = 0
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = each.value.capacity == "proxy" ? [1] : []
    content {
      capacity_provider = "FARGATE"
      weight            = 0
      base              = 1
    }
  }

  dynamic "capacity_provider_strategy" {
    for_each = each.value.capacity == "proxy" ? [1] : []
    content {
      capacity_provider = "FARGATE_SPOT"
      weight            = 1
      base              = 0
    }
  }

  network_configuration {
    subnets          = [for s in aws_subnet.private : s.id]
    security_groups  = [aws_security_group.tasks.id]
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.this[each.key].arn
  }

  dynamic "load_balancer" {
    for_each = each.key == "frontend-proxy" ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.proxy.arn
      container_name   = "frontend-proxy"
      container_port   = 8080
    }
  }

  lifecycle {
    # desiredCount is driven by the EventBridge schedule and site-control.yml.
    ignore_changes = [desired_count]
  }

  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_lb_listener.http,
    aws_iam_role_policy.execution,
  ]
}
