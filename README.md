# goat-saas-agent-dist

Distribution assets for released `goat-saas-agent` binaries.

## Contents

- `install.sh` — subscriber install/update entry point for released binaries
- `cloud-setup.sh` / `cloud-post-setup.sh` — cloud host bootstrap helpers
- `runner-image/` — mirrored runner-image assets, including the callback-server copy that must stay in sync with `goat-saas-skill-setup/runner-image/`

## Security Notes

- `install.sh` supports `GOAT_SAAS_AGENT_VERSION=<tag>` for version-pinned installs.
- `cloud-setup.sh` installs Node.js through a signed NodeSource apt repository setup instead of piping a remote script into `bash`.
- `cloud-setup.sh` installs the released `goat-saas-agent` binary directly from GitHub release assets and verifies the published SHA-256 checksum before placing it in `/usr/local/bin`.
