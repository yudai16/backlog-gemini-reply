variable "project_id" {
  type        = string
  description = "The GCP project ID."
}

variable "region" {
  type        = string
  description = "The GCP region to deploy resources."
  default     = "asia-northeast1"
}

variable "service_name" {
  type        = string
  description = "A unique name for the service."
  default     = "backlog-gemini-reply"
}

variable "backlog_api_key" {
  type        = string
  description = "The API key for Backlog."
  sensitive   = true
}

variable "basic_auth_username" {
  type        = string
  description = "The username for Basic Authentication."
  sensitive   = true
}

variable "basic_auth_password" {
  type        = string
  description = "The password for Basic Authentication."
  sensitive   = true
}

variable "backlog_space_url" {
  type        = string
  description = "The base URL of your Backlog space (e.g., https://your-space.backlog.jp)."
}

variable "gemini_model_name" {
  type        = string
  description = "The name of the Gemini model to use."
  default     = "gemini-2.5-flash-lite"
}

variable "prompt_gcs_bucket_name" {
  type        = string
  description = "The name of the GCS bucket to store prompt files. Must be globally unique."
}

variable "system_prompt_gcs_file_path" {
  type        = string
  description = "The path to the system prompt file within the GCS bucket."
  default     = "prompts/system_prompt.txt"
}

variable "gemini_region" {
  type        = string
  description = "The GCP region for Vertex AI Gemini models. Defaults to the main region if not specified."
  default     = "us-central1"
}
