#!/bin/bash
# goat-saas-agent Cloud Build Setup
# Run on a fresh Ubuntu 24.04 server (DigitalOcean, Vultr, etc.)
# Usage: curl -sL https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/cloud-setup.sh | bash

set -euo pipefail

echo "============================================"
echo "  goat-saas-agent Cloud Build Setup"
echo "============================================"
echo ""

# ── System updates ────────────────────────────────────────────────────────────

echo "[1/7] Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# ── Node.js 20 LTS ───────────────────────────────────────────────────────────

echo "[2/7] Installing Node.js 20 LTS..."
curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
apt-get install -y -qq nodejs
echo "  Node.js $(node --version) installed"

# ── Build tools & Git ─────────────────────────────────────────────────────────

echo "[3/7] Installing build tools and Git..."
apt-get install -y -qq build-essential git tmux

# ── PostgreSQL 16 ─────────────────────────────────────────────────────────────

echo "[4/7] Installing PostgreSQL..."
apt-get install -y -qq postgresql postgresql-contrib
systemctl enable postgresql > /dev/null 2>&1
systemctl start postgresql
echo "  PostgreSQL $(psql --version | awk '{print $3}') installed"

# ── Claude Code CLI ───────────────────────────────────────────────────────────

echo "[5/7] Installing Claude Code CLI..."
npm install -g @anthropic-ai/claude-code --silent 2>/dev/null
echo "  Claude Code installed"

# ── goat-saas-agent ───────────────────────────────────────────────────────────

echo "[6/7] Installing goat-saas-agent..."
curl -sL https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/install.sh | bash
echo "  goat-saas-agent installed"

# ── Verification ──────────────────────────────────────────────────────────────

echo ""
echo "[7/7] Verifying installation..."
echo ""
echo "  Node.js:         $(node --version)"
echo "  npm:             $(npm --version)"
echo "  PostgreSQL:      $(pg_isready -q && echo 'running' || echo 'not running')"
echo "  Claude Code:     $(claude --version 2>/dev/null || echo 'installed (run claude login to authenticate)')"
echo "  goat-saas-agent: $(goat-saas-agent --version 2>/dev/null || echo 'installed')"
echo "  tmux:            $(tmux -V)"
echo ""
echo "============================================"
echo "  Setup complete!"
echo ""
echo "  Next steps:"
echo "    1. claude login"
echo "    2. goat-saas-agent setup"
echo "    3. git clone <your-repo>"
echo "    4. cd <your-repo>"
echo "    5. goat-saas-agent run"
echo ""
echo "  For live streams, use tmux:"
echo "    tmux new -s build"
echo "    goat-saas-agent run"
echo "    (Ctrl+B, D to detach)"
echo "    (tmux attach -t build to reconnect)"
echo "============================================"
