#!/bin/bash
# goatsaas Cloud Post-Setup
# Run as root AFTER completing the 3 interactive login steps.
# Handles: copy binary, create builder user, copy credentials, configure git.
#
# Usage:
#   1. Run cloud-setup.sh first (installs all dependencies)
#   2. Run: claude login
#   3. Run: goatsaas setup        # (legacy: goat-saas-agent setup still works)
#   4. Run this script: bash cloud-post-setup.sh <git-name> <git-email>
#
# Example:
#   bash cloud-post-setup.sh "Keno Mullings" "keno@example.com"

set -euo pipefail

# ── Validate arguments ──────────────────────────────────────────────────────

GIT_NAME="${1:-}"
GIT_EMAIL="${2:-}"

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
  echo "Usage: bash cloud-post-setup.sh <git-name> <git-email>"
  echo "Example: bash cloud-post-setup.sh \"Keno Mullings\" \"keno@example.com\""
  exit 1
fi

# ── Validate prerequisites ──────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  goatsaas Post-Setup"
echo "============================================"
echo ""

# Must be root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root."
  exit 1
fi

# Claude must be logged in
if [ ! -f /root/.claude.json ] && [ ! -d /root/.claude ]; then
  echo "ERROR: Claude Code not configured. Run 'claude login' first."
  exit 1
fi

# Agent must be set up
if [ ! -f /root/.goat-saas-agent/credentials.json ]; then
  echo "ERROR: goatsaas not activated. Run 'goatsaas setup' first."
  exit 1
fi

echo "  Prerequisites verified ✓"
echo ""

# ── Step 1: Copy binary to shared location ──────────────────────────────────

echo "[1/4] Making goatsaas available to all users..."
if [ -f /root/.local/bin/goatsaas ]; then
  rm -f /usr/local/bin/goatsaas
  cp /root/.local/bin/goatsaas /usr/local/bin/goatsaas
  chmod +x /usr/local/bin/goatsaas
  echo "  Copied to /usr/local/bin/goatsaas ✓"
elif [ -f /usr/local/bin/goatsaas ]; then
  echo "  Already at /usr/local/bin/goatsaas ✓"
else
  echo "  ERROR: goatsaas binary not found. Run install.sh first."
  exit 1
fi

# ── Step 2: Create builder user ─────────────────────────────────────────────

echo "[2/4] Creating builder user..."
if id "builder" &>/dev/null; then
  echo "  User 'builder' already exists ✓"
else
  adduser --disabled-password --gecos "" builder
  echo "  User 'builder' created ✓"
fi

# ── Step 3: Copy all credentials to builder ─────────────────────────────────

echo "[3/4] Copying credentials to builder..."

# Claude Code config directory
if [ -d /root/.claude ]; then
  rm -rf /home/builder/.claude
  cp -r /root/.claude /home/builder/.claude
  chown -R builder:builder /home/builder/.claude
  echo "  ~/.claude/ copied ✓"
fi

# Claude Code config file (.claude.json)
if [ -f /root/.claude.json ]; then
  cp /root/.claude.json /home/builder/.claude.json
  chown builder:builder /home/builder/.claude.json
  echo "  ~/.claude.json copied ✓"
fi

# goat-saas-agent credentials
if [ -d /root/.goat-saas-agent ]; then
  rm -rf /home/builder/.goat-saas-agent
  cp -r /root/.goat-saas-agent /home/builder/.goat-saas-agent
  chown -R builder:builder /home/builder/.goat-saas-agent
  echo "  ~/.goat-saas-agent/ copied ✓"
fi

# ── Step 4: Configure git for builder ───────────────────────────────────────

echo "[4/4] Configuring git for builder..."
su - builder -c "git config --global user.name \"$GIT_NAME\""
su - builder -c "git config --global user.email \"$GIT_EMAIL\""
echo "  git identity: $GIT_NAME <$GIT_EMAIL> ✓"

# ── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Post-setup complete!"
echo ""
echo "  Next steps:"
echo "    1. su - builder"
echo "    2. gh auth login"
echo "    3. gh repo clone <org>/<repo>"
echo "    4. (From local terminal) scp secrets.md to the server"
echo "    5. cd <repo> && goatsaas run --auto-approve --claude-code-analysis-model claude-sonnet-4-6"
echo ""
echo "  To skip database setup (already done as root):"
echo "    goatsaas run --from-step claude-code-phase-1 --auto-approve --claude-code-analysis-model claude-sonnet-4-6"
echo "============================================"
