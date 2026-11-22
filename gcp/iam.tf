# One service account per program, as Part 0 asks.
#
# The Terraform identity is *not* created here. It is the account the lab creates by hand in
# Part 0, and a configuration that could mint its own deployer would be a configuration that
# could grant itself anything. On a laptop Terraform runs as the developer's own gcloud
# application-default credentials; in CI it would come through Workload Identity Federation,
# with no key downloaded anywhere.
#
# This is the identity the *application* runs as, which is a different thing and deliberately
# much smaller: it may open the database and read one secret. It cannot deploy, cannot read
# other secrets, and cannot see the registry.

resource "google_service_account" "api" {
  project      = var.project_id
  account_id   = "${var.project_name}-api"
  display_name = "Meetings API on Cloud Run"
  description  = "Runtime identity of the Cloud Run service. Not a deployer."

  depends_on = [google_project_service.enabled]
}

# Connect to Cloud SQL through the built-in proxy. Note this is granted on the project rather
# than on the instance: Cloud SQL has no per-instance IAM for the client role.
resource "google_project_iam_member" "api_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.api.email}"
}

# Read the database password, and only that secret.
resource "google_secret_manager_secret_iam_member" "api_db_password" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

# Write its own logs. Without this the service runs but is silent, which is a miserable way to
# debug a first deployment.
resource "google_project_iam_member" "api_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.api.email}"
}
