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

  # Part 1, Step 6 puts the state in HCP Terraform. Filled in once the organization exists:
  #
  # cloud {
  #   organization = "<organization>"
  #   workspaces { name = "meetings-dev" }
  # }
  #
  # Until then the state is local, which is why terraform.tfstate* is in .gitignore.
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
