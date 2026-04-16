#!/bin/bash
# goat-saas-agent Cloud Build Setup
# Run on a fresh Ubuntu 24.04 server (DigitalOcean, Vultr, etc.)
# Usage:
#   curl -fsSLO https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/cloud-setup.sh
#   bash cloud-setup.sh

set -euo pipefail

# Prevent interactive prompts during package installation
export DEBIAN_FRONTEND=noninteractive

DIST_REPO="TheMullingsLabs/goat-saas-agent-dist"
API_BASE="https://api.github.com/repos/${DIST_REPO}"
DOWNLOAD_BASE="https://github.com/${DIST_REPO}/releases/download"
TMP_DIR="$(mktemp -d)"
CURL_OPTS=(--fail --silent --show-error --location --proto '=https' --tlsv1.2)

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

resolve_agent_target() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64) echo "linux-x64" ;;
    aarch64|arm64) echo "linux-arm64" ;;
    *)
      echo "Unsupported architecture: ${arch}" >&2
      exit 1
      ;;
  esac
}

resolve_agent_release_tag() {
  if [ -n "${GOAT_SAAS_AGENT_VERSION:-}" ]; then
    printf '%s' "${GOAT_SAAS_AGENT_VERSION}"
    return 0
  fi

  curl "${CURL_OPTS[@]}" "${API_BASE}/releases/latest" \
    | grep '"tag_name"' \
    | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/'
}

install_agent_release_binary() {
  local target binary_name tag download_url checksum_name
  target="$(resolve_agent_target)"
  binary_name="goat-saas-agent-${target}"
  tag="$(resolve_agent_release_tag)"

  if [ -z "${tag}" ]; then
    echo "  ERROR: Could not resolve goat-saas-agent release tag" >&2
    exit 1
  fi

  download_url="${DOWNLOAD_BASE}/${tag}/${binary_name}"
  checksum_name="checksums-${target}.txt"

  curl "${CURL_OPTS[@]}" "${download_url}" -o "${TMP_DIR}/${binary_name}"
  curl "${CURL_OPTS[@]}" "${DOWNLOAD_BASE}/${tag}/${checksum_name}" -o "${TMP_DIR}/checksums.txt"

  if ! grep -Eq "[[:space:]]${binary_name}$" "${TMP_DIR}/checksums.txt"; then
    echo "  ERROR: checksum file does not contain ${binary_name}" >&2
    exit 1
  fi

  (
    cd "${TMP_DIR}"
    sha256sum -c checksums.txt --ignore-missing
  )

  install -m 0755 "${TMP_DIR}/${binary_name}" /usr/local/bin/goat-saas-agent
  printf '%s\n' "${tag}" > /usr/local/bin/.goat-saas-agent-version
  echo "  ✓ goat-saas-agent ${tag} installed to /usr/local/bin/goat-saas-agent"
}

install_nodesource_node20() {
  install -d -m 0755 /etc/apt/keyrings
  curl "${CURL_OPTS[@]}" https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  chmod 0644 /etc/apt/keyrings/nodesource.gpg
  cat >/etc/apt/sources.list.d/nodesource.list <<'EOF'
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main
EOF
  apt-get update -qq
  apt-get install -y -qq nodejs
}

echo "============================================"
echo "  goat-saas-agent Cloud Build Setup"
echo "============================================"
echo ""

# ── System updates ────────────────────────────────────────────────────────────

echo "[1/8] Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"

# ── Node.js 20 LTS ───────────────────────────────────────────────────────────

echo "[2/8] Installing Node.js 20 LTS..."
apt-get install -y -qq ca-certificates curl gnupg
install_nodesource_node20
echo "  Node.js $(node --version) installed"

# ── Build tools & Git ─────────────────────────────────────────────────────────

echo "[3/8] Installing build tools, Git, and GitHub CLI..."
apt-get install -y -qq build-essential git tmux gh

# ── PostgreSQL 16 ─────────────────────────────────────────────────────────────

echo "[4/8] Installing PostgreSQL..."
apt-get install -y -qq postgresql postgresql-contrib
systemctl enable postgresql > /dev/null 2>&1
pg_ctlcluster 16 main start > /dev/null 2>&1 || true
echo "  PostgreSQL $(psql --version | awk '{print $3}') installed"
echo "  Status: $(pg_isready -q && echo 'running' || echo 'not running — run: sudo pg_ctlcluster 16 main start')"

# ── Claude Code CLI ───────────────────────────────────────────────────────────

echo "[5/8] Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code --silent 2>/dev/null
echo "  Claude Code installed"

# ── goat-saas-agent ───────────────────────────────────────────────────────────

echo "[6/8] Installing goat-saas-agent..."
install_agent_release_binary
echo "  goat-saas-agent installed"

# ── Verification ──────────────────────────────────────────────────────────────

echo ""
echo "[7/8] Verifying installation..."
echo ""
echo "  Node.js:         $(node --version)"
echo "  npm:             $(npm --version)"
echo "  PostgreSQL:      $(pg_isready -q && echo 'running' || echo 'not running')"
echo "  GitHub CLI:      $(gh --version 2>/dev/null | head -1 || echo 'not found')"
echo "  Claude Code:     $(claude --version 2>/dev/null || echo 'installed (run claude login to authenticate)')"
echo "  goat-saas-agent: $(goat-saas-agent --version 2>/dev/null || echo 'installed')"
echo "  tmux:            $(tmux -V)"
echo ""
echo "============================================"
echo "  Setup complete!"
echo ""
echo "[8/8] Next steps:"
echo "    1. claude login"
echo "    2. gh auth login"
echo "    3. goat-saas-agent setup"
echo "    4. gh repo clone <org>/<repo>"
echo "    5. cd <your-repo>"
echo ""
echo "  Start a build (always use tmux):"
echo "    tmux new -s build"
echo "    goat-saas-agent run"
echo ""
echo "  You can safely close the terminal."
echo "  The build continues on the server."
echo ""
echo "  Come back later from any terminal:"
echo "    ssh root@<server-ip>"
echo "    tmux attach -t build"
echo ""
echo "  Or use DigitalOcean web console:"
echo "    Droplets > your droplet > Access > Launch Droplet Console"
echo "    tmux attach -t build"
echo ""
echo "  tmux basics:"
echo "    Ctrl+B, D        — detach (build keeps running)"
echo "    tmux attach -t build — reconnect"
echo "    tmux ls          — list sessions"
echo "============================================"
