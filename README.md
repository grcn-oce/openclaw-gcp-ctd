# OpenClaw on GCP -- Terraform Deployment

Secure-by-default Terraform configuration for deploying OpenClaw Gateway on Google Cloud Platform.

## Security Hardening (vs. Default OpenClaw)

This deployment applies security controls that go beyond a standard OpenClaw install. The table below highlights what's different:

| Area | Default OpenClaw | This Deployment |
|------|-----------------|-----------------|
| **Network exposure** | Public IP, open ports | No public IP, all traffic via Cloud NAT |
| **SSH access** | Direct SSH from internet | SSH via IAP tunnel only (Google-authenticated) |
| **Firewall** | OS default (allow all) | GCP VPC deny-all ingress + allowlist rules |
| **Secrets storage** | Plaintext in config files or env | GCP Secret Manager with per-secret IAM |
| **LLM authentication** | API keys in config | VM service account ADC via LiteLLM proxy (no API keys needed) |
| **Service account** | Default Compute SA (broad permissions) | Dedicated SA with least-privilege roles |
| **VM integrity** | Standard boot | Shielded VM: Secure Boot, vTPM, Integrity Monitoring |
| **OS hardening** | Default SSH config | Root login disabled, password auth off, OS Login enforced, project SSH keys blocked |
| **Process isolation** | Runs as current user | Dedicated `openclaw` user, systemd hardened unit |
| **Docker hardening** | Default daemon config | `no-new-privileges`, log rotation, ulimits, PID limits |
| **Sandbox containers** | Default network access | Network `none`, read-only workspace, memory/CPU limits |
| **Container registry** | Docker Hub (public) | Private Artifact Registry with cleanup policies |
| **Logging** | Local only | Sensitive value redaction, structured file logging |
| **Auto-updates** | Manual | Unattended security upgrades enabled |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  GCE Instance (Shielded VM, no public IP)               │
│                                                         │
│  ┌───────────────────┐    ┌──────────────────────────┐  │
│  │  OpenClaw Gateway  │───▶│  LiteLLM Proxy (:4000)   │  │
│  │  (Node.js :18789)  │    │  OpenAI-compatible API   │  │
│  └───────────────────┘    └──────────┬───────────────┘  │
│                                      │ ADC (SA token)   │
│  ┌───────────────────┐               ▼                  │
│  │  Docker Sandbox    │    ┌──────────────────────────┐  │
│  │  (network: none)   │    │  Vertex AI API (global)  │  │
│  └───────────────────┘    │  Gemini 3.1 models       │  │
│                            └──────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

This module provisions:

- **VPC + Subnet** with no default network, private IP Google access
- **Cloud Firewall** deny-all ingress + SSH via IAP only (no public IP)
- **Cloud NAT** for outbound internet without a public IP
- **Service Account** with least-privilege IAM bindings (`aiplatform.user` for Vertex AI)
- **Secret Manager** secrets for gateway token and optional channel credentials
- **Artifact Registry** private Docker repository for sandbox images
- **GCE Instance** with Shielded VM (Secure Boot, vTPM, Integrity Monitoring)
- **LiteLLM Proxy** local OpenAI-compatible gateway that authenticates to Vertex AI via the VM's service account (ADC)
- **Systemd services** for both LiteLLM proxy and OpenClaw gateway

### How LLM Authentication Works

Unlike typical setups that require API keys, this deployment uses the GCE VM's service account for LLM authentication:

1. The VM runs with a dedicated service account that has `roles/aiplatform.user`
2. **LiteLLM proxy** runs on `localhost:4000` and authenticates to Vertex AI using Application Default Credentials (ADC) from the VM's metadata server
3. **OpenClaw** connects to LiteLLM as an `openai-completions` provider — no API keys leave the VM
4. LiteLLM translates OpenAI-format requests into Vertex AI API calls with OAuth2 tokens

This means **no LLM API keys are needed** in your Terraform config, Secret Manager, or environment variables.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- A GCP project with billing enabled and the Vertex AI API enabled
- Authenticated credentials:
  ```bash
  gcloud auth application-default login
  ```

## Quick Start

1. **Clone and configure:**

   ```bash
   cd openclaw-gcp-ctd
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Edit `terraform.tfvars`** with your values:

   ```hcl
   project_id         = "my-gcp-project"
   region             = "us-central1"
   zone               = "us-central1-c"
   instance_name      = "openclaw-gateway"
   machine_type       = "e2-standard-2"
   boot_disk_size_gb  = 30

   # Default: LiteLLM proxy → Vertex AI (Gemini 3.1) via service account ADC
   model_provider     = "litellm"
   model_primary      = "litellm/gemini-3.1-pro-preview"
   model_fallbacks    = "[\"litellm/gemini-3.1-pro-preview\", \"litellm/gemini-3.1-flash-lite-preview\"]"
   ```

   > **No `llm_api_key` needed** — the VM's service account authenticates to Vertex AI automatically.

3. **Deploy:**

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Wait for startup to complete (~5-7 minutes):**

   The startup script installs Docker, Node.js, OpenClaw, Python, and LiteLLM. Monitor progress with:

   ```bash
   gcloud compute ssh openclaw-gateway \
     --zone=us-central1-c \
     --tunnel-through-iap \
     --project=my-gcp-project \
     --command="sudo tail -f /var/log/openclaw-startup.log"
   ```

   Wait until you see `=== OpenClaw GCP Startup Complete ===`.

5. **Connect to the instance:**

   ```bash
   gcloud compute ssh openclaw-gateway \
     --zone=us-central1-c \
     --tunnel-through-iap \
     --project=my-gcp-project
   ```

6. **Check service status:**

   ```bash
   sudo systemctl status litellm.service
   sudo systemctl status openclaw-gateway.service
   ```

## Using the VM

When you SSH into the instance, you land as your admin user (e.g., `admin_yourname`). OpenClaw runs as a dedicated `openclaw` user with secrets pre-loaded. Depending on what you need to do, use the appropriate user:

### As admin user (default SSH login)

The admin user can manage the system but does **not** have OpenClaw secrets in the environment. Use this for:

- Checking service status: `sudo systemctl status openclaw-gateway.service`
- Checking LiteLLM status: `sudo systemctl status litellm.service`
- Viewing logs: `sudo journalctl -u openclaw-gateway.service -f`
- Viewing LiteLLM logs: `sudo journalctl -u litellm.service -f`
- Viewing startup logs: `sudo cat /var/log/openclaw-startup.log`
- Restarting services: `sudo systemctl restart litellm.service openclaw-gateway.service`
- Editing config files: `sudo -u openclaw nano /home/openclaw/.openclaw/openclaw.json`
- Running one-off openclaw commands with the token:
  ```bash
  export OPENCLAW_GATEWAY_TOKEN=$(sudo cat /home/openclaw/.openclaw/secrets/gateway-token.txt)
  openclaw status
  ```

### As openclaw user (recommended for OpenClaw CLI)

Switch to the `openclaw` user to get all secrets automatically loaded in your shell:

```bash
sudo -iu openclaw
```

Then you can use OpenClaw directly:

```bash
openclaw status          # Check gateway status
openclaw tui             # Launch the interactive TUI
openclaw logs --follow   # Stream live logs
openclaw doctor --fix    # Auto-fix config issues
```

To exit back to your admin user:

```bash
exit
```

### Quick reference

| Task | Command |
|------|---------|
| SSH into the VM | `gcloud compute ssh openclaw-gateway --zone=us-central1-c --tunnel-through-iap --project=my-gcp-project` |
| Switch to openclaw user | `sudo -iu openclaw` |
| Check OpenClaw service | `sudo systemctl status openclaw-gateway.service` |
| Check LiteLLM proxy | `sudo systemctl status litellm.service` |
| Restart both services | `sudo systemctl restart litellm.service openclaw-gateway.service` |
| View OpenClaw logs | `sudo journalctl -u openclaw-gateway.service -f` |
| View LiteLLM logs | `sudo journalctl -u litellm.service -f` |
| View startup log | `sudo cat /var/log/openclaw-startup.log` |
| Launch TUI (as openclaw) | `openclaw tui` |
| Test LiteLLM health | `curl http://127.0.0.1:4000/health` |

## LLM Provider Configuration

### Default: LiteLLM + Vertex AI (recommended)

The default configuration uses a **LiteLLM proxy** running on the VM to route requests to **Vertex AI**. Authentication uses the VM's service account via ADC — no API keys required.

```hcl
model_provider  = "litellm"
model_primary   = "litellm/gemini-3.1-pro-preview"
model_fallbacks = "[\"litellm/gemini-3.1-pro-preview\", \"litellm/gemini-3.1-flash-lite-preview\"]"
```

**How it works:**

1. OpenClaw sends requests to `http://127.0.0.1:4000/v1` (LiteLLM) using the `openai-completions` API format
2. LiteLLM maps model names (e.g., `gemini-3.1-pro-preview`) to Vertex AI endpoints (`vertex_ai/gemini-3.1-pro-preview`)
3. LiteLLM authenticates to Vertex AI using the VM's service account token (ADC via metadata server)
4. No API keys are stored, rotated, or managed

**LiteLLM config** is at `/etc/litellm/config.yaml`. To add more models:

```bash
sudo nano /etc/litellm/config.yaml
```

```yaml
model_list:
  - model_name: gemini-3.1-pro-preview
    litellm_params:
      model: vertex_ai/gemini-3.1-pro-preview
      vertex_project: "my-gcp-project"
      vertex_location: "global"
  - model_name: gemini-2.5-flash
    litellm_params:
      model: vertex_ai/gemini-2.5-flash
      vertex_project: "my-gcp-project"
      vertex_location: "global"
```

Then restart: `sudo systemctl restart litellm.service openclaw-gateway.service`

### Alternative: Direct API key providers

You can still use direct API key providers (OpenAI, Anthropic, Google AI Studio) by setting `model_provider` and `llm_api_key`:

#### OpenAI

```hcl
model_provider  = "openai"
model_primary   = "openai/gpt-4o"
model_fallbacks = "[\"openai/gpt-4o-mini\"]"
llm_api_key     = "sk-..."  # Stored in Secret Manager, exported as OPENAI_API_KEY
```

#### Anthropic

```hcl
model_provider  = "anthropic"
model_primary   = "anthropic/claude-sonnet-4-6"
model_fallbacks = "[\"anthropic/claude-haiku-4-5\"]"
llm_api_key     = "sk-ant-..."  # Stored in Secret Manager, exported as ANTHROPIC_API_KEY
```

#### Google AI Studio (Gemini API key)

```hcl
model_provider  = "google"
model_primary   = "google/gemini-3.1-pro-preview"
model_fallbacks = "[\"google/gemini-3.1-flash-lite-preview\"]"
llm_api_key     = "AIza..."  # Stored in Secret Manager, exported as GEMINI_API_KEY
```

When `llm_api_key` is set, Terraform stores it in Secret Manager with proper IAM bindings and injects it as an environment variable at startup.

## Channel Integration

OpenClaw supports messaging channels (Telegram, WhatsApp, etc.) to interact with agents. Channels are optional -- without them, the gateway runs in TUI/API-only mode.

### Telegram Setup

#### 1. Create a Telegram Bot

1. Open Telegram and message [@BotFather](https://t.me/BotFather)
2. Send `/newbot` and follow the prompts to choose a name and username
3. BotFather will give you a token like: `123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxx`
4. Save this token securely -- do not commit it to version control

#### 2. Store the Token in Secret Manager

**Option A: Via Terraform (recommended)**

Set the token in your `terraform.tfvars`:

```hcl
telegram_bot_token = "123456789:AAExxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

Terraform will automatically create the `openclaw-telegram-bot-token` secret in Secret Manager with proper IAM bindings.

**Option B: Via gcloud CLI (after deployment)**

If you prefer to manage the secret separately:

```bash
# Create the secret
echo -n "YOUR_TELEGRAM_BOT_TOKEN" | \
  gcloud secrets create openclaw-telegram-bot-token \
    --project=my-gcp-project \
    --replication-policy=automatic \
    --data-file=-

# Grant the gateway service account access
gcloud secrets add-iam-policy-binding openclaw-telegram-bot-token \
  --project=my-gcp-project \
  --role=roles/secretmanager.secretAccessor \
  --member="serviceAccount:openclaw-gateway@my-gcp-project.iam.gserviceaccount.com"
```

#### 3. Configure the Channel in openclaw.json

SSH into the instance and update the OpenClaw configuration:

```bash
gcloud compute ssh openclaw-gateway \
  --zone=us-central1-c \
  --tunnel-through-iap \
  --project=my-gcp-project
```

Edit the config to add the Telegram channel:

```bash
sudo -u openclaw nano /home/openclaw/.openclaw/openclaw.json
```

Update the `"channels"` section:

```json
"channels": {
  "telegram": {
    "enabled": true,
    "tokenFile": "/home/openclaw/.openclaw/secrets/telegram-bot-token.txt",
    "dmPolicy": "pairing",
    "groupPolicy": "allowlist",
    "streaming": "partial"
  }
}
```

Then update the `fetch-secrets.sh` script to also fetch the Telegram token:

```bash
sudo -u openclaw nano /home/openclaw/.openclaw/secrets/fetch-secrets.sh
```

Add this line after the gateway token fetch:

```bash
fetch_secret "openclaw-telegram-bot-token" "$SECRETS_DIR/telegram-bot-token.txt"
```

Restart the service:

```bash
sudo systemctl restart openclaw-gateway.service
```

### Rotating Secrets

To rotate a secret without downtime:

```bash
# Add a new version
echo -n "NEW_TOKEN_VALUE" | \
  gcloud secrets versions add openclaw-telegram-bot-token \
    --project=my-gcp-project \
    --data-file=-

# Restart the service to pick up the new version
gcloud compute ssh openclaw-gateway \
  --zone=us-central1-c \
  --tunnel-through-iap \
  --project=my-gcp-project \
  --command="sudo systemctl restart openclaw-gateway.service"
```

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `project_id` | Yes | -- | GCP project ID |
| `region` | No | `us-central1` | GCP region |
| `zone` | No | `us-central1-c` | GCE instance zone |
| `network_name` | No | `openclaw-vpc` | Name of the VPC network |
| `subnet_cidr` | No | `10.10.0.0/24` | CIDR range for the subnet |
| `instance_name` | No | `openclaw-gateway` | Name of the GCE instance |
| `machine_type` | No | `e2-standard-2` | GCE machine type |
| `boot_disk_size_gb` | No | `30` | Boot disk size in GB |
| `boot_disk_type` | No | `pd-balanced` | Boot disk type (`pd-standard`, `pd-balanced`, `pd-ssd`) |
| `os_image` | No | `debian-cloud/debian-12` | Boot disk image |
| `telegram_bot_token` | No | `""` | Telegram bot token (stored in Secret Manager) |
| `gateway_auth_token` | No | auto-generated | Gateway auth token (48-char hex if empty) |
| `brave_api_key` | No | `""` | Brave Search API key |
| `openclaw_version` | No | `latest` | OpenClaw npm package version |
| `sandbox_image` | No | `""` | Docker image for sandbox containers |
| `model_provider` | No | `litellm` | LLM provider: `litellm` (Vertex AI via proxy), `google`, `openai`, or `anthropic` |
| `model_primary` | No | `litellm/gemini-3.1-pro-preview` | Primary model for OpenClaw agents |
| `model_fallbacks` | No | `["litellm/gemini-3.1-pro-preview", ...]` | Fallback model identifiers (JSON array) |
| `llm_api_key` | No | `""` | LLM provider API key (not needed for `litellm` provider) |
| `deployer_service_account` | No | `""` | SA email granted IAP + OS Login access |
| `labels` | No | `{app="openclaw", ...}` | Labels to apply to all resources |

## Outputs

| Output | Description |
|--------|-------------|
| `instance_name` | GCE instance name |
| `instance_zone` | GCE instance zone |
| `instance_internal_ip` | Internal IP address |
| `service_account_email` | Gateway service account |
| `artifact_registry_url` | Docker registry for sandbox images |
| `ssh_via_iap` | SSH command to connect |
| `gateway_token_secret` | Secret Manager resource for gateway token |
| `secrets_configured` | List of secrets created |
| `llm_api_key_status` | LLM API key configuration status and next steps |

## Security

- **No public IP** -- instance is only accessible via IAP tunnel
- **SSH via IAP only** -- firewall allows SSH from Google's IAP range (`35.235.240.0/20`)
- **OS Login enforced** -- no project-wide SSH keys
- **Shielded VM** -- Secure Boot, vTPM, Integrity Monitoring
- **No LLM API keys** -- Vertex AI auth via service account ADC through LiteLLM proxy
- **Secrets in Secret Manager** -- gateway token and optional keys never stored in plaintext
- **LiteLLM bound to localhost** -- proxy only listens on `127.0.0.1:4000`, not exposed externally
- **Dedicated service account** -- least-privilege IAM (Vertex AI user, logging, monitoring, Artifact Registry read, Secret Manager access)
- **Systemd hardening** -- `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`
- **Docker hardening** -- `no-new-privileges`, log rotation, ulimits, sandbox network `none`

## Troubleshooting

### LiteLLM proxy not starting

```bash
sudo journalctl -u litellm.service --no-pager -n 50
sudo cat /etc/litellm/config.yaml
```

### Model not found (404)

Verify the model name is valid on Vertex AI. Preview models require the `-preview` suffix and use the `global` location:

```bash
# Check current LiteLLM config
sudo cat /etc/litellm/config.yaml

# Verify vertex_location is "global" for Gemini 3.x preview models
```

### OpenClaw can't connect to LiteLLM

```bash
# Check LiteLLM is running
curl http://127.0.0.1:4000/health

# Check OpenClaw config points to LiteLLM
sudo -u openclaw cat /home/openclaw/.openclaw/openclaw.json | grep -A3 baseUrl
```

### Service account permissions

The VM's service account needs `roles/aiplatform.user`. Verify:

```bash
gcloud projects get-iam-policy my-gcp-project \
  --flatten="bindings[].members" \
  --filter="bindings.members:openclaw-gateway@my-gcp-project.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

## Cleanup

```bash
terraform destroy
```
