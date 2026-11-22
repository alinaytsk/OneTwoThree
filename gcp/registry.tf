# Artifact Registry, the counterpart of ECR. 0.5 GB a month is free, and the backend image is
# around 250 MB, so one tag fits and two do not - hence the cleanup policy below.

resource "google_artifact_registry_repository" "backend" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.project_name}-backend"
  description   = "Backend container images for Cloud Run"
  format        = "DOCKER"

  # Keep the three most recent images and delete the rest. The free tier is 0.5 GB; without
  # this, every pushed tag stays for ever and the registry quietly becomes the only line on the
  # bill that grows while nobody uses the app.
  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = 3
    }
  }

  depends_on = [google_project_service.enabled]
}
