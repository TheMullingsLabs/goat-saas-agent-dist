# AGENT.md - goat-saas-agent-dist

Purpose: operating guide for coding agents working in `goat-saas-agent-dist`.

## Mission

Maintain the released installer and cloud bootstrap scripts for `goat-saas-agent` without breaking platform detection, checksum verification, dependency setup, or operator onboarding.

## Shape

- `install.sh`: downloads the latest released binary, verifies checksums, installs it into the user's path
- `cloud-setup.sh`: provisions a fresh Ubuntu server for long-running builds
- `runner-image/`: distribution-side runner image assets and helpers

## Source Of Truth

- `install.sh`
- `cloud-setup.sh`
- `README.md`

Mandatory instruction: follow the monorepo root `.claude/feedback_workflow_rules.md` for every change in this repo.

## Non-Negotiable Rules

- Keep the install flow non-interactive and safe for curl-pipe execution.
- Do not remove checksum verification without an explicit replacement.
- Be careful when editing shell startup file writes; avoid duplicate or destructive path mutations.
- Do not hardcode secrets, tokens, or user-specific paths.
- Preserve supported platform detection behavior unless the change is deliberate and documented.

## Recommended Checks

- `bash -n install.sh`
- `bash -n cloud-setup.sh`

## Definition Of Done

A change is done only when both scripts are still syntactically valid, the install/bootstrap flow remains documented, and any compatibility change is reflected in the repo docs.
