# APIs are off by default on a new Google Cloud project - the counterpart of nothing in AWS,
# where every service is simply there. Enabling them from Terraform is what makes a fresh
# project reproducible: `terraform apply` on an empty project brings up the whole stack.
#
# `disable_on_destroy = false` on purpose. Destroying this configuration should remove the
# resources, not switch the project's APIs back off: another configuration (or a console
# session) may be relying on them, and re-enabling takes minutes.

locals {
  services = [
    "serviceusage.googleapis.com", # must come first: it is the API that enables APIs
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "firebase.googleapis.com",
    "firebasehosting.googleapis.com",
    "logging.googleapis.com",
  ]
}

resource "google_project_service" "enabled" {
  for_each = toset(local.services)

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}
