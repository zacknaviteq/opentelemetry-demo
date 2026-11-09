terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  backend "s3" {
    bucket       = "calc-tfstate-960410382237"
    key          = "opentelemetry-demo/infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = {
      Project   = "otel-demo"
      ManagedBy = "terraform"
      Repo      = "zacknaviteq/opentelemetry-demo"
    }
  }
}

data "aws_partition" "current" {}
