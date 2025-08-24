terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.50.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 4.50.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

locals {
  # Suffix for service accounts and other resources to ensure uniqueness
  resource_suffix = substr(md5(var.project_id), 0, 6)
}

# ------------------------------------------------------------------------------
# APIs to enable
# ------------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "aiplatform.googleapis.com",
    "apigateway.googleapis.com",
    "servicemanagement.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com" # Added for GCS
  ])
  service = each.key
}

# ------------------------------------------------------------------------------
# GCS Bucket for Prompts
# ------------------------------------------------------------------------------
resource "google_storage_bucket" "prompt_bucket" {
  name                        = var.prompt_gcs_bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket_object" "prompt_file" {
  name   = var.system_prompt_gcs_file_path
  bucket = google_storage_bucket.prompt_bucket.name
  source = "${path.module}/system_prompt.txt"
  depends_on = [google_storage_bucket.prompt_bucket]
}

# ------------------------------------------------------------------------------
# Secret Manager for sensitive data
# ------------------------------------------------------------------------------
resource "google_secret_manager_secret" "backlog_api_key" {
  secret_id = "${var.service_name}-backlog-api-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "backlog_api_key" {
  secret      = google_secret_manager_secret.backlog_api_key.id
  secret_data = var.backlog_api_key
}

resource "google_secret_manager_secret" "basic_auth_username" {
  secret_id = "${var.service_name}-basic-auth-username"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "basic_auth_username" {
  secret      = google_secret_manager_secret.basic_auth_username.id
  secret_data = var.basic_auth_username
}

resource "google_secret_manager_secret" "basic_auth_password" {
  secret_id = "${var.service_name}-basic-auth-password"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "basic_auth_password" {
  secret      = google_secret_manager_secret.basic_auth_password.id
  secret_data = var.basic_auth_password
}

# ------------------------------------------------------------------------------
# Service Account for Cloud Function
# ------------------------------------------------------------------------------
resource "google_service_account" "function_sa" {
  account_id   = "${var.service_name}-sa-${local.resource_suffix}"
  display_name = "Service Account for ${var.service_name}"
  depends_on   = [google_project_service.apis]
}

# Grant SA access to secrets
resource "google_secret_manager_secret_iam_member" "secret_accessor" {
  for_each = toset([
    google_secret_manager_secret.backlog_api_key.secret_id,
    google_secret_manager_secret.basic_auth_username.secret_id,
    google_secret_manager_secret.basic_auth_password.secret_id
  ])
  project   = var.project_id
  secret_id = each.key
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
}

# Grant SA access to Vertex AI
resource "google_project_iam_member" "ai_user" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_project_iam_member" "artifact_registry_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

# Grant SA access to GCS prompt bucket
resource "google_storage_bucket_iam_member" "prompt_reader" {
  bucket = google_storage_bucket.prompt_bucket.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.function_sa.email}"
}

# ------------------------------------------------------------------------------
# Cloud Function (Gen 1)
# ------------------------------------------------------------------------------

data "archive_file" "source" {
  type        = "zip"
  source_dir  = "../app"
  output_path = "/tmp/${var.service_name}_source.zip"
}

resource "google_storage_bucket" "source_bucket" {
  name                        = "${var.service_name}-source-bucket-${local.resource_suffix}"
  location                    = var.region
  uniform_bucket_level_access = true
  depends_on                  = [google_project_service.apis]
}

resource "google_storage_bucket_object" "source_archive" {
  name   = "${var.service_name}_source.zip"
  bucket = google_storage_bucket.source_bucket.name
  source = data.archive_file.source.output_path
}

resource "google_cloudfunctions_function" "default" {
  name                  = var.service_name
  runtime               = "python312"
  entry_point           = "webhook"
  available_memory_mb   = 512
  source_archive_bucket = google_storage_bucket.source_bucket.name
  source_archive_object = google_storage_bucket_object.source_archive.name
  trigger_http          = true
  timeout               = 60
  region                = var.region
  service_account_email = google_service_account.function_sa.email
  ingress_settings      = "ALLOW_ALL"

  environment_variables = {
    GCP_PROJECT_ID              = var.project_id
    GCP_REGION                  = var.region
    GEMINI_REGION               = coalesce(var.gemini_region, var.region)
    BACKLOG_SPACE_URL           = var.backlog_space_url
    GEMINI_MODEL_NAME           = var.gemini_model_name
    PROMPT_GCS_BUCKET_NAME      = var.prompt_gcs_bucket_name
    SYSTEM_PROMPT_GCS_FILE_PATH = var.system_prompt_gcs_file_path
  }

  secret_environment_variables {
    key        = "BACKLOG_API_KEY"
    project_id = var.project_id
    secret     = google_secret_manager_secret.backlog_api_key.secret_id
    version    = "latest"
  }
  secret_environment_variables {
    key        = "BASIC_AUTH_USERNAME"
    project_id = var.project_id
    secret     = google_secret_manager_secret.basic_auth_username.secret_id
    version    = "latest"
  }
  secret_environment_variables {
    key        = "BASIC_AUTH_PASSWORD"
    project_id = var.project_id
    secret     = google_secret_manager_secret.basic_auth_password.secret_id
    version    = "latest"
  }

  depends_on = [
    google_project_service.apis,
    google_storage_bucket_iam_member.prompt_reader
  ]
}

# ------------------------------------------------------------------------------
# API Gateway
# ------------------------------------------------------------------------------
resource "google_api_gateway_api" "default" {
  provider = google-beta
  api_id = var.service_name
  depends_on = [google_project_service.apis]
}

data "template_file" "openapi_spec" {
  template = file("${path.module}/openapi_spec.yaml")
  vars = {
    function_url = google_cloudfunctions_function.default.https_trigger_url
  }
}

resource "google_api_gateway_api_config" "default" {
  provider = google-beta
  api           = google_api_gateway_api.default.api_id
  api_config_id = "${var.service_name}-config"

  openapi_documents {
    document {
      path     = "openapi_spec.yaml"
      contents = base64encode(data.template_file.openapi_spec.rendered)
    }
  }
  gateway_config {
    backend_config {
      google_service_account = google_service_account.function_sa.email
    }
  }
  depends_on = [google_cloudfunctions_function.default]
}

resource "google_api_gateway_gateway" "default" {
  provider = google-beta
  api_config = google_api_gateway_api_config.default.id
  gateway_id = var.service_name
  region     = var.region
}

# Allow API Gateway to invoke the Cloud Function
resource "google_cloudfunctions_function_iam_member" "invoker" {
  project        = google_cloudfunctions_function.default.project
  region         = google_cloudfunctions_function.default.region
  cloud_function = google_cloudfunctions_function.default.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:${google_service_account.function_sa.email}"
}