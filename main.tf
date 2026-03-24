###############################################################################
# OpenClaw on GCP -- Main Infrastructure
# Click-to-deploy with secure-by-default settings.
#
# Resources created:
#   - VPC + Subnet (no default network)
#   - Cloud Firewall rules (deny-all ingress + SSH via IAP only)
#   - Cloud NAT (outbound internet without public IP, optional)
#   - Service Account with least-privilege IAM
#   - Secret Manager secrets for all sensitive values
#   - Artifact Registry repository for sandbox images
#   - GCE instance with startup script
#   - Cloud Logging sink for OpenClaw logs
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ──────────────────────────────────────────────────────────────────────────────
# Enable Required APIs
# ──────────────────────────────────────────────────────────────────────────────

resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ──────────────────────────────────────────────────────────────────────────────
# Random token generation (if gateway_auth_token not provided)
# ──────────────────────────────────────────────────────────────────────────────

resource "random_id" "gateway_token" {
  byte_length = 24
}

locals {
  gateway_auth_token = var.gateway_auth_token != "" ? var.gateway_auth_token : random_id.gateway_token.hex

  sandbox_image = var.sandbox_image != "" ? var.sandbox_image : "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.sandbox.repository_id}/openclaw-sandbox:latest"
}

# ──────────────────────────────────────────────────────────────────────────────
# Networking -- VPC, Subnet, Cloud NAT
# ──────────────────────────────────────────────────────────────────────────────

resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  project                 = var.project_id

  depends_on = [google_project_service.apis["compute.googleapis.com"]]
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.network_name}-subnet"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Cloud Router + NAT for outbound internet access without a public IP
resource "google_compute_router" "router" {
  name    = "${var.network_name}-router"
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.network_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Firewall Rules -- Secure by default (deny-all ingress)
# ──────────────────────────────────────────────────────────────────────────────

# Deny all ingress by default
resource "google_compute_firewall" "deny_all_ingress" {
  name    = "${var.network_name}-deny-all-ingress"
  network = google_compute_network.vpc.id

  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Allow SSH via IAP only (35.235.240.0/20 is Google's IAP range)
# This is the ONLY ingress SSH rule -- no direct SSH from the internet.
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.network_name}-allow-iap-ssh"
  network = google_compute_network.vpc.id

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # 35.235.240.0/20 is Google's IAP forwarding range.
  # Only IAP-authenticated sessions can reach port 22.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["openclaw"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Allow internal communication within subnet
resource "google_compute_firewall" "allow_internal" {
  name    = "${var.network_name}-allow-internal"
  network = google_compute_network.vpc.id

  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
  target_tags   = ["openclaw"]
}

# ──────────────────────────────────────────────────────────────────────────────
# Service Account -- Least Privilege
# ──────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "openclaw" {
  account_id   = "openclaw-gateway"
  display_name = "OpenClaw Gateway Service Account"
  project      = var.project_id

  depends_on = [google_project_service.apis["iam.googleapis.com"]]
}

# Only grant Secret Manager accessor (no editor, no owner)
resource "google_project_iam_member" "logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.openclaw.email}"
}

resource "google_project_iam_member" "monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.openclaw.email}"
}

# IAP tunnel access for the deployer service account (testing/admin)
resource "google_project_iam_member" "iap_tunnel_accessor" {
  count   = var.deployer_service_account != "" ? 1 : 0
  project = var.project_id
  role    = "roles/iap.tunnelResourceAccessor"
  member  = "serviceAccount:${var.deployer_service_account}"
}

# OS Login access for the deployer service account (required when enable-oslogin=TRUE)
resource "google_project_iam_member" "os_login" {
  count   = var.deployer_service_account != "" ? 1 : 0
  project = var.project_id
  role    = "roles/compute.osAdminLogin"
  member  = "serviceAccount:${var.deployer_service_account}"
}

# Artifact Registry reader (pull sandbox images)
resource "google_artifact_registry_repository_iam_member" "reader" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.sandbox.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.openclaw.email}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Secret Manager -- Store all secrets externally
# ──────────────────────────────────────────────────────────────────────────────

resource "google_secret_manager_secret" "telegram_bot_token" {
  count = var.telegram_bot_token != "" ? 1 : 0

  secret_id = "openclaw-telegram-bot-token"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "telegram_bot_token" {
  count = var.telegram_bot_token != "" ? 1 : 0

  secret      = google_secret_manager_secret.telegram_bot_token[0].id
  secret_data = var.telegram_bot_token
}

resource "google_secret_manager_secret" "gateway_token" {
  secret_id = "openclaw-gateway-token"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "gateway_token" {
  secret      = google_secret_manager_secret.gateway_token.id
  secret_data = local.gateway_auth_token
}

resource "google_secret_manager_secret" "llm_api_key" {
  count = var.llm_api_key != "" ? 1 : 0

  secret_id = "openclaw-llm-api-key"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "llm_api_key" {
  count = var.llm_api_key != "" ? 1 : 0

  secret      = google_secret_manager_secret.llm_api_key[0].id
  secret_data = var.llm_api_key
}

resource "google_secret_manager_secret" "brave_api_key" {
  count = var.brave_api_key != "" ? 1 : 0

  secret_id = "openclaw-brave-api-key"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = var.labels

  depends_on = [google_project_service.apis["secretmanager.googleapis.com"]]
}

resource "google_secret_manager_secret_version" "brave_api_key" {
  count = var.brave_api_key != "" ? 1 : 0

  secret      = google_secret_manager_secret.brave_api_key[0].id
  secret_data = var.brave_api_key
}

# Per-secret IAM bindings (least privilege -- only this SA can access these secrets)
resource "google_secret_manager_secret_iam_member" "telegram_accessor" {
  count = var.telegram_bot_token != "" ? 1 : 0

  secret_id = google_secret_manager_secret.telegram_bot_token[0].secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw.email}"
}

resource "google_secret_manager_secret_iam_member" "gateway_accessor" {
  secret_id = google_secret_manager_secret.gateway_token.secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw.email}"
}

resource "google_secret_manager_secret_iam_member" "llm_api_key_accessor" {
  count = var.llm_api_key != "" ? 1 : 0

  secret_id = google_secret_manager_secret.llm_api_key[0].secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw.email}"
}

resource "google_secret_manager_secret_iam_member" "brave_accessor" {
  count = var.brave_api_key != "" ? 1 : 0

  secret_id = google_secret_manager_secret.brave_api_key[0].secret_id
  project   = var.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openclaw.email}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Artifact Registry -- Private sandbox image repository
# ──────────────────────────────────────────────────────────────────────────────

resource "google_artifact_registry_repository" "sandbox" {
  location      = var.region
  repository_id = "openclaw-sandbox"
  description   = "Private Docker images for OpenClaw sandbox containers"
  format        = "DOCKER"
  project       = var.project_id

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"

    most_recent_versions {
      keep_count = 5
    }
  }

  labels = var.labels

  depends_on = [google_project_service.apis["artifactregistry.googleapis.com"]]
}

# ──────────────────────────────────────────────────────────────────────────────
# Compute Engine Instance
# ──────────────────────────────────────────────────────────────────────────────

resource "google_compute_instance" "openclaw" {
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone
  project      = var.project_id

  tags = ["openclaw"]

  labels = var.labels

  boot_disk {
    initialize_params {
      image = var.os_image
      size  = var.boot_disk_size_gb
      type  = var.boot_disk_type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    # No access_config block = no external IP (secure by default)
    # Outbound traffic goes through Cloud NAT
  }

  service_account {
    email  = google_service_account.openclaw.email
    # cloud-platform is the minimum scope required for Secret Manager access.
    # IAM roles (not scopes) enforce least-privilege.
    scopes = ["cloud-platform"]
  }

  # Shielded VM (Secure Boot + vTPM + Integrity Monitoring)
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
    serial-port-enable     = "FALSE"
  }

  metadata_startup_script = templatefile("${path.module}/scripts/startup.sh", {
    project_id          = var.project_id
    region              = var.region
    openclaw_version    = var.openclaw_version
    sandbox_image       = local.sandbox_image
    model_provider      = var.model_provider
    model_primary       = var.model_primary
    model_fallbacks     = var.model_fallbacks
    has_llm_api_key     = var.llm_api_key != ""
    has_brave_api_key   = var.brave_api_key != ""
    has_telegram        = var.telegram_bot_token != ""
  })

  allow_stopping_for_update = true

  depends_on = [
    google_project_service.apis["compute.googleapis.com"],
    google_secret_manager_secret_version.gateway_token,
    google_compute_router_nat.nat,
  ]
}
