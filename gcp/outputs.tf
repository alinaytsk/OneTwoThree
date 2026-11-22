output "api_url" {
  value       = google_cloud_run_v2_service.api.uri
  description = "HTTPS URL of the Cloud Run service. This is what VITE_API_URL is built with, and what firebase.json rewrites /api/** to."
}

output "site_url" {
  value       = "https://${google_firebase_hosting_site.main.site_id}.web.app"
  description = "Firebase Hosting URL, live once `firebase deploy --only hosting` has run."
}

output "db_connection_name" {
  value       = google_sql_database_instance.main.connection_name
  description = "project:region:instance. Used by the Cloud SQL proxy and by `gcloud sql connect`."
}

output "db_socket_dir" {
  value       = local.db_socket_dir
  description = "What DB_HOST is set to inside Cloud Run: a unix socket directory, not a hostname."
}

output "registry_repository" {
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.backend.repository_id}"
  description = "Push the backend image here, then pass <this>/backend:<tag> as var.image."
}

output "api_service_account" {
  value       = google_service_account.api.email
  description = "Runtime identity of the Cloud Run service: Cloud SQL client, one secret, its own logs."
}

output "migrate_command" {
  value       = "gcloud run jobs execute ${google_cloud_run_v2_job.migrate.name} --region ${var.region} --project ${var.project_id} --wait"
  description = "Applies Alembic migrations and seeds. Run once after the first apply, and after every migration."
}

output "stop_database_command" {
  value       = "gcloud sql instances patch ${google_sql_database_instance.main.name} --activation-policy NEVER --project ${var.project_id}"
  description = <<-EOT
    The one command that matters for the bill. db-f1-micro does not pause on idle the way Aurora
    Serverless does: it bills $0.0105 an hour until it is stopped. Storage is still charged while
    stopped. Start it again with --activation-policy ALWAYS.
  EOT
}
