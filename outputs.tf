###############################################################################
# OpenClaw on GCP -- Outputs
###############################################################################

output "instance_name" {
  description = "Name of the GCE instance."
  value       = google_compute_instance.openclaw.name
}

output "instance_zone" {
  description = "Zone of the GCE instance."
  value       = google_compute_instance.openclaw.zone
}

output "instance_internal_ip" {
  description = "Internal IP of the GCE instance."
  value       = google_compute_instance.openclaw.network_interface[0].network_ip
}

output "service_account_email" {
  description = "Service account email used by the instance."
  value       = google_service_account.openclaw.email
}

output "artifact_registry_url" {
  description = "Artifact Registry URL for pushing sandbox images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.sandbox.repository_id}"
}

output "ssh_via_iap" {
  description = "Command to SSH into the instance via IAP."
  value       = "gcloud compute ssh ${google_compute_instance.openclaw.name} --zone=${google_compute_instance.openclaw.zone} --tunnel-through-iap --project=${var.project_id}"
}

output "gateway_token_secret" {
  description = "Secret Manager resource name for the gateway token."
  value       = google_secret_manager_secret.gateway_token.name
}

output "secrets_configured" {
  description = "List of Secret Manager secrets created."
  sensitive   = true
  value = concat(
    [google_secret_manager_secret.gateway_token.secret_id],
    var.llm_api_key != "" ? [google_secret_manager_secret.llm_api_key[0].secret_id] : [],
    var.telegram_bot_token != "" ? [google_secret_manager_secret.telegram_bot_token[0].secret_id] : [],
    var.brave_api_key != "" ? [google_secret_manager_secret.brave_api_key[0].secret_id] : []
  )
}

output "llm_api_key_status" {
  description = "LLM API key configuration status and next steps."
  sensitive   = true
  value = var.llm_api_key != "" ? "LLM API key stored in Secret Manager (openclaw-llm-api-key) and auto-injected as ${var.model_provider == "openai" ? "OPENAI_API_KEY" : var.model_provider == "anthropic" ? "ANTHROPIC_API_KEY" : "GEMINI_API_KEY"}" : <<-EOT
    No LLM API key provided. To add one manually:
    1. gcloud secrets create openclaw-llm-api-key --project=${var.project_id} --replication-policy=automatic --data-file=<(echo -n "YOUR_API_KEY")
    2. gcloud secrets add-iam-policy-binding openclaw-llm-api-key --project=${var.project_id} --role=roles/secretmanager.secretAccessor --member="serviceAccount:${google_service_account.openclaw.email}"
    3. SSH in and update /home/openclaw/.openclaw/secrets/fetch-secrets.sh (see README)
  EOT
}
