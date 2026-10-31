variable "region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type = string
}

variable "env" {
  type        = string
  description = "Which environment this is: dev, stage or prod"

  validation {
    condition     = contains(["dev", "stage", "prod"], var.env)
    error_message = "env must be dev, stage or prod."
  }
}

locals {
  name = "${var.project_name}-${var.env}"

  # What differs between environments, in one table
  settings = {
    dev   = { versioning = false, keep_days = 7, force_destroy = true }
    stage = { versioning = true, keep_days = 30, force_destroy = true }
    prod  = { versioning = true, keep_days = 365, force_destroy = false }
  }
  s = local.settings[var.env]
}

# Bucket names are global across all AWS accounts, so add a random suffix.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "playground" {
  bucket        = "${local.name}-tf-playground-${random_id.suffix.hex}"
  force_destroy = local.s.force_destroy
  tags          = { Environment = var.env }
}

resource "aws_s3_bucket_versioning" "playground" {
  bucket = aws_s3_bucket.playground.id

  versioning_configuration {
    status = local.s.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "playground" {
  bucket = aws_s3_bucket.playground.id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration { days = local.s.keep_days }
  }
}

# A resource that exists only in some environments: count = 0 or 1
resource "aws_sns_topic" "alarms" {
  count = var.env == "prod" ? 1 : 0
  name  = "${local.name}-alarms"
}

output "bucket_name" {
  value = aws_s3_bucket.playground.bucket
}
