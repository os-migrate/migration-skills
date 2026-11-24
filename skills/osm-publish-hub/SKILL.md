---
name: osm-publish-hub
description: Publish a pre-built os-migrate collection tarball to Red Hat Automation Hub (console.redhat.com)
version: 1.0
---

# OS-Migrate Automation Hub Publish

Publish a pre-built os-migrate Ansible collection tarball to the Red Hat Certified Automation Hub at console.redhat.com.

## How This Skill Works

When you invoke `/osm-publish-hub`, Claude Code:
1. Reads this `SKILL.md` to understand what to do
2. Executes the bundled `scripts/publish.sh` script with the provided arguments
3. The script handles all publish logic (validation, SSO token exchange, publishing, verification)
4. Returns the results back to you with formatted output

The skill is **self-contained** — all logic is in the bundled script, so it can be executed independently or via Claude Code.

## Arguments

- `TARBALL` (required): Path to a pre-built collection tarball (e.g., `~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz`)
- `--token TOKEN` (optional): Automation Hub offline token (refresh token). Falls back to `AUTOMATION_HUB_TOKEN` env var. Obtain from https://console.redhat.com/ansible/automation-hub/token

## Usage Examples

```bash
# Publish with token from environment
/osm-publish-hub ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz

# Publish with explicit token
/osm-publish-hub ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz --token eyJhbG...

# Typical workflow: build then publish
/osm-build 1.0.4
/osm-publish-hub ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz
```

## Manual Execution

You can also run the script directly without Claude Code:

```bash
# From the project root
./skills/osm-publish-hub/scripts/publish.sh ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz --token YOUR_TOKEN

# Or with env var
AUTOMATION_HUB_TOKEN=YOUR_TOKEN ./skills/osm-publish-hub/scripts/publish.sh ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz
```

## Publish Process

Execute the bundled publish script:

```bash
./scripts/publish.sh "$@"
```

The script performs these steps:

1. **Validate tarball**: exists, is a valid gzip archive, and is an os-migrate collection
2. **Extract version** from the tarball filename and validate semver format
3. **Verify offline token** is available (argument or `AUTOMATION_HUB_TOKEN` env var)
4. **Check ansible-galaxy** is available locally
5. **Exchange offline token** for a short-lived access token via Red Hat SSO
6. **Check Automation Hub** to see if this version is already published (404 = good, 200 = already exists)
7. **Write temporary ansible.cfg** with Automation Hub server config (required for `auth_url` — no CLI flag exists)
8. **Publish** using `ansible-galaxy collection publish`
9. **Verify upload** succeeded by querying the API
10. **Clean up** temporary ansible.cfg (via `trap`, runs even on failure)

## Token Security

- Never echo, log, or display the offline token or access token value. The script masks them in `ansible-galaxy` output.
- The temporary `ansible.cfg` containing the token is cleaned up via a `trap` on EXIT.
- When reporting back to the user, do not repeat the token.

## Expected Output

```
os-migrate Automation Hub Publish:
✅ Tarball: ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz (234 KB)
✅ Collection: os_migrate.os_migrate v1.0.4
✅ Token: offline token provided
✅ SSO exchange: access token obtained
✅ Pre-flight: version 1.0.4 not yet on Automation Hub
✅ Published to Automation Hub
✅ Verified: version 1.0.4 is now available on Automation Hub
✅ URL: https://console.redhat.com/ansible/automation-hub/repo/published/os_migrate/os_migrate/
```

## Important Notes

- **os-migrate only**: This skill is for the `os_migrate.os_migrate` collection. Do not use it for `vmware_migration_kit`.
- **Pre-built tarball only**: This skill does not build the collection. Use `/osm-build` first to produce the tarball.
- **Token expiry**: Offline tokens from console.redhat.com can expire. If SSO exchange or auth fails, generate a fresh token from https://console.redhat.com/ansible/automation-hub/token.
- **Idempotency**: The pre-flight check prevents re-publishing an existing version.
