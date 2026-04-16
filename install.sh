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
if command -v sha256sum >/dev/null 2>&1; then
  (cd /tmp && sha256sum -c checksums.txt --ignore-missing)
elif command -v shasum >/dev/null 2>&1; then
  (cd /tmp && shasum -a 256 -c checksums.txt)
else
  echo "WARNING: No checksum tool found — skipping verification"
fi

# Install binary
mkdir -p "${INSTALL_DIR}"
mv "/tmp/${BINARY_NAME}" "${INSTALL_DIR}/goat-saas-agent"
chmod +x "${INSTALL_DIR}/goat-saas-agent"

# Write version file for --check-update
echo "${LATEST_TAG}" > "${INSTALL_DIR}/.goat-saas-agent-version"

# Ensure PATH includes install dir
PATH_UPDATED=""
if ! echo "${PATH}" | grep -q "${INSTALL_DIR}"; then
  # Detect the correct shell rc file
  SHELL_RC=""
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  SHELL_RC="${HOME}/.zshrc" ;;
    fish) SHELL_RC="${HOME}/.config/fish/config.fish" ;;
    *)    SHELL_RC="${HOME}/.bashrc" ;;
  esac
  # Prefer .zshrc on macOS (default shell is zsh)
  if [ "${PLATFORM}" = "darwin" ] && [ -f "${HOME}/.zshrc" ]; then
    SHELL_RC="${HOME}/.zshrc"
  fi

  if [ -n "${SHELL_RC}" ]; then
    if [ "$(basename "${SHELL_RC}")" = "config.fish" ]; then
      mkdir -p "$(dirname "${SHELL_RC}")"
      echo "set -gx PATH ${INSTALL_DIR} \$PATH" >> "${SHELL_RC}"
    else
      echo "export PATH=\"${INSTALL_DIR}:\${PATH}\"" >> "${SHELL_RC}"
    fi
    echo "Added ${INSTALL_DIR} to PATH in ${SHELL_RC}"
    PATH_UPDATED="${SHELL_RC}"
  fi
  export PATH="${INSTALL_DIR}:${PATH}"
fi

echo ""
echo "  ✓ goat-saas-agent ${LATEST_TAG} installed to ${INSTALL_DIR}/goat-saas-agent"
echo ""

# Check runtime dependencies
echo "Checking dependencies..."
if command -v git >/dev/null 2>&1; then
  echo "  ✓ git"
elif [ "${PLATFORM}" = "darwin" ]; then
  echo "  ✗ git (required — install with: xcode-select --install)"
else
  echo "  ✗ git (required — install with: sudo apt install git)"
fi

if command -v node >/dev/null 2>&1; then
  echo "  ✓ node"
elif [ "${PLATFORM}" = "darwin" ]; then
  echo "  ✗ node (required — install with: brew install node@20)"
else
  echo "  ✗ node (required — install with: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install nodejs)"
fi

if command -v claude >/dev/null 2>&1; then
  echo "  ✓ claude CLI"
else
  echo "  ✗ claude CLI (required — install with: npm install -g @anthropic-ai/claude-code)"
fi

echo ""
if [ -n "${PATH_UPDATED}" ]; then
  echo "  To use goat-saas-agent in this terminal, run:"
  echo ""
  echo "    source ${PATH_UPDATED}"
  echo ""
fi
echo "Run 'goat-saas-agent setup' to activate with your API key."
