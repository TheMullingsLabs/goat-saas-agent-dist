# goat-saas-agent-dist

Distribution assets for released `goat-saas-agent` binaries.

## Contents

- `install.sh` — subscriber install/update entry point for released binaries. Consumed by `setup.sh` in `goat-saas-skill-setup/runner-image/` during runner-image snapshot builds. `install.sh` downloads the `goat-saas-agent-linux-x64` / `goat-saas-agent-linux-arm64` binary from the matching GitHub release and verifies the published SHA-256 checksum before placement.
- `cloud-setup.sh` / `cloud-post-setup.sh` — cloud host bootstrap helpers
- `runner-image/` — mirrored runner-image assets. **Scope:** this mirror contains **only** `runner-image/callback-server/`. It does **not** contain `setup.sh` or `refresh-runner-image.sh` — those live solely in `goat-saas-skill-setup/runner-image/` and are not duplicated here.

### Parity invariant: `runner-image/callback-server/`

The `runner-image/callback-server/` directory in this repo is kept **byte-identical** to `goat-saas-skill-setup/runner-image/callback-server/` by convention. A `diff` between the two directories should return empty. Any change to one must be mirrored to the other in the same commit/PR — the callback-server cross-cutting notes in the top-level `CLAUDE.md` explicitly call this out ("Both copies must stay in sync").

## Security Notes

- `install.sh` supports `GOAT_SAAS_AGENT_VERSION=<tag>` for version-pinned installs.
- `install.sh` downloads the released `goat-saas-agent-linux-x64` / `goat-saas-agent-linux-arm64` binary from GitHub release assets and verifies the published SHA-256 checksum before installing it. This is the same verification path used by `setup.sh` when it invokes `install.sh` during runner-image snapshot builds.
- `cloud-setup.sh` installs Node.js through a signed NodeSource apt repository setup instead of piping a remote script into `bash`.
- `cloud-setup.sh` installs the released `goat-saas-agent` binary directly from GitHub release assets and verifies the published SHA-256 checksum before placing it in `/usr/local/bin`.
