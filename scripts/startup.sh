#!/usr/bin/env bash
###############################################################################
# OpenClaw GCE Startup Script
# Secure-by-default installation and configuration.
#
# This script:
#   1. Creates a dedicated 'openclaw' OS user
#   2. Installs Docker with hardened daemon config
#   3. Installs Node.js and OpenClaw
#   4. Configures host firewall (iptables)
#   5. Blocks GCP metadata from Docker containers
#   6. Fetches secrets from GCP Secret Manager
#   7. Deploys secure openclaw.json
#   8. Creates and enables systemd service
###############################################################################

set -euo pipefail
exec > >(tee /var/log/openclaw-startup.log) 2>&1

echo "=== OpenClaw GCP Startup Script ==="
echo "Started at: $(date -u)"

PROJECT_ID="${project_id}"
REGION="${region}"
OPENCLAW_VERSION="${openclaw_version}"
SANDBOX_IMAGE="${sandbox_image}"
MODEL_PROVIDER="${model_provider}"
MODEL_PRIMARY="${model_primary}"
MODEL_FALLBACKS='${model_fallbacks}'
HAS_LLM_API_KEY="${has_llm_api_key}"
HAS_BRAVE_API_KEY="${has_brave_api_key}"
HAS_TELEGRAM="${has_telegram}"

OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/$OPENCLAW_USER"

# ──────────────────────────────────────────────────────────────────────────────
# 1. System Hardening
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Hardening SSH..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/' /etc/ssh/sshd_config
systemctl reload sshd || true

# Firewall is handled by GCP VPC firewall rules (deny-all ingress + IAP SSH only).
# No host-level iptables needed.

echo ">>> Updating package lists..."
# Retry apt-get update -- Cloud NAT may need a moment to be ready
for i in 1 2 3 4 5; do
  apt-get update -qq && break
  echo ">>> apt-get update attempt $i failed, retrying in 10s..."
  sleep 10
done

echo ">>> Enabling unattended upgrades..."
apt-get install -y -qq unattended-upgrades > /dev/null 2>&1
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APTEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APTEOF

# ──────────────────────────────────────────────────────────────────────────────
# 2. Create Dedicated OS User
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Creating dedicated openclaw user..."
if ! id "$OPENCLAW_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$OPENCLAW_USER"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Install Docker with Hardened Configuration
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Installing Docker..."
if ! command -v docker &>/dev/null; then
  apt-get install -y -qq ca-certificates curl gnupg > /dev/null 2>&1
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io > /dev/null 2>&1
fi

echo ">>> Hardening Docker daemon..."
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DOCKEREOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true,
  "no-new-privileges": true,
  "default-ulimits": {
    "nofile": { "Name": "nofile", "Hard": 65536, "Soft": 32768 },
    "nproc": { "Name": "nproc", "Hard": 4096, "Soft": 2048 }
  }
}
DOCKEREOF
systemctl restart docker

# Add openclaw user to docker group (required for sandbox)
usermod -aG docker "$OPENCLAW_USER"

# ──────────────────────────────────────────────────────────────────────────────
# 4. Install Node.js and OpenClaw
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Installing Node.js..."
if ! command -v node &>/dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq nodejs > /dev/null 2>&1
fi

echo ">>> Installing OpenClaw $${OPENCLAW_VERSION}..."
npm install -g "openclaw@$${OPENCLAW_VERSION}" --ignore-scripts 2>/dev/null || \
  npm install -g openclaw --ignore-scripts

echo ">>> Pulling sandbox Docker image ($SANDBOX_IMAGE)..."
docker pull "$SANDBOX_IMAGE"

# ──────────────────────────────────────────────────────────────────────────────
# 4b. Install LiteLLM Proxy (Vertex AI → OpenAI-compatible gateway)
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Installing Python3 and LiteLLM proxy..."
apt-get install -y -qq python3 python3-pip python3-venv > /dev/null 2>&1

LITELLM_VENV="/opt/litellm"
python3 -m venv "$LITELLM_VENV"
"$LITELLM_VENV/bin/pip" install --quiet 'litellm[proxy]==1.82.6' google-cloud-aiplatform

echo ">>> Creating LiteLLM config..."
mkdir -p /etc/litellm
cat > /etc/litellm/config.yaml <<LITELLMEOF
model_list:
  - model_name: gemini-3.1-pro-preview
    litellm_params:
      model: vertex_ai/gemini-3.1-pro-preview
      vertex_project: "$PROJECT_ID"
      vertex_location: "global"
  - model_name: gemini-3.1-flash-lite-preview
    litellm_params:
      model: vertex_ai/gemini-3.1-flash-lite-preview
      vertex_project: "$PROJECT_ID"
      vertex_location: "global"

general_settings:
  master_key: "sk-litellm-local-only"
LITELLMEOF

echo ">>> Creating LiteLLM systemd service..."
cat > /etc/systemd/system/litellm.service <<LITESVCEOF
[Unit]
Description=LiteLLM Proxy (Vertex AI Gateway)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$LITELLM_VENV/bin/litellm --config /etc/litellm/config.yaml --host 127.0.0.1 --port 4000
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=true
ReadWritePaths=/tmp

[Install]
WantedBy=multi-user.target
LITESVCEOF

systemctl daemon-reload
systemctl enable litellm.service
systemctl start litellm.service

echo ">>> Waiting for LiteLLM proxy to be ready..."
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s http://127.0.0.1:4000/health > /dev/null 2>&1; then
    echo ">>> LiteLLM proxy is ready."
    break
  fi
  echo ">>> LiteLLM not ready yet (attempt $i), waiting 5s..."
  sleep 5
done

# ──────────────────────────────────────────────────────────────────────────────
# 5. Configure Secrets (GCP Secret Manager)
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Setting up secrets directory..."
SECRETS_DIR="$OPENCLAW_HOME/.openclaw/secrets"
mkdir -p "$SECRETS_DIR"

echo ">>> Writing fetch-secrets.sh..."
cat > "$SECRETS_DIR/fetch-secrets.sh" <<FETCHEOF
#!/usr/bin/env bash
set -euo pipefail

SECRETS_DIR="$OPENCLAW_HOME/.openclaw/secrets"
PROJECT="$PROJECT_ID"

mkdir -p "\$SECRETS_DIR"
chmod 700 "\$SECRETS_DIR"

fetch_secret() {
  local secret_name="\$1"
  local dest_file="\$2"
  gcloud secrets versions access latest \\
    --secret="\$secret_name" \\
    --project="\$PROJECT" \\
    > "\$dest_file" 2>/dev/null
  chmod 600 "\$dest_file"
  echo "[fetch-secrets] Wrote \$dest_file"
}

fetch_secret "openclaw-gateway-token"      "\$SECRETS_DIR/gateway-token.txt"

ENV_FILE="\$SECRETS_DIR/openclaw-env"
{
  echo "OPENCLAW_GATEWAY_TOKEN=\$(cat "\$SECRETS_DIR/gateway-token.txt")"
FETCHEOF

if [ "$MODEL_PROVIDER" = "litellm" ]; then
  # LiteLLM proxy handles Vertex AI auth via ADC -- no LLM API key needed.
  # Pass the LiteLLM master key so OpenClaw can authenticate to the local proxy.
cat >> "$SECRETS_DIR/fetch-secrets.sh" <<'FETCHEOF_LITELLM'
  echo "OPENAI_API_KEY=sk-litellm-local-only"
FETCHEOF_LITELLM
elif [ "$HAS_LLM_API_KEY" = "true" ]; then
  # Map provider to the correct env var name
  case "$MODEL_PROVIDER" in
    openai)    LLM_ENV_VAR="OPENAI_API_KEY" ;;
    anthropic) LLM_ENV_VAR="ANTHROPIC_API_KEY" ;;
    google)    LLM_ENV_VAR="GEMINI_API_KEY" ;;
    *)         LLM_ENV_VAR="LLM_API_KEY" ;;
  esac
cat >> "$SECRETS_DIR/fetch-secrets.sh" <<FETCHEOF_LLM
  fetch_secret "openclaw-llm-api-key" "\$SECRETS_DIR/llm-api-key.txt"
  echo "$LLM_ENV_VAR=\$(cat "\$SECRETS_DIR/llm-api-key.txt")"
FETCHEOF_LLM
fi

if [ "$HAS_BRAVE_API_KEY" = "true" ]; then
cat >> "$SECRETS_DIR/fetch-secrets.sh" <<'FETCHEOF2'
  fetch_secret "openclaw-brave-api-key" "$SECRETS_DIR/brave-api-key.txt"
  echo "BRAVE_API_KEY=$(cat "$SECRETS_DIR/brave-api-key.txt")"
FETCHEOF2
fi

cat >> "$SECRETS_DIR/fetch-secrets.sh" <<'FETCHEOF3'
} > "$ENV_FILE"
chmod 600 "$ENV_FILE"
echo "[fetch-secrets] Wrote $ENV_FILE"
echo "[fetch-secrets] All secrets fetched successfully."
FETCHEOF3

chmod 700 "$SECRETS_DIR/fetch-secrets.sh"

# ──────────────────────────────────────────────────────────────────────────────
# 6. Deploy Secure openclaw.json
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Deploying secure openclaw.json..."
mkdir -p "$OPENCLAW_HOME/.openclaw"

cat > "$OPENCLAW_HOME/.openclaw/openclaw.json" <<CONFIGEOF
{
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token"
    },
    "tailscale": {
      "mode": "off",
      "resetOnExit": true
    },
    "controlUi": {
      "allowInsecureAuth": false,
      "dangerouslyDisableDeviceAuth": false
    }
  },
  "models": {
    "providers": {
      "litellm": {
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:4000/v1",
        "models": [
          { "id": "gemini-3.1-pro-preview", "name": "Gemini 3.1 Pro Preview" },
          { "id": "gemini-3.1-flash-lite-preview", "name": "Gemini 3.1 Flash Lite Preview" }
        ]
      }
    }
  },
  "channels": {},
  "session": {
    "dmScope": "per-channel-peer"
  },
  "messages": {
    "ackReactionScope": "group-mentions"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "$MODEL_PRIMARY",
        "fallbacks": $MODEL_FALLBACKS
      },
      "workspace": "$OPENCLAW_HOME/.openclaw/workspace",
      "compaction": { "mode": "safeguard" },
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 },
      "sandbox": {
        "mode": "all",
        "workspaceAccess": "ro",
        "docker": {
          "image": "$SANDBOX_IMAGE",
          "network": "none",
          "tmpfs": ["/tmp:exec,mode=1777"],
          "memory": "512m",
          "cpus": 1.0,
          "pidsLimit": 256
        },
        "browser": { "allowHostControl": false }
      }
    }
  },
  "tools": {
    "deny": ["browser"],
    "exec": {
      "security": "allowlist",
      "ask": "on-miss",
      "safeBins": ["jq", "grep", "cut", "sort", "uniq", "head", "tail", "tr", "wc"]
    },
    "elevated": { "enabled": false },
    "web": {
      "search": { "enabled": true },
      "fetch": { "enabled": true }
    }
  },
  "logging": {
    "redactSensitive": "tools",
    "file": "/var/log/openclaw/openclaw.log",
    "level": "info",
    "redactPatterns": [
      "sk-[a-zA-Z0-9]{32,}",
      "ghp_[a-zA-Z0-9]{36}",
      "xoxb-[0-9]+-[a-zA-Z0-9]+",
      "ya29\\\\.[a-zA-Z0-9_-]+",
      "AKIA[0-9A-Z]{16}",
      "ASIA[0-9A-Z]{16}",
      "[0-9]+:AA[a-zA-Z0-9_-]{33,}"
    ]
  },
  "plugins": {
    "enabled": true,
    "allow": []
  },
  "discovery": {
    "mdns": { "mode": "off" }
  },
  "browser": {
    "enabled": false,
    "evaluateEnabled": false
  },
  "hooks": {
    "enabled": false,
    "maxBodyBytes": 262144
  },
  "commands": {
    "useAccessGroups": true,
    "bash": false,
    "debug": false
  }
}
CONFIGEOF

# ──────────────────────────────────────────────────────────────────────────────
# 7. Set File Permissions (defense-in-depth)
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Setting file permissions..."
mkdir -p "$OPENCLAW_HOME/.openclaw/workspace"
mkdir -p "$OPENCLAW_HOME/.openclaw/agents/main/agent"

# Pre-populate auth-profiles.json for the configured model provider
if [ "$MODEL_PROVIDER" = "litellm" ]; then
  echo ">>> Configuring LiteLLM auth profile..."
  cat > "$OPENCLAW_HOME/.openclaw/agents/main/agent/auth-profiles.json" <<'AUTHEOF'
{
  "version": 1,
  "profiles": {
    "litellm:default": {
      "type": "api_key",
      "provider": "litellm",
      "key": "sk-litellm-local-only"
    }
  }
}
AUTHEOF
fi
mkdir -p "$OPENCLAW_HOME/.openclaw/credentials"
mkdir -p "$OPENCLAW_HOME/.openclaw/identity"
mkdir -p "$OPENCLAW_HOME/.openclaw/memory"
mkdir -p "$OPENCLAW_HOME/.openclaw/logs"
mkdir -p /var/log/openclaw

chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/.openclaw"
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" /var/log/openclaw

chmod 700 "$OPENCLAW_HOME/.openclaw"
find "$OPENCLAW_HOME/.openclaw" -type d -exec chmod 700 {} \;
find "$OPENCLAW_HOME/.openclaw" -name "*.json" -exec chmod 600 {} \;
chmod 700 "$SECRETS_DIR/fetch-secrets.sh"

# Add secret exports to openclaw user's bashrc for interactive sessions
cat >> "$OPENCLAW_HOME/.bashrc" <<'BASHRCEOF'

# Load OpenClaw gateway token from secrets
if [ -f "$HOME/.openclaw/secrets/gateway-token.txt" ]; then
  export OPENCLAW_GATEWAY_TOKEN=$(cat "$HOME/.openclaw/secrets/gateway-token.txt")
fi

# Load LLM API key from secrets (if fetched)
if [ -f "$HOME/.openclaw/secrets/llm-api-key.txt" ]; then
  export LLM_API_KEY=$(cat "$HOME/.openclaw/secrets/llm-api-key.txt")
fi

# Load env file with all secrets
if [ -f "$HOME/.openclaw/secrets/openclaw-env" ]; then
  set -a
  source "$HOME/.openclaw/secrets/openclaw-env"
  set +a
fi
BASHRCEOF
chown "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/.bashrc"

# ──────────────────────────────────────────────────────────────────────────────
# 8. Create Systemd Service
# ──────────────────────────────────────────────────────────────────────────────

echo ">>> Creating systemd service..."
OPENCLAW_BIN=$(command -v openclaw || echo "/usr/bin/openclaw")
NODE_BIN=$(command -v node || echo "/usr/bin/node")

cat > /etc/systemd/system/openclaw-gateway.service <<SVCEOF
[Unit]
Description=OpenClaw Gateway (Secure Deployment)
After=network-online.target docker.service litellm.service
Wants=network-online.target
Requires=docker.service litellm.service

[Service]
Type=simple
User=$OPENCLAW_USER
Group=$OPENCLAW_USER
WorkingDirectory=$OPENCLAW_HOME

ExecStartPre=$SECRETS_DIR/fetch-secrets.sh
ExecStart=$NODE_BIN $(npm root -g)/openclaw/dist/entry.js gateway --port 18789

EnvironmentFile=$SECRETS_DIR/openclaw-env
Environment=NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt
Environment=OPENCLAW_SERVICE_VERSION=$OPENCLAW_VERSION

Restart=on-failure
RestartSec=10

# Systemd-level hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=$OPENCLAW_HOME/.openclaw $OPENCLAW_HOME/.config /var/log/openclaw /tmp
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
MemoryDenyWriteExecute=false

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable openclaw-gateway.service

# Run initial secret fetch (as the openclaw user)
su - "$OPENCLAW_USER" -c "$SECRETS_DIR/fetch-secrets.sh" || true

# Start the service
systemctl start openclaw-gateway.service

echo "=== OpenClaw GCP Startup Complete ==="
echo "Finished at: $(date -u)"
echo "Gateway status: $(systemctl is-active openclaw-gateway.service)"
