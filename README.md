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

This module provisions:

- **VPC + Subnet** with no default network, private IP Google access
- **Cloud Firewall** deny-all ingress + SSH via IAP only (no public IP)
- **Cloud NAT** for outbound internet without a public IP
- **Service Account** with least-privilege IAM bindings
- **Secret Manager** secrets for gateway token and optional channel credentials
- **Artifact Registry** private Docker repository for sandbox images
- **GCE Instance** with Shielded VM (Secure Boot, vTPM, Integrity Monitoring)
- **Systemd service** with hardened unit configuration

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`)
- A GCP project with billing enabled
- Authenticated credentials:
  ```bash
  gcloud auth application-default login
  ```

## Quick Start

1. **Clone and configure:**

   ```bash
   cd terraform-openclaw-gcp
   cp terraform.tfvars.example terraform.tfvars
   ```

2. **Edit `terraform.tfvars`** with your values:

   ```hcl
   project_id         = "my-gcp-project"
   region             = "us-central1"
   zone               = "us-central1-c"
   network_name       = "openclaw-vpc"
   machine_type       = "e2-standard-2"
   boot_disk_size_gb  = 30
   model_provider     = "google"
   model_primary      = "google-gemini-cli/gemini-3.1-pro-preview"
   model_fallbacks    = "[\"google/gemini-3.1-pro-preview\", \"google/gemini-3.1-flash-lite-preview\"]"  #Change ask you see fit
   llm_api_key        = ""  # Leave empty if you want to use Gemini Code Assist OAuth
   ```

3. **Deploy:**

   ```bash
   terraform init
   terraform plan
   terraform apply
   ```

4. **Wait for startup to complete (~3-5 minutes):**

   The instance runs a startup script that installs Docker, Node.js, and OpenClaw. Wait for it to finish before connecting. You can monitor progress with:

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
   sudo systemctl status openclaw-gateway.service
   sudo journalctl -u openclaw-gateway.service -f
   ```

## Using the VM

When you SSH into the instance, you land as your admin user (e.g., `admin_yourname`). OpenClaw runs as a dedicated `openclaw` user with secrets pre-loaded. Depending on what you need to do, use the appropriate user:

### As admin user (default SSH login)

The admin user can manage the system but does **not** have OpenClaw secrets in the environment. Use this for:

- Checking service status: `sudo systemctl status openclaw-gateway.service`
- Viewing logs: `sudo journalctl -u openclaw-gateway.service -f`
- Viewing startup logs: `sudo cat /var/log/openclaw-startup.log`
- Restarting the service: `sudo systemctl restart openclaw-gateway.service`
- Editing config files: `sudo -u openclaw nano /home/openclaw/.openclaw/openclaw.json`
- Running one-off openclaw commands with the token:
  ```bash
  export OPENCLAW_GATEWAY_TOKEN=$(sudo cat /home/openclaw/.openclaw/secrets/gateway-token.txt)
  openclaw status
  ```

### As openclaw user (recommended for OpenClaw CLI)

Switch to the `openclaw` user to get all secrets (gateway token, LLM API keys, etc.) automatically loaded in your shell:

```bash
sudo -iu openclaw
```

Then you can use OpenClaw directly:

```bash
openclaw status          # Check gateway status
openclaw tui             # Launch the interactive TUI
openclaw logs --follow   # Stream live logs
openclaw security audit  # Run a security audit
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
| Check service status | `sudo systemctl status openclaw-gateway.service` |
| Restart the service | `sudo systemctl restart openclaw-gateway.service` |
| View live logs | `sudo journalctl -u openclaw-gateway.service -f` |
| View startup log | `sudo cat /var/log/openclaw-startup.log` |
| Launch TUI (as openclaw) | `openclaw tui` |
| Check gateway status | `openclaw status` |

## LLM Provider Configuration

OpenClaw supports multiple LLM providers. You have two options for configuring the API key:

- **Option A: Via Terraform (recommended)** — provide the API key as a variable and Terraform automatically creates the Secret Manager entry, IAM binding, and wires it into the service
- **Option B: Manual setup after deployment** — deploy first, then add the API key to Secret Manager yourself

### Option A: Provide API key via Terraform

Set `model_provider`, `model_primary`, `model_fallbacks`, and `llm_api_key` in your `terraform.tfvars`. Terraform will:
- Store the key in Secret Manager (`openclaw-llm-api-key`)
- Grant the gateway service account read access
- Automatically fetch and export it as the correct env var at startup

#### Google Gemini

```hcl
model_provider  = "google"
model_primary   = "google-gemini-cli/gemini-3.1-pro-preview"
model_fallbacks = "[\"google/gemini-3.1-pro-preview\", \"google/gemini-3.1-flash-lite-preview\"]"
llm_api_key     = "AIzaSy..."  # Your Gemini API key → exported as GEMINI_API_KEY
```

#### OpenAI

```hcl
model_provider  = "openai"
model_primary   = "openai/gpt-4o"
model_fallbacks = "[\"openai/gpt-4o-mini\"]"
llm_api_key     = "sk-..."  # Your OpenAI API key → exported as OPENAI_API_KEY
```

#### Anthropic

```hcl
model_provider  = "anthropic"
model_primary   = "anthropic/claude-sonnet-4-6"
model_fallbacks = "[\"anthropic/claude-haiku-4-5\"]"
llm_api_key     = "sk-ant-..."  # Your Anthropic API key → exported as ANTHROPIC_API_KEY
```

### Option B: Add API key manually after deployment

If you prefer not to pass secrets through Terraform (e.g., for security policy reasons), deploy without `llm_api_key` and add it manually:

#### 1. Create the secret in GCP Secret Manager

```bash
echo -n "YOUR_API_KEY" | \
  gcloud secrets create openclaw-llm-api-key \
    --project=my-gcp-project \
    --replication-policy=automatic \
    --data-file=-
```

#### 2. Grant the gateway service account access

```bash
gcloud secrets add-iam-policy-binding openclaw-llm-api-key \
  --project=my-gcp-project \
  --role=roles/secretmanager.secretAccessor \
  --member="serviceAccount:openclaw-gateway@my-gcp-project.iam.gserviceaccount.com"
```

#### 3. SSH into the VM and update fetch-secrets.sh

```bash
gcloud compute ssh openclaw-gateway \
  --zone=us-central1-c \
  --tunnel-through-iap \
  --project=my-gcp-project
```

Edit the fetch script:

```bash
sudo -u openclaw nano /home/openclaw/.openclaw/secrets/fetch-secrets.sh
```

Add the fetch and export lines. Use the correct env var for your provider:

| Provider | Env Var |
|----------|---------|
| Google Gemini | `GEMINI_API_KEY` |
| OpenAI | `OPENAI_API_KEY` |
| Anthropic | `ANTHROPIC_API_KEY` |

```bash
# Add after the gateway token fetch:
fetch_secret "openclaw-llm-api-key" "$SECRETS_DIR/llm-api-key.txt"

# Add inside the { ... } > "$ENV_FILE" block:
echo "GEMINI_API_KEY=$(cat "$SECRETS_DIR/llm-api-key.txt")"
```

#### 4. Restart the service

```bash
sudo systemctl restart openclaw-gateway.service
sudo systemctl status openclaw-gateway.service
```

### Using an existing Secret Manager entry

If you already have an API key in Secret Manager (e.g., `projects/my-project/secrets/my-existing-key`), you can skip creating a new one. Just grant access and update `fetch-secrets.sh` to reference your existing secret name:

```bash
# Grant access
gcloud secrets add-iam-policy-binding my-existing-key \
  --project=my-gcp-project \
  --role=roles/secretmanager.secretAccessor \
  --member="serviceAccount:openclaw-gateway@my-gcp-project.iam.gserviceaccount.com"

# Then in fetch-secrets.sh, use your secret name:
fetch_secret "my-existing-key" "$SECRETS_DIR/llm-api-key.txt"
```

### How it works

The API key is stored securely in GCP Secret Manager and never written to disk in plaintext config files. At service startup:
1. `fetch-secrets.sh` pulls the latest secret version from Secret Manager
2. The key is written to a permission-restricted file (`chmod 600`)
3. It's exported as the appropriate environment variable in the service's env file
4. The OpenClaw gateway process reads the env var at runtime

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

### Adding Other Channels

The same pattern applies for any channel:

1. **Create the secret** in Secret Manager:

   ```bash
   echo -n "YOUR_SECRET_VALUE" | \
     gcloud secrets create openclaw-<channel>-token \
       --project=my-gcp-project \
       --replication-policy=automatic \
       --data-file=-
   ```

2. **Grant access** to the gateway service account:

   ```bash
   gcloud secrets add-iam-policy-binding openclaw-<channel>-token \
     --project=my-gcp-project \
     --role=roles/secretmanager.secretAccessor \
     --member="serviceAccount:openclaw-gateway@my-gcp-project.iam.gserviceaccount.com"
   ```

3. **Add the fetch** to `fetch-secrets.sh`:

   ```bash
   fetch_secret "openclaw-<channel>-token" "$SECRETS_DIR/<channel>-token.txt"
   ```

4. **Configure the channel** in `openclaw.json` under `"channels"`

5. **Restart** the service:

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

# Disable the old version (optional)
gcloud secrets versions disable OLD_VERSION_NUMBER \
  --secret=openclaw-telegram-bot-token \
  --project=my-gcp-project
```

## Adding Custom Secrets

You can add any additional secret (API keys, tokens, credentials) to the OpenClaw VM using GCP Secret Manager. Secrets are fetched at service startup and exposed as environment variables.

### Step-by-step guide

#### 1. Create the secret in GCP Secret Manager

From your local machine or Cloud Shell:

```bash
echo -n "YOUR_SECRET_VALUE" | \
  gcloud secrets create my-custom-secret \
    --project=my-gcp-project \
    --replication-policy=automatic \
    --data-file=-
```

#### 2. Grant the gateway service account access

```bash
gcloud secrets add-iam-policy-binding my-custom-secret \
  --project=my-gcp-project \
  --role=roles/secretmanager.secretAccessor \
  --member="serviceAccount:openclaw-gateway@my-gcp-project.iam.gserviceaccount.com"
```

#### 3. SSH into the OpenClaw VM

```bash
gcloud compute ssh openclaw-gateway \
  --zone=us-central1-c \
  --tunnel-through-iap \
  --project=my-gcp-project
```

#### 4. Add the secret fetch to `fetch-secrets.sh`

Edit the fetch script:

```bash
sudo -u openclaw nano /home/openclaw/.openclaw/secrets/fetch-secrets.sh
```

Add a `fetch_secret` line and an `echo` line to export it as an env var. For example, to add a secret called `my-custom-secret` as the env var `MY_CUSTOM_SECRET`:

```bash
# Add this line after the existing fetch_secret calls:
fetch_secret "my-custom-secret" "$SECRETS_DIR/my-custom-secret.txt"

# Add this line inside the { ... } > "$ENV_FILE" block:
echo "MY_CUSTOM_SECRET=$(cat "$SECRETS_DIR/my-custom-secret.txt")"
```

The complete `fetch-secrets.sh` should look like:

```bash
#!/usr/bin/env bash
set -euo pipefail

SECRETS_DIR="/home/openclaw/.openclaw/secrets"
PROJECT="my-gcp-project"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

fetch_secret() {
  local secret_name="$1"
  local dest_file="$2"
  gcloud secrets versions access latest \
    --secret="$secret_name" \
    --project="$PROJECT" \
    > "$dest_file" 2>/dev/null
  chmod 600 "$dest_file"
  echo "[fetch-secrets] Wrote $dest_file"
}

fetch_secret "openclaw-gateway-token" "$SECRETS_DIR/gateway-token.txt"
fetch_secret "my-custom-secret"       "$SECRETS_DIR/my-custom-secret.txt"

ENV_FILE="$SECRETS_DIR/openclaw-env"
{
  echo "OPENCLAW_GATEWAY_TOKEN=$(cat "$SECRETS_DIR/gateway-token.txt")"
  echo "MY_CUSTOM_SECRET=$(cat "$SECRETS_DIR/my-custom-secret.txt")"
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "[fetch-secrets] Wrote $ENV_FILE"
echo "[fetch-secrets] All secrets fetched successfully."
```

#### 5. (Optional) Make the secret available in interactive sessions

To use the secret when SSH'd into the VM, add it to the openclaw user's `.bashrc`:

```bash
sudo -u openclaw bash -c 'cat >> ~/.bashrc <<'\''EOF'\''

# Load custom secret
if [ -f "$HOME/.openclaw/secrets/my-custom-secret.txt" ]; then
  export MY_CUSTOM_SECRET=$(cat "$HOME/.openclaw/secrets/my-custom-secret.txt")
fi
EOF'
```

#### 6. Restart the service

```bash
sudo systemctl restart openclaw-gateway.service
```

#### 7. Verify

Check that the service started successfully and the secret is loaded:

```bash
sudo systemctl status openclaw-gateway.service
```

To verify the env var is set in the service:

```bash
sudo cat /home/openclaw/.openclaw/secrets/openclaw-env
```

### Common examples

| Secret | GCP Secret Name | Env Var |
|--------|----------------|---------|
| OpenAI API key | `openclaw-openai-api-key` | `OPENAI_API_KEY` |
| Anthropic API key | `openclaw-anthropic-api-key` | `ANTHROPIC_API_KEY` |
| Gemini API key | `openclaw-gemini-api-key` | `GEMINI_API_KEY` |
| Brave Search key | `openclaw-brave-api-key` | `BRAVE_API_KEY` |
| Telegram bot token | `openclaw-telegram-bot-token` | `TELEGRAM_BOT_TOKEN` |
| GitHub PAT | `openclaw-github-pat` | `GITHUB_TOKEN` |
| Custom webhook URL | `openclaw-webhook-url` | `WEBHOOK_URL` |

## Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `project_id` | Yes | -- | GCP project ID |
| `telegram_bot_token` | No | `""` | Telegram bot token (stored in Secret Manager) |
| `gateway_auth_token` | No | auto-generated | Gateway auth token (48-char hex if empty) |
| `brave_api_key` | No | `""` | Brave Search API key |
| `region` | No | `us-central1` | GCP region |
| `zone` | No | `us-central1-c` | GCE instance zone |
| `network_name` | No | `openclaw-vpc` | Name of the VPC network |
| `machine_type` | No | `e2-standard-2` | GCE machine type |
| `boot_disk_size_gb` | No | `30` | Boot disk size in GB |
| `model_provider` | No | `google` | LLM provider: `google`, `openai`, or `anthropic` |
| `model_primary` | No | `google-gemini-cli/gemini-3.1-pro-preview` | Primary model for OpenClaw agents |
| `model_fallbacks` | No | `["google/gemini-3.1-pro-preview", ...]` | Fallback model identifiers (JSON array) |
| `llm_api_key` | No | `""` | LLM provider API key (stored in Secret Manager) |
| `openclaw_version` | No | `latest` | OpenClaw npm package version |
| `deployer_service_account` | No | `""` | SA email granted IAP + OS Login access |

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

## Security

- **No public IP** -- instance is only accessible via IAP tunnel
- **SSH via IAP only** -- firewall allows SSH from Google's IAP range (`35.235.240.0/20`)
- **OS Login enforced** -- no project-wide SSH keys
- **Shielded VM** -- Secure Boot, vTPM, Integrity Monitoring
- **Secrets in Secret Manager** -- never stored in plaintext in Terraform state or on disk
- **Dedicated service account** -- least-privilege IAM (logging, monitoring, Artifact Registry read, Secret Manager access)
- **Systemd hardening** -- `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`
- **Docker hardening** -- `no-new-privileges`, log rotation, ulimits, sandbox network `none`

## Cleanup

```bash
terraform destroy
```
