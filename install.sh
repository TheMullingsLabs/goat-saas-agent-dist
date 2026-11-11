#!/bin/bash
set -euo pipefail

# goat-saas-agent installer
# Usage: curl -sL https://raw.githubusercontent.com/TheMullingsLabs/goat-saas-agent-dist/main/install.sh | bash

DIST_REPO="TheMullingsLabs/goat-saas-agent-dist"
INSTALL_DIR="${HOME}/.local/bin"
API_BASE="https://api.github.com/repos/${DIST_REPO}"
DOWNLOAD_BASE="https://github.com/${DIST_REPO}/releases/download"
LATEST_URL="${API_BASE}/releases/latest"
# Test hook: tests point this at a local file:// fixture laid out like the release site
# (<base>/releases/latest, <base>/releases/download/<tag>/<file>). Unset in normal use.
if [ -n "${GOATSAAS_INSTALL_BASE_URL:-}" ]; then
  LATEST_URL="${GOATSAAS_INSTALL_BASE_URL}/releases/latest"
  DOWNLOAD_BASE="${GOATSAAS_INSTALL_BASE_URL}/releases/download"
fi

# Exit codes the agent's self-update reports in plain words (src/license/updater.ts,
# INSTALL_EXIT_MESSAGES). Keep the two in step.
EXIT_NO_RELEASE=10
EXIT_DOWNLOAD=11
EXIT_CHECKSUM=12
EXIT_INSTALL=13

# Network limits apply to a stalled or dead connection only, never to a download that is
# still moving: no connection in 20 s, or under 1 KB/s for 60 s, aborts; transient errors
# retry. There is deliberately no overall time limit (binaries are 50-65 MB).
CURL_NET=(--connect-timeout 20 --speed-limit 1024 --speed-time 60 --retry 3 --retry-delay 2)
if [ -t 1 ]; then
  CURL_PROGRESS=(--progress-bar)
else
  CURL_PROGRESS=(-sS)
fi

# Every run works in its own temporary folder, removed on exit, so two runs never share
# files and an interrupted run leaves nothing behind.
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# A stopped run (e.g. an older agent's 60 s limit sends SIGTERM) exits through the EXIT trap too.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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

# Get latest release tag. The repo is public, but api.github.com allows only
# 60 unauthenticated requests/hour per IP — a release day exhausts that and
# this call 403s (release-and-refresh step-4 failures, 2026-06-05 x2; the
# second recurrence happened because this fix originally landed only on the
# dist COPY, which build.yml overwrites from THIS file on every release —
# this file is the source of truth). Use a token when the caller provides
# one (GH_TOKEN or GITHUB_TOKEN); release-and-refresh.sh passes its own.
AUTH_HEADER=()
INSTALL_GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
if [ -n "${INSTALL_GH_TOKEN}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${INSTALL_GH_TOKEN}")
fi
echo "Fetching latest release..."
LATEST_TAG=""
if curl -fsSL "${CURL_NET[@]}" ${AUTH_HEADER[@]+"${AUTH_HEADER[@]}"} "${LATEST_URL}" -o "${WORK}/latest.json"; then
  LATEST_TAG=$(grep '"tag_name"' "${WORK}/latest.json" | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || true)
fi

if [ -z "${LATEST_TAG}" ]; then
  echo "ERROR: Could not fetch latest release."
  exit "${EXIT_NO_RELEASE}"
fi

echo "Latest version: ${LATEST_TAG}"

# Download binary
DOWNLOAD_URL="${DOWNLOAD_BASE}/${LATEST_TAG}/${BINARY_NAME}"
echo "Downloading ${BINARY_NAME} (${LATEST_TAG})..."
if ! curl -fL "${CURL_NET[@]}" "${CURL_PROGRESS[@]}" "${DOWNLOAD_URL}" -o "${WORK}/${BINARY_NAME}"; then
  echo "ERROR: Download failed. The installed version was not changed."
  exit "${EXIT_DOWNLOAD}"
fi

# Download and verify checksum
CHECKSUM_NAME="checksums-${TARGET}.txt"
if ! curl -fsSL "${CURL_NET[@]}" "${DOWNLOAD_BASE}/${LATEST_TAG}/${CHECKSUM_NAME}" -o "${WORK}/${CHECKSUM_NAME}"; then
  echo "ERROR: Checksum download failed. The installed version was not changed."
  exit "${EXIT_DOWNLOAD}"
fi

echo "Verifying checksum..."
CHECK_OK=1
if command -v sha256sum >/dev/null 2>&1; then
  (cd "${WORK}" && sha256sum -c "${CHECKSUM_NAME}" --ignore-missing) || CHECK_OK=0
elif command -v shasum >/dev/null 2>&1; then
  (cd "${WORK}" && shasum -a 256 -c "${CHECKSUM_NAME}") || CHECK_OK=0
else
  echo "WARNING: No checksum tool found — skipping verification"
fi
if [ "${CHECK_OK}" -ne 1 ]; then
  echo "ERROR: Checksum did not match. The installed version was not changed."
  exit "${EXIT_CHECKSUM}"
fi

# Install binary: copy next to the target, then rename over it, so the installed binary is
# either the old one or the complete new one, never a partial file.
if ! {
  mkdir -p "${INSTALL_DIR}" &&
    cp "${WORK}/${BINARY_NAME}" "${INSTALL_DIR}/.goatsaas.new.$$" &&
    chmod +x "${INSTALL_DIR}/.goatsaas.new.$$" &&
    mv -f "${INSTALL_DIR}/.goatsaas.new.$$" "${INSTALL_DIR}/goatsaas" &&
    ln -sf "${INSTALL_DIR}/goatsaas" "${INSTALL_DIR}/goat-saas-agent"
}; then
  rm -f "${INSTALL_DIR}/.goatsaas.new.$$"
  echo "ERROR: Install failed. The installed version was not changed."
  exit "${EXIT_INSTALL}"
fi

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
echo "  ✓ goatsaas ${LATEST_TAG} installed to ${INSTALL_DIR}/goatsaas"
echo "    (legacy alias: ${INSTALL_DIR}/goat-saas-agent)"
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
  echo "  To use goatsaas in this terminal, run:"
  echo ""
  echo "    source ${PATH_UPDATED}"
  echo ""
fi
echo "Run 'goatsaas setup' to activate with your API key."
