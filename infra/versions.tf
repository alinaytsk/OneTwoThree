terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.6"
    }
  }

  # The state lives in HCP Terraform: stored, locked for the duration of every run, and kept
  # version by version. The workspace name matches the one the bootstrap role's trust policy is
  # pinned to (organization:alinaytsk:project:Default Project:workspace:meetings-dev).
  cloud {
    organization = "alinaytsk"

    workspaces {
      name = "meetings-dev"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}
