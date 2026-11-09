# otel-demo AWS infra

Terraform for running the OpenTelemetry demo on ECS Fargate (ARM64, mostly Spot)
in account `960410382237` / `us-east-1`.

State: `s3://calc-tfstate-960410382237/opentelemetry-demo/infra/terraform.tfstate`
(shared bucket with `zacknaviteq/calc`, S3 native locking).

```sh
cd infra
terraform init
terraform plan
terraform apply
```

## What it creates

| Area | Resources |
| --- | --- |
| Network | 3 private subnets in the default VPC, 1 NAT gateway, task and ALB security groups, Cloud Map namespace `otel-demo.local` |
| Public access | Internet-facing ALB on HTTP :80 -> `frontend-proxy` (Envoy). Output `shop_url`. Never stopped by the schedule, so the URL is stable |
| Compute | ECS cluster `otel-demo`, one ARM64 service per demo component (`services.tf`). Stateless services on `FARGATE_SPOT`; `kafka`, `astronomy-db`, `valkey-cart`, `otel-collector` on `FARGATE`; `frontend-proxy` has an on-demand base of 1 |
| Images | ECR `opentelemetry-demo`, tags `<sha>-<image>` and `latest-<image>`, scan on push, last 5 per image kept |
| Observability | awslogs `/otel-demo/<service>` (14 days); collector -> X-Ray OTLP (Transaction Search, 10% sampled), EMF namespace `OtelDemo` (span RED metrics only), OTLP logs `/otel-demo/otel-logs`; dashboard `otel-demo`; alarms + Spot interruption notifications to SNS `otel-demo-alerts` |
| Chatbot | Agent calls Bedrock `openai.gpt-oss-120b-1:0` through the OpenAI-compatible endpoint with a short-term API key minted from its task role (`LLM_AUTH=bedrock-iam`); `LLM_MAX_TOKENS` caps output |
| Schedule | EventBridge Scheduler (`Asia/Jerusalem`): start 08:00, stop 18:00 on `schedule_days` (default `SUN-THU`) via the `otel-demo-scaler` Lambda |
| Budget | `otel-demo-monthly`, $300, account-wide, e-mails at 80% / 100% actual and 100% forecasted |
| CI/CD | OIDC role `otel-demo-github-deploy` (main branch only) |

Transaction Search (`aws_xray_trace_segment_destination`) is an account/region-wide
setting: X-Ray segments from any workload in the region go to the `aws/spans` log group.

## GitHub repo variables

Optional. The workflows default to the values below; set a variable only to override it.

| Variable | Value |
| --- | --- |
| `AWS_ROLE_ARN` | `terraform output -raw github_deploy_role_arn` |
| `AWS_REGION` | `us-east-1` |
| `ECR_REPOSITORY` | `terraform output -raw ecr_repository` |
| `ECS_CLUSTER` | `terraform output -raw ecs_cluster` |
| `ECS_SERVICES` | `terraform output -raw scheduled_services` (default: every service except load-generator) |
| `ARM_RUNNER` | optional, defaults to `ubuntu-24.04-arm` |

## Workflows

- `aws-deploy.yml`: PRs build the changed images (arm64, no push). Pushes to `main`
  build and push them, then force a new deployment of the affected services without
  changing `desiredCount`, so a deploy outside working hours does not start anything.
  `workflow_dispatch` rebuilds and redeploys everything. The image list is
  `aws/images.json`.
- `site-control.yml`: manual `start` / `stop` override of the schedule.

## Bootstrap order

1. `terraform apply` (all services are created with `desiredCount = 0`).
2. Set the repo variables above.
3. Run `aws-deploy.yml` (or merge to `main`) to build and push all images.
4. Run `site-control.yml` with `start`, or wait for the next scheduled start.

## Operations

- Change working days: `-var 'schedule_days=MON-FRI'`. Disable the schedule: `-var schedule_enabled=false`.
- Start/stop now: `site-control.yml`, or
  `aws lambda invoke --function-name otel-demo-scaler --payload '{"action":"start"}' --cli-binary-format raw-in-base64-out /dev/stdout`.
- Shell into a task: `aws ecs execute-command --cluster otel-demo --task <id> --container <name> --interactive --command sh`.
- The flagd UI (`/feature`) and Envoy routes are public, as in upstream.

Rollback: `terraform destroy` (the ECR repository must be empty first).
