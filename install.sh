#!/bin/bash
set -euo pipefail

# goat-saas-agent installer
# Usage: curl -sL https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/install.sh | bash

DIST_REPO="TheMullingsLabs/goat-saas-agent-dist"
INSTALL_DIR="${HOME}/.local/bin"
API_BASE="https://api.github.com/repos/${DIST_REPO}"
DOWNLOAD_BASE="https://github.com/${DIST_REPO}/releases/download"

# Detect platform
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"

case "${OS}" in
  linux*)  PLATFORM="linux" ;;
  darwin*) PLATFORM="darwin" ;;
  *)       echo "Unsupported OS: ${OS}"; exit 1 ;;
esac

case "${ARCH}" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *)             echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
esac

TARGET="${PLATFORM}-${ARCH}"
BINARY_NAME="goat-saas-agent-${TARGET}"

# Get latest release tag (public repo — no auth needed)
echo "Fetching latest release..."
LATEST_TAG=$(curl -fsSL \
  "${API_BASE}/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

if [ -z "${LATEST_TAG}" ]; then
  echo "ERROR: Could not fetch latest release."
  exit 1
fi

echo "Latest version: ${LATEST_TAG}"

# Download binary
DOWNLOAD_URL="${DOWNLOAD_BASE}/${LATEST_TAG}/${BINARY_NAME}"
echo "Downloading ${BINARY_NAME} (${LATEST_TAG})..."
curl -fsSL -L "${DOWNLOAD_URL}" -o "/tmp/${BINARY_NAME}"

# Download and verify checksum
CHECKSUM_NAME="checksums-${TARGET}.txt"
curl -fsSL -L \
  "${DOWNLOAD_BASE}/${LATEST_TAG}/${CHECKSUM_NAME}" \
  -o "/tmp/checksums.txt"

echo "Verifying checksum..."
(cd /tmp && sha256sum -c checksums.txt --ignore-missing)

# Install binary
mkdir -p "${INSTALL_DIR}"
mv "/tmp/${BINARY_NAME}" "${INSTALL_DIR}/goat-saas-agent"
chmod +x "${INSTALL_DIR}/goat-saas-agent"

# Write version file for --check-update
echo "${LATEST_TAG}" > "${INSTALL_DIR}/.goat-saas-agent-version"

# Ensure PATH includes install dir
if ! echo "${PATH}" | grep -q "${INSTALL_DIR}"; then
  SHELL_RC="${HOME}/.bashrc"
  [ -f "${HOME}/.zshrc" ] && SHELL_RC="${HOME}/.zshrc"
  echo "export PATH=\"${INSTALL_DIR}:\${PATH}\"" >> "${SHELL_RC}"
  echo "Added ${INSTALL_DIR} to PATH in ${SHELL_RC}"
  export PATH="${INSTALL_DIR}:${PATH}"
fi

echo ""
echo "  ✓ goat-saas-agent ${LATEST_TAG} installed to ${INSTALL_DIR}/goat-saas-agent"
echo ""

# Check runtime dependencies
echo "Checking dependencies..."
command -v git >/dev/null 2>&1 \
  && echo "  ✓ git" \
  || echo "  ✗ git (required — install with: sudo apt install git)"
command -v node >/dev/null 2>&1 \
  && echo "  ✓ node" \
  || echo "  ✗ node (required — install with: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install nodejs)"
command -v claude >/dev/null 2>&1 \
  && echo "  ✓ claude CLI" \
  || echo "  ✗ claude CLI (required — install with: npm install -g @anthropic-ai/claude-code)"

echo ""
echo "Run 'goat-saas-agent setup' to activate with your API key."
