# Private subnets + a single NAT gateway in the default VPC. The NAT gateway
# and ALB stay up 24/7 (the ALB DNS name is the public URL and must not change).

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = var.vpc_id
  availability_zone       = each.key
  cidr_block              = each.value
  map_public_ip_on_launch = false

  tags = { Name = "${var.name}-private-${each.key}" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name}-nat" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = var.public_subnet_ids[0]
  tags          = { Name = "${var.name}-nat" }
}

resource "aws_route_table" "private" {
  vpc_id = var.vpc_id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# --- Security groups -----------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "otel-demo public ALB"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Public HTTP"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_proxy" {
  for_each = toset(["8080", "10000"])

  security_group_id            = aws_security_group.alb.id
  description                  = "To frontend-proxy port ${each.key}"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
}

resource "aws_security_group" "tasks" {
  name        = "${var.name}-tasks"
  description = "otel-demo ECS tasks"
  vpc_id      = var.vpc_id
  tags        = { Name = "${var.name}-tasks" }
}

resource "aws_vpc_security_group_ingress_rule" "tasks_self" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "Service-to-service traffic"
  referenced_security_group_id = aws_security_group.tasks.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_http" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "ALB to frontend-proxy"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "tasks_from_alb_admin" {
  security_group_id            = aws_security_group.tasks.id
  description                  = "ALB health check to Envoy admin /ready"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 10000
  to_port                      = 10000
}

resource "aws_vpc_security_group_egress_rule" "tasks_all" {
  security_group_id = aws_security_group.tasks.id
  description       = "Outbound (AWS APIs, ECR, Bedrock, peers)"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# --- Service discovery ---------------------------------------------------------

resource "aws_service_discovery_private_dns_namespace" "this" {
  name        = "${var.name}.local"
  description = "otel-demo service discovery (compose hostnames as <svc>.${var.name}.local)"
  vpc         = var.vpc_id
}
