terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # Firebase Hosting has no GA resources: the site and its releases are beta-only.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # State. The AWS configuration in infra/ keeps its state in HCP Terraform (workspace
  # meetings-dev); this one is deliberately a *separate* state so that one plan can never
  # touch both clouds. The lab asks for a second HCP workspace:
  #
  #   cloud {
  #     organization = "alinaytsk"
  #     workspaces { name = "meetings-gcp" }
  #   }
  #
  # It is commented out, not deleted, because a cloud block makes `terraform init` require an
  # HCP token, and this configuration has to be init- and validate-able with no credentials at
  # all (there is no billing account on the Google project, so it is never applied). Swap the
  # local backend below for that block after `terraform login`.
  backend "local" {}
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = var.project_name
    managed_by = "terraform"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project    = var.project_name
    managed_by = "terraform"
  }
}
