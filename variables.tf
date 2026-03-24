###############################################################################
# OpenClaw on GCP -- Terraform Variables
# Secure-by-default values for all configurable parameters.
###############################################################################

# ──────────────────────────────────────────────────────────────────────────────
# Project & Region
# ──────────────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID where all resources will be created."
  type        = string
}

variable "region" {
  description = "GCP region for regional resources (Artifact Registry, Secret Manager)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the Compute Engine instance."
  type        = string
  default     = "us-central1-c"
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking
# ──────────────────────────────────────────────────────────────────────────────

variable "network_name" {
  description = "Name of the VPC network."
  type        = string
  default     = "openclaw-vpc"
}

variable "subnet_cidr" {
  description = "CIDR range for the subnet."
  type        = string
  default     = "10.10.0.0/24"
}

# SSH access is IAP-only by design. No variable to weaken this.
# Use: gcloud compute ssh INSTANCE --tunnel-through-iap

# ──────────────────────────────────────────────────────────────────────────────
# Compute
# ──────────────────────────────────────────────────────────────────────────────

variable "instance_name" {
  description = "Name of the GCE instance."
  type        = string
  default     = "openclaw-gateway"
}

variable "machine_type" {
  description = "GCE machine type."
  type        = string
  default     = "e2-standard-2"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 30
}

variable "boot_disk_type" {
  description = "Boot disk type (pd-standard, pd-balanced, pd-ssd)."
  type        = string
  default     = "pd-balanced"
}

variable "os_image" {
  description = "Boot disk image."
  type        = string
  default     = "debian-cloud/debian-12"
}

# ──────────────────────────────────────────────────────────────────────────────
# Secrets
# ──────────────────────────────────────────────────────────────────────────────

variable "telegram_bot_token" {
  description = "Telegram bot token (stored in Secret Manager, never in plaintext config). Leave empty to skip Telegram integration."
  type        = string
  sensitive   = true
  default     = ""
}

variable "gateway_auth_token" {
  description = "OpenClaw gateway auth token. Leave empty to auto-generate a 48-char hex token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "brave_api_key" {
  description = "Brave Search API key (optional). Leave empty to disable."
  type        = string
  sensitive   = true
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# OpenClaw Configuration
# ──────────────────────────────────────────────────────────────────────────────

variable "openclaw_version" {
  description = "OpenClaw npm package version to install."
  type        = string
  default     = "latest"
}

variable "sandbox_image" {
  description = "Docker image for sandbox containers. Uses Artifact Registry by default."
  type        = string
  default     = ""
  # Empty = use the image built and pushed to the project's Artifact Registry.
}

variable "model_provider" {
  description = "LLM provider: google, openai, or anthropic. Determines which API key env var is set."
  type        = string
  default     = "google"

  validation {
    condition     = contains(["google", "openai", "anthropic"], var.model_provider)
    error_message = "model_provider must be one of: google, openai, anthropic."
  }
}

variable "model_primary" {
  description = "Primary model identifier for OpenClaw agents."
  type        = string
  default     = "google-gemini-cli/gemini-3.1-pro-preview"
}

variable "model_fallbacks" {
  description = "Fallback model identifiers (JSON array)."
  type        = string
  default     = "[\"google/gemini-3.1-pro-preview\", \"google/gemini-3.1-flash-lite-preview\"]"
}

variable "llm_api_key" {
  description = "API key for the LLM provider (stored in Secret Manager). Leave empty if using Google Vertex AI with service account auth."
  type        = string
  sensitive   = true
  default     = ""
}

variable "deployer_service_account" {
  description = "Service account email for the deployer (granted IAP tunnel access). Leave empty to skip."
  type        = string
  default     = ""
}

# ──────────────────────────────────────────────────────────────────────────────
# Labels
# ──────────────────────────────────────────────────────────────────────────────

variable "labels" {
  description = "Labels to apply to all resources."
  type        = map(string)
  default = {
    app         = "openclaw"
    managed-by  = "terraform"
    environment = "production"
  }
}
