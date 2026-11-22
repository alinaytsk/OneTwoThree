# Cloud SQL for PostgreSQL: the closest counterpart to Aurora Serverless v2, and the row where
# the two clouds genuinely differ. Aurora at 0-1 ACU pauses when nobody calls the app and costs
# nothing; db-f1-micro has no idle state. It runs, and it bills $0.0105 an hour until somebody
# stops it. See docs/adr/0008 for why we took it anyway, and docs/lab9-costs.md for the number.

resource "random_password" "db" {
  length = 32
  # Cloud SQL accepts punctuation in passwords, but the value also travels through a libpq
  # connection string, where @ : / and ? change its meaning. Letters and digits only: 32 of
  # them is ~190 bits, far more than the characters would have added.
  special = false
}

resource "google_secret_manager_secret" "db_password" {
  project   = var.project_id
  secret_id = "${var.project_name}-db-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}

resource "google_sql_database_instance" "main" {
  project          = var.project_id
  name             = "${var.project_name}-pg"
  region           = var.region
  database_version = "POSTGRES_16"

  # Student project: a destroy should actually destroy. The AWS side keeps a final snapshot of
  # Aurora; here the equivalent protection is turned off deliberately so that `terraform
  # destroy` cannot leave an instance behind, which is the single most common surprise on a
  # student's bill.
  deletion_protection = false

  settings {
    tier      = var.db_tier
    disk_size = var.db_disk_size_gb
    disk_type = "PD_SSD"

    # Off. Autoresize is what turns a runaway table into a bill nobody authorised, and 10 GB is
    # already two orders of magnitude more than this app's data.
    disk_autoresize = false

    availability_type = "ZONAL"
    edition           = "ENTERPRISE"

    ip_configuration {
      # A public IP with no authorised networks: nothing on the internet can open a connection,
      # but the Cloud Run proxy can. The alternative, a private IP, needs a VPC peering range
      # and - on this project - the Service Networking API, which is more moving parts than the
      # lab needs. Cloud Run reaches it over the Cloud SQL unix socket either way.
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
      # Seven days of point-in-time recovery would need WAL archiving, which is charged per GB.
      # Daily backups are free up to the instance's own size.
      point_in_time_recovery_enabled = false
    }

    maintenance_window {
      day          = 7 # Sunday
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled = false
    }
  }

  depends_on = [google_project_service.enabled]
}

resource "google_sql_database" "main" {
  project  = var.project_id
  name     = var.db_name
  instance = google_sql_database_instance.main.name
}

resource "google_sql_user" "app" {
  project  = var.project_id
  name     = var.db_user
  instance = google_sql_database_instance.main.name
  password = random_password.db.result
}
