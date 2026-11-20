---
name: osm-publish-hub
description: Publish a pre-built os-migrate collection tarball to Red Hat Automation Hub (console.redhat.com)
tags: [publish, automation-hub, ansible, os-migrate]
---

# OS-Migrate Automation Hub Publish Skill

This skill publishes a pre-built os-migrate Ansible collection tarball to the Red Hat Certified Automation Hub at console.redhat.com.

## Usage

```
/osm-publish-hub <TARBALL> [--token TOKEN]
```

**Arguments:**
- `TARBALL` (required): Path to a pre-built collection tarball (e.g., `~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz`)
- `--token TOKEN` (optional): Automation Hub offline token (refresh token). Falls back to `AUTOMATION_HUB_TOKEN` env var. Obtain from https://console.redhat.com/ansible/automation-hub/token

## Examples

```bash
# Publish with token from environment
/osm-publish-hub ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz

# Publish with explicit token
/osm-publish-hub ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz --token eyJhbG...

# Typical workflow: build then publish
/osm-build 1.0.4
/osm-publish-hub ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz
```

## What it does

1. **Validate tarball** exists, is a valid gzip archive, and is an os-migrate collection
2. **Extract version** from the tarball filename
3. **Verify offline token** is available (argument or `AUTOMATION_HUB_TOKEN` env var)
4. **Check ansible-galaxy** is available locally
5. **Exchange offline token** for a short-lived access token via Red Hat SSO
6. **Check Automation Hub** to see if this version is already published
7. **Write temporary ansible.cfg** with Automation Hub server config (required for `auth_url`)
8. **Publish** using `ansible-galaxy collection publish`
9. **Verify upload** succeeded by querying the API
10. **Clean up** temporary ansible.cfg

## Output

```
os-migrate Automation Hub Publish:
✅ Tarball: ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz (234 KB)
✅ Collection: os_migrate.os_migrate v1.0.4
✅ Token: offline token provided
✅ SSO exchange: access token obtained
✅ Pre-flight: version 1.0.4 not yet on Automation Hub
✅ Published to Automation Hub
   https://console.redhat.com/ansible/automation-hub/repo/published/os_migrate/os_migrate/
```

---

# Implementation

## Background: Automation Hub Authentication

Automation Hub on console.redhat.com does **not** accept direct API tokens like community
Galaxy does. Instead it uses Red Hat SSO (Keycloak) with an offline/refresh token flow:

1. The user obtains an **offline token** (refresh token) from
   https://console.redhat.com/ansible/automation-hub/token
2. That offline token must be exchanged for a short-lived **access token** via the SSO
   endpoint at `https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token`
3. `ansible-galaxy` handles this exchange automatically, but **only** when `auth_url` is
   configured in `ansible.cfg` — there is no `--auth-url` CLI flag
4. The `--server` flag in `ansible-galaxy` takes a **config server name** (e.g.,
   `automation_hub`), not a raw URL, when using `ansible.cfg`

This means the skill must write a temporary `ansible.cfg` and point `ANSIBLE_CONFIG` at it.

## Steps

You are responsible for:

1. **Parse arguments**:
   - Extract TARBALL path (first positional argument, required)
   - Extract `--token` value if present, otherwise use `AUTOMATION_HUB_TOKEN` env var
   - If no tarball provided, error with usage example

2. **Validate the tarball**:
   ```bash
   # Check file exists and is non-empty
   if [[ ! -s "$TARBALL" ]]; then
     echo "Error: tarball not found or empty: $TARBALL"
     exit 1
   fi

   # Check it's a valid gzip archive
   if ! tar -tzf "$TARBALL" > /dev/null 2>&1; then
     echo "Error: not a valid gzip archive: $TARBALL"
     exit 1
   fi

   # Check it's an os-migrate collection (not vmware-migration-kit or something else)
   TARBALL_NAME=$(basename "$TARBALL")
   if [[ "$TARBALL_NAME" != os_migrate-os_migrate-*.tar.gz ]]; then
     echo "Error: tarball does not look like an os-migrate collection: $TARBALL_NAME"
     echo "Expected: os_migrate-os_migrate-X.Y.Z.tar.gz"
     exit 1
   fi
   ```

3. **Extract the version** from the tarball filename:
   ```bash
   VERSION=${TARBALL_NAME#os_migrate-os_migrate-}
   VERSION=${VERSION%.tar.gz}
   # Validate semver format
   if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
     echo "Error: could not extract valid semver from filename: $VERSION"
     exit 1
   fi
   ```

4. **Verify the offline token**:
   ```bash
   OFFLINE_TOKEN="${TOKEN:-$AUTOMATION_HUB_TOKEN}"
   if [[ -z "$OFFLINE_TOKEN" ]]; then
     echo "Error: no offline token provided"
     echo "Use --token TOKEN or set AUTOMATION_HUB_TOKEN env var"
     echo "Obtain a token from: https://console.redhat.com/ansible/automation-hub/token"
     exit 1
   fi
   ```

5. **Verify ansible-galaxy is available**:
   ```bash
   if ! command -v ansible-galaxy > /dev/null 2>&1; then
     echo "Error: ansible-galaxy not found (pip install 'ansible-core>=2.16.0')"
     exit 1
   fi
   ```

6. **Exchange the offline token for an access token** (for pre-flight API checks):
   ```bash
   SSO_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"

   ACCESS_TOKEN=$(curl -s -X POST "$SSO_URL" \
     -d "grant_type=refresh_token" \
     -d "client_id=cloud-services" \
     -d "refresh_token=$OFFLINE_TOKEN" \
     | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

   if [[ -z "$ACCESS_TOKEN" ]]; then
     echo "Error: SSO token exchange failed — offline token may be expired or invalid"
     echo "Obtain a fresh token from: https://console.redhat.com/ansible/automation-hub/token"
     exit 1
   fi
   ```
   - The `client_id` for console.redhat.com is `cloud-services`.
   - Never log or display the access token or offline token.

7. **Check if version already exists on Automation Hub**:
   ```bash
   AH_API="https://console.redhat.com/api/automation-hub"
   AH_CONTENT_API="$AH_API/v3/plugin/ansible/content/published/collections/index"

   HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
     -H "Authorization: Bearer $ACCESS_TOKEN" \
     "$AH_CONTENT_API/os_migrate/os_migrate/versions/$VERSION/")

   if [[ "$HTTP_CODE" == "200" ]]; then
     echo "Error: version $VERSION already exists on Automation Hub"
     exit 1
   elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
     echo "Error: authentication failed — check your token"
     echo "Obtain a fresh token from: https://console.redhat.com/ansible/automation-hub/token"
     exit 1
   elif [[ "$HTTP_CODE" != "404" ]]; then
     echo "Warning: could not query Automation Hub (HTTP $HTTP_CODE), continuing anyway"
   fi
   ```
   Note: a 404 means the version does not exist yet, which is what we want.

8. **Write a temporary ansible.cfg** for Automation Hub:
   ```bash
   TMPDIR=$(mktemp -d)
   ANSIBLE_CFG="$TMPDIR/ansible.cfg"

   cat > "$ANSIBLE_CFG" <<CFG
   [galaxy]
   server_list = automation_hub

   [galaxy_server.automation_hub]
   url=https://console.redhat.com/api/automation-hub/content/published/
   auth_url=https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
   token=$OFFLINE_TOKEN
   CFG
   ```
   - The `auth_url` tells `ansible-galaxy` to exchange the offline token via SSO
     automatically. Without this, authentication fails.
   - The `url` ends with `/content/published/` — this is the content path for the
     certified namespace.
   - The `token` here is the **offline token** (refresh token), not the access token.
     `ansible-galaxy` handles the exchange internally when `auth_url` is set.

9. **Publish to Automation Hub**:
   ```bash
   ANSIBLE_CONFIG="$ANSIBLE_CFG" ansible-galaxy collection publish "$TARBALL" \
     --server automation_hub 2>&1 | sed "s/${OFFLINE_TOKEN}/****/g"
   ```
   - `ANSIBLE_CONFIG` env var points `ansible-galaxy` at the temporary config.
   - `--server automation_hub` references the server **name** from the config, not a URL.
   - The `sed` pipe masks the token in any output — never display the token value.
   - If `ansible-galaxy` exits non-zero, report the error but do not delete the local tarball.

10. **Clean up** the temporary ansible.cfg:
    ```bash
    rm -rf "$TMPDIR"
    ```
    Always clean up, even on failure — the config contains the offline token.

11. **Verify the upload**:
    ```bash
    # Give the API a moment to index the new version, then check
    sleep 5
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      "$AH_CONTENT_API/os_migrate/os_migrate/versions/$VERSION/")

    if [[ "$HTTP_CODE" == "200" ]]; then
      echo "Verified: version $VERSION is now available on Automation Hub"
    else
      echo "Warning: upload appeared to succeed but verification returned HTTP $HTTP_CODE"
      echo "Check manually: https://console.redhat.com/ansible/automation-hub/repo/published/os_migrate/os_migrate/"
    fi
    ```

12. **Show summary**:
    - Display collection name and version
    - Display Automation Hub URL: `https://console.redhat.com/ansible/automation-hub/repo/published/os_migrate/os_migrate/`
    - Display tarball size

## Important Notes

- **Token type**: The token from console.redhat.com is an **offline/refresh token**, not a direct API key. It must be exchanged via Red Hat SSO. `ansible-galaxy` does this automatically when `auth_url` is configured in `ansible.cfg`.
- **ansible.cfg is required**: There is no `--auth-url` CLI flag. The skill must write a temporary `ansible.cfg` with the `auth_url` for the SSO endpoint and point `ANSIBLE_CONFIG` at it.
- **Always clean up**: The temporary `ansible.cfg` contains the offline token. Delete it after publishing, even on failure. Use a trap or ensure cleanup in all code paths.
- **Token security**: Never log, display, or echo the offline token or access token. Mask them in all command output with `sed`.
- **Pre-built tarball only**: This skill does not build the collection. Use `/osm-build` first to produce the tarball, then pass it to this skill.
- **os-migrate only**: This skill is for the `os_migrate.os_migrate` collection. Do not use it for `vmware_migration_kit`.
- **Token expiry**: Offline tokens from console.redhat.com can expire. If SSO exchange or auth fails, suggest the user generate a fresh token from https://console.redhat.com/ansible/automation-hub/token.
- **Idempotency**: The pre-flight check prevents re-publishing an existing version. If the version already exists, the skill exits with an error rather than attempting an overwrite.
- **Environment variable alternative**: Instead of `--token` or `AUTOMATION_HUB_TOKEN`, users can also set `ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN` which `ansible-galaxy` reads directly (pattern: `ANSIBLE_GALAXY_SERVER_<SERVER_NAME>_TOKEN`). If this env var is set and the user has their own `ansible.cfg` with the `auth_url` configured, the temporary config is not needed — but the skill should still write its own to be self-contained.

## Error Handling

- If tarball path not provided: show usage and exit
- If tarball does not exist or is empty: error and exit
- If tarball is not a valid archive: error and exit
- If tarball is not an os-migrate collection: error with expected naming and exit
- If version cannot be parsed from filename: error and exit
- If no token provided (arg or env): error with instructions to obtain one and exit
- If ansible-galaxy not found: error with install instructions and exit
- If SSO token exchange fails: error with link to get a new token and exit
- If token is expired or invalid (401/403): error with link to get a new token and exit
- If version already on Automation Hub: error and exit
- If publish fails: show error, keep local tarball, clean up temp config
- If post-publish verification fails: warning with manual check URL
- **Always clean up temp ansible.cfg** in all error paths (use `trap 'rm -rf "$TMPDIR"' EXIT`)
