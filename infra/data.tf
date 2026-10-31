# What this module reads but does not own.
#
# Not in the layout the lab sketches, which lists versions / variables / auth / reports / ai /
# outputs: the data sources are collected here rather than repeated at the top of reports.tf
# and ai.tf, because both need the account ID and the bucket name is built from it.

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

data "aws_partition" "current" {}

# The VPC, the database and the API Lambda stay in CloudFormation (infra/backend.yaml). The
# report builder runs inside that VPC and talks to that database, so it reads the values from
# the stack's outputs instead of having them pasted in as variables - the same outputs the
# Makefile reads.
data "aws_cloudformation_stack" "backend" {
  name = var.backend_stack_name
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  backend = data.aws_cloudformation_stack.backend.outputs

  # Named so the resources below read like the template they came from.
  reports_bucket_name = "${var.project_name}-reports-${local.account_id}"
  reports_bucket_arn  = "arn:${local.partition}:s3:::${var.project_name}-reports-${local.account_id}"
}

# The database password. CloudFormation resolved it at deploy time with
# {{resolve:secretsmanager:...}}, which never put the value in the template or the stack.
# Terraform has no such thing: reading it here puts the password in the state file, which is
# one more reason the state belongs in HCP Terraform and not on a laptop or in Git.
data "aws_secretsmanager_secret_version" "db" {
  secret_id = local.backend["DbSecretArn"]
}
