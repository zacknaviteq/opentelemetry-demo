# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

locals {
  # Every image CI builds (one per container, flagd task has three).
  images = sort(keys(local.image_to_service))
}

resource "aws_ecr_repository" "this" {
  name                 = "opentelemetry-demo"
  image_tag_mutability = "MUTABLE" # latest-<image> is re-pointed on every deploy

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = concat(
      [{
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }],
      [for i, img in local.images : {
        rulePriority = i + 10
        description  = "Keep the last ${var.ecr_images_to_keep} ${img} images"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*-${img}"]
          countType      = "imageCountMoreThan"
          countNumber    = var.ecr_images_to_keep
        }
        action = { type = "expire" }
      }]
    )
  })
}
