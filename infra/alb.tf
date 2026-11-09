# Internet-facing ALB on :80 -> frontend-proxy (Envoy). Never stopped by the
# schedule so its DNS name (the public URL) stays stable.

resource "aws_lb" "this" {
  name               = var.name
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
  idle_timeout       = 300 # chatbot (LLM) responses can be slow

  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "proxy" {
  name                 = "${var.name}-proxy"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 15

  health_check {
    # Envoy admin readiness: the proxy itself, independent of upstreams.
    port                = "10000"
    path                = "/ready"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy.arn
  }
}
