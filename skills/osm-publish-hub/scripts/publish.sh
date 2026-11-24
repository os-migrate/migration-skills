#!/bin/bash
set -euo pipefail

# OS-Migrate Automation Hub Publish Script
# Publishes a pre-built os-migrate collection tarball to Red Hat Certified Automation Hub

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Red Hat SSO / Automation Hub configuration
SSO_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
AH_API="https://console.redhat.com/api/automation-hub"
AH_CONTENT_API="$AH_API/v3/plugin/ansible/content/published/collections/index"
AH_WEB_URL="https://console.redhat.com/ansible/automation-hub/repo/published/os_migrate/os_migrate/"

print_status() {
    local color=$1
    shift
    echo -e "${color}$*${NC}"
}

print_success() { print_status "$GREEN" "✅ $*"; }
print_error()   { print_status "$RED" "❌ $*"; }
print_warning() { print_status "$YELLOW" "⚠️  $*"; }
print_info()    { print_status "$BLUE" "ℹ️  $*"; }

usage() {
    echo "Usage: $0 <TARBALL> [--token TOKEN]"
    echo ""
    echo "Arguments:"
    echo "  TARBALL            Path to a pre-built os-migrate collection tarball"
    echo "  --token TOKEN      Automation Hub offline token (falls back to AUTOMATION_HUB_TOKEN env var)"
    echo ""
    echo "Examples:"
    echo "  $0 ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz"
    echo "  $0 ~/Downloads/os_migrate-os_migrate-1.0.4.tar.gz --token eyJhbG..."
    echo ""
    echo "Obtain a token from: https://console.redhat.com/ansible/automation-hub/token"
}

# Parse arguments
TOKEN=""
TARBALL=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)
            if [[ -z "${2:-}" ]]; then
                print_error "--token requires a value"
                exit 1
            fi
            TOKEN="$2"
            shift 2
            ;;
        --token=*)
            TOKEN="${1#--token=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            if [[ -z "$TARBALL" ]]; then
                TARBALL="$1"
            else
                print_error "Unexpected argument: $1"
                usage
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$TARBALL" ]]; then
    print_error "No tarball specified"
    echo ""
    usage
    exit 1
fi

# Resolve ~ in path
TARBALL="${TARBALL/#\~/$HOME}"

main() {
    echo ""
    print_info "os-migrate Automation Hub Publish"
    print_info "=================================="
    echo ""

    # 1. Validate the tarball
    if [[ ! -s "$TARBALL" ]]; then
        print_error "Tarball not found or empty: $TARBALL"
        exit 1
    fi

    if ! tar -tzf "$TARBALL" > /dev/null 2>&1; then
        print_error "Not a valid gzip archive: $TARBALL"
        exit 1
    fi

    TARBALL_NAME=$(basename "$TARBALL")
    TARBALL_SIZE=$(du -h "$TARBALL" | cut -f1)
    if [[ "$TARBALL_NAME" != os_migrate-os_migrate-*.tar.gz ]]; then
        print_error "Tarball does not look like an os-migrate collection: $TARBALL_NAME"
        print_error "Expected: os_migrate-os_migrate-X.Y.Z.tar.gz"
        exit 1
    fi
    print_success "Tarball: $TARBALL ($TARBALL_SIZE)"

    # 2. Extract version from filename
    VERSION=${TARBALL_NAME#os_migrate-os_migrate-}
    VERSION=${VERSION%.tar.gz}
    if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Could not extract valid semver from filename: $VERSION"
        exit 1
    fi
    print_success "Collection: os_migrate.os_migrate v$VERSION"

    # 3. Verify offline token
    OFFLINE_TOKEN="${TOKEN:-${AUTOMATION_HUB_TOKEN:-}}"
    if [[ -z "$OFFLINE_TOKEN" ]]; then
        print_error "No offline token provided"
        print_error "Use --token TOKEN or set AUTOMATION_HUB_TOKEN env var"
        print_error "Obtain a token from: https://console.redhat.com/ansible/automation-hub/token"
        exit 1
    fi
    print_success "Token: offline token provided"

    # 4. Verify ansible-galaxy is available
    if ! command -v ansible-galaxy > /dev/null 2>&1; then
        print_error "ansible-galaxy not found (pip install 'ansible-core>=2.16.0')"
        exit 1
    fi
    print_success "ansible-galaxy: $(ansible-galaxy --version | head -1)"

    # 5. Exchange offline token for access token (for API pre-flight checks)
    ACCESS_TOKEN=$(curl -s -X POST "$SSO_URL" \
        --form-string "grant_type=refresh_token" \
        --form-string "client_id=cloud-services" \
        --form-string "refresh_token=$OFFLINE_TOKEN" \
        | python3 -I -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))")

    if [[ -z "$ACCESS_TOKEN" ]]; then
        print_error "SSO token exchange failed — offline token may be expired or invalid"
        print_error "Obtain a fresh token from: https://console.redhat.com/ansible/automation-hub/token"
        exit 1
    fi
    print_success "SSO exchange: access token obtained"

    # 6. Check if version already exists on Automation Hub
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$AH_CONTENT_API/os_migrate/os_migrate/versions/$VERSION/")

    if [[ "$HTTP_CODE" == "200" ]]; then
        print_error "Version $VERSION already exists on Automation Hub"
        exit 1
    elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
        print_error "Authentication failed (HTTP $HTTP_CODE) — check your token"
        print_error "Obtain a fresh token from: https://console.redhat.com/ansible/automation-hub/token"
        exit 1
    elif [[ "$HTTP_CODE" != "404" ]]; then
        print_warning "Could not query Automation Hub (HTTP $HTTP_CODE), continuing anyway"
    else
        print_success "Pre-flight: version $VERSION not yet on Automation Hub"
    fi

    # 7. Write temporary ansible.cfg (required for auth_url — no CLI flag exists)
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT
    ANSIBLE_CFG="$TMPDIR/ansible.cfg"

    cat > "$ANSIBLE_CFG" <<CFG
[galaxy]
server_list = automation_hub

[galaxy_server.automation_hub]
url=https://console.redhat.com/api/automation-hub/content/published/
auth_url=https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token
token=$OFFLINE_TOKEN
CFG

    # 8. Publish to Automation Hub
    print_info "Publishing to Automation Hub..."
    if ! ANSIBLE_CONFIG="$ANSIBLE_CFG" ansible-galaxy collection publish "$TARBALL" \
            --server automation_hub 2>&1 | sed "s/${OFFLINE_TOKEN}/****/g"; then
        print_error "Publish failed (local tarball kept: $TARBALL)"
        exit 1
    fi
    print_success "Published to Automation Hub"

    # 9. Verify the upload
    sleep 5
    HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$AH_CONTENT_API/os_migrate/os_migrate/versions/$VERSION/")

    if [[ "$HTTP_CODE" == "200" ]]; then
        print_success "Verified: version $VERSION is now available on Automation Hub"
    else
        print_warning "Upload appeared to succeed but verification returned HTTP $HTTP_CODE"
        print_warning "Check manually: $AH_WEB_URL"
    fi

    # 10. Summary
    echo ""
    print_success "Done!"
    print_success "Collection: os_migrate.os_migrate v$VERSION"
    print_success "URL: $AH_WEB_URL"
}

main
