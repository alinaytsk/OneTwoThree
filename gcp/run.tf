# The API on Cloud Run.
#
# The difference from Lambda that matters is not the scaling model - both scale to zero - but
# the interface. Lambda speaks its own event JSON, so the FastAPI app needed Mangum to translate
# it; Cloud Run speaks HTTP to whatever port it puts in $PORT. So the adapter comes out and
# uvicorn is the whole entry point. back/Dockerfile.cloudrun is that image, and it is the same
# image that runs on a laptop with `docker run -e PORT=8080`.

locals {
  # The Cloud SQL unix socket the built-in proxy mounts. libpq reads a host that starts with a
  # slash as a socket directory, so app/config.py needs no change at all: DB_HOST carries this
  # path instead of a hostname.
  db_socket_dir = "/cloudsql/${google_sql_database_instance.main.connection_name}"

  db_env = {
    DB_HOST = local.db_socket_dir
    DB_PORT = "5432"
    DB_NAME = var.db_name
    DB_USER = var.db_user
  }

  app_env = {
    CORS_ORIGINS         = join(",", var.cors_origins)
    COGNITO_REGION       = var.cognito_region
    COGNITO_USER_POOL_ID = var.cognito_user_pool_id
    COGNITO_CLIENT_ID    = var.cognito_client_id
    # Cloud Run gives a container one request at a time per concurrency slot but keeps it warm;
    # a pooled connection in a warm instance is fine here, unlike on Lambda against a pausing
    # Aurora, where an idle pooled connection stopped the database from ever pausing.
    DB_NULL_POOL = "false"
  }
}

resource "google_cloud_run_v2_service" "api" {
  project  = var.project_id
  name     = "${var.project_name}-api"
  location = var.region

  deletion_protection = false

  # The service is public at the network level; the application checks Cognito ID tokens itself
  # (and, with an empty pool id, runs with auth disabled as the local demo does).
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.api.email

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instances
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance {
        instances = [google_sql_database_instance.main.connection_name]
      }
    }

    containers {
      image = var.image

      # Cloud Run sets $PORT and expects the container to listen on it. 8080 is its default and
      # what the Dockerfile falls back to, so the same image runs unchanged on a laptop.
      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Request-based billing: CPU is allocated only while a request is in flight, which is
        # what makes an idle month cost nothing.
        cpu_idle = true
      }

      dynamic "env" {
        for_each = merge(local.db_env, local.app_env)
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "DB_PASSWORD"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.db_password.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      startup_probe {
        http_get {
          path = "/api/health"
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        failure_threshold     = 6
      }
    }
  }

  depends_on = [
    google_project_service.enabled,
    google_secret_manager_secret_version.db_password,
  ]
}

# Open to the internet. This is the one grant worth reading twice: allUsers as run.invoker means
# anyone may reach the URL, and the only thing standing between the internet and the data is the
# application's own token check.
resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.project_id
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Migrations as a job rather than part of the service's start-up.
#
# Putting `alembic upgrade head` in the container's CMD (which is what compose.yaml does) means
# every cold start runs it, and two instances starting at once run it concurrently against the
# same database. Cloud Run makes the better pattern easy: a job, executed on demand.
#
#   gcloud run jobs execute meetings-migrate --region us-central1 --wait
resource "google_cloud_run_v2_job" "migrate" {
  project  = var.project_id
  name     = "${var.project_name}-migrate"
  location = var.region

  deletion_protection = false

  template {
    template {
      service_account = google_service_account.api.email
      max_retries     = 1

      volumes {
        name = "cloudsql"
        cloud_sql_instance {
          instances = [google_sql_database_instance.main.connection_name]
        }
      }

      containers {
        image   = var.image
        command = ["sh", "-c", "alembic upgrade head && python -m app.seed"]

        dynamic "env" {
          for_each = merge(local.db_env, { SEED = "true" })
          content {
            name  = env.key
            value = env.value
          }
        }

        env {
          name = "DB_PASSWORD"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.db_password.secret_id
              version = "latest"
            }
          }
        }

        volume_mounts {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
    }
  }

  depends_on = [
    google_project_service.enabled,
    google_sql_database.main,
  ]
}
