# goat-saas-agent-dist

Distribution scripts and release assets for `goat-saas-agent`.

## Security Notes

- `install.sh` supports `GOAT_SAAS_AGENT_VERSION=<tag>` for version-pinned installs.
- `cloud-setup.sh` installs Node.js through a signed NodeSource apt repository setup instead of piping a remote script into `bash`.
- `cloud-setup.sh` installs the released `goat-saas-agent` binary directly from GitHub release assets and verifies the published SHA-256 checksum before placing it in `/usr/local/bin`.
