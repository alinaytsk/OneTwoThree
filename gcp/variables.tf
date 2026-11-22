variable "project_id" {
  type        = string
  description = <<-EOT
    The Google Cloud project. Permanent and globally unique, 6-30 characters. This is the
    project created by hand in Part 0 (onetwotree-511013); Terraform does not create it,
    because creating a project needs a billing account and an organisation or folder.
  EOT
}

variable "project_name" {
  type        = string
  default     = "meetings"
  description = "Name prefix for every resource, and the value of their `project` label. Mirrors the same variable in infra/."
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = <<-EOT
    Everything lives here. us-central1 is the cheapest region for Cloud Run and Cloud SQL and
    the one the lab's price list is quoted in; europe-central2 (Warsaw) would be closer to the
    users but costs about 10% more per Cloud SQL hour.
  EOT
}

variable "db_tier" {
  type        = string
  default     = "db-f1-micro"
  description = "Smallest shared-core Cloud SQL tier: 0.6 GB RAM, $0.0105/hour while running. db-g1-small (1.7 GB) is $0.035."
}

variable "db_disk_size_gb" {
  type        = number
  default     = 10
  description = "SSD size in GB. Billed whether the instance runs or is stopped, at $0.17/GB a month."

  validation {
    condition     = var.db_disk_size_gb >= 10
    error_message = "Cloud SQL for PostgreSQL will not take less than 10 GB."
  }
}

variable "db_name" {
  type        = string
  default     = "meetings"
  description = "Database inside the instance. Matches POSTGRES_DB in compose.yaml so the same migrations apply."
}

variable "db_user" {
  type        = string
  default     = "meetings"
  description = "Application role. Cloud SQL also creates a `postgres` superuser, which the app never uses."
}

variable "image" {
  type        = string
  description = <<-EOT
    The backend image Cloud Run runs, including tag, in Artifact Registry. Built from
    back/Dockerfile.cloudrun - the Compose and Lambda images are not interchangeable: this one
    listens on $PORT and carries no Mangum adapter.

    Until the image is pushed, the placeholder in terraform.tfvars.example lets `plan` run.
  EOT
}

variable "cors_origins" {
  type        = list(string)
  description = "Browser origins the API answers. The Firebase Hosting URL belongs here once the site exists."
  default = [
    "http://localhost:3000",
    "http://localhost:5173",
  ]
}

variable "cognito_region" {
  type        = string
  default     = "us-east-1"
  description = <<-EOT
    Sign-in stays on AWS Cognito for now (Part 2 moves the frontend, API and database only;
    Identity Platform is a stretch goal). The Cloud Run service verifies the same ID tokens the
    Lambda did, so it needs the pool's region, id and client id.
  EOT
}

variable "cognito_user_pool_id" {
  type        = string
  default     = ""
  description = "Empty disables auth entirely: every request acts as one local user. That is what the no-billing demo runs with."
}

variable "cognito_client_id" {
  type        = string
  default     = ""
  description = "App client the accepted ID tokens are issued for."
}

variable "max_instances" {
  type        = number
  default     = 2
  description = <<-EOT
    Cloud Run scales to zero at the bottom; this caps the top. Two is deliberate: db-f1-micro
    allows about 25 connections, and the API opens one per request, so an unbounded fan-out
    would exhaust the database long before it exhausted the free tier.
  EOT
}
