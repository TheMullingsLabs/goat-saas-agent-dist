#!/bin/bash
# goat-saas-agent Cloud Build Setup
# Run on a fresh Ubuntu 24.04 server (DigitalOcean, Vultr, etc.)
# Usage: curl -sL https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/cloud-setup.sh | bash

set -euo pipefail

# Prevent interactive prompts during package installation
export DEBIAN_FRONTEND=noninteractive

echo "============================================"
echo "  goat-saas-agent Cloud Build Setup"
echo "============================================"
echo ""

# ── System updates ────────────────────────────────────────────────────────────

echo "[1/8] Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq -o Dpkg::Options::="--force-confold"

# ── Node.js 20 LTS ───────────────────────────────────────────────────────────

echo "[2/8] Installing Node.js 20 LTS..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
apt-get install -y -qq nodejs
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
curl -sL https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/install.sh | bash
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
