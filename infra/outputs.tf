output "shop_url" {
  description = "Public URL of the shop (ALB DNS name, HTTP)."
  value       = "${local.public_url}/"
}

output "chatbot_url" {
  description = "Public URL of the AI chatbot."
  value       = "${local.public_url}/chatbot/"
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.this.dns_name
}

output "ecs_cluster" {
  description = "ECS cluster name (repo variable ECS_CLUSTER)."
  value       = aws_ecs_cluster.this.name
}

output "ecr_repository" {
  description = "ECR repository name (repo variable ECR_REPOSITORY)."
  value       = aws_ecr_repository.this.name
}

output "ecr_repository_url" {
  description = "ECR repository URL."
  value       = aws_ecr_repository.this.repository_url
}

output "github_deploy_role_arn" {
  description = "Deploy role ARN (repo variable AWS_ROLE_ARN)."
  value       = aws_iam_role.github_deploy.arn
}

output "scheduled_services" {
  description = "Services started by the schedule / site-control (comma-separated, repo variable ECS_SERVICES)."
  value       = join(",", local.scheduled_services)
}

output "image_to_service" {
  description = "ECR image name => ECS service."
  value       = local.image_to_service
}

output "scaler_function" {
  description = "Lambda used by the schedules (can be invoked manually)."
  value       = aws_lambda_function.scaler.function_name
}

output "dashboard_url" {
  description = "CloudWatch dashboard."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}"
}
