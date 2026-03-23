#!/usr/bin/env bash
# One-time CouchDB cluster initialization for Obsidian LiveSync.
# Run this ONCE after the first `docker compose up -d`.
#
# This script is idempotent: safe to run multiple times.
# It sources .env for credentials, so no secrets are hardcoded.
#
# Usage:
#   ./scripts/couchdb-init.sh
#   # or with explicit values:
#   COUCHDB_USER=admin COUCHDB_PASSWORD=secret ./scripts/couchdb-init.sh

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env if it exists
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
fi

COUCH_HOST="${COUCH_HOST:-http://127.0.0.1:5984}"
COUCH_USER="${COUCHDB_USER:?COUCHDB_USER not set. Create .env from .env.example}"
COUCH_PASS="${COUCHDB_PASSWORD:?COUCHDB_PASSWORD not set. Create .env from .env.example}"

# --- Helpers ---
# Pass credentials via stdin to avoid them appearing in process table
couch_curl() {
    curl -sf -K - "$@" <<CRED
user = "${COUCH_USER}:${COUCH_PASS}"
CRED
}

couch_curl_verbose() {
    curl -s -K - "$@" <<CRED
user = "${COUCH_USER}:${COUCH_PASS}"
CRED
}

log() { echo "==> $*"; }
ok()  { echo "  [OK] $*"; }
fail() { echo "  [FAIL] $*"; }

# --- Preflight ---
if ! command -v curl &>/dev/null; then
    echo "ERROR: curl is required but not found."
    exit 1
fi

# --- Wait for CouchDB readiness ---
log "Waiting for CouchDB at ${COUCH_HOST} ..."
TIMEOUT=60
ELAPSED=0
while ! curl -sf "${COUCH_HOST}/_up" -o /dev/null 2>/dev/null; do
    if (( ELAPSED >= TIMEOUT )); then
        echo "ERROR: CouchDB did not become ready within ${TIMEOUT}s."
        echo "Check: docker compose ps / docker compose logs couchdb"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done

VERSION=$(couch_curl_verbose "${COUCH_HOST}/" 2>/dev/null | grep -o '"version":"[^"]*"' | cut -d'"' -f4)
ok "CouchDB ${VERSION:-unknown} is ready (${ELAPSED}s)"

# --- Idempotency check ---
log "Checking if already initialized ..."
if couch_curl -o /dev/null "${COUCH_HOST}/_users" 2>/dev/null; then
    ok "CouchDB is already initialized (_users database exists). Skipping cluster setup."
    ALREADY_INIT=true
else
    ALREADY_INIT=false

    # --- Single-node cluster setup ---
    log "Running single-node cluster setup ..."
    RESULT=$(couch_curl_verbose -X POST "${COUCH_HOST}/_cluster_setup" \
        -H "Content-Type: application/json" \
        -d "{\"action\":\"enable_single_node\",\"username\":\"${COUCH_USER}\",\"password\":\"${COUCH_PASS}\",\"bind_address\":\"0.0.0.0\",\"port\":5984,\"singlenode\":true}")

    if echo "$RESULT" | grep -q '"ok"'; then
        ok "Cluster setup complete"
    else
        fail "Cluster setup returned: $RESULT"
        exit 1
    fi
fi

# --- Verify system databases ---
log "Verifying system databases ..."
for db in _users _replicator _global_changes; do
    if couch_curl -o /dev/null "${COUCH_HOST}/${db}" 2>/dev/null; then
        ok "$db exists"
    else
        fail "$db missing"
    fi
done

# --- Verify configuration ---
log "Verifying CouchDB configuration ..."
ERRORS=0

check_config() {
    local section="$1" key="$2" expected="$3"
    local actual
    actual=$(couch_curl_verbose "${COUCH_HOST}/_node/_local/_config/${section}/${key}" 2>/dev/null | tr -d '"')
    if [[ "$actual" == "$expected" ]]; then
        ok "${section}/${key} = ${actual}"
    else
        fail "${section}/${key} = '${actual}' (expected '${expected}')"
        ERRORS=$((ERRORS + 1))
    fi
}

check_config "chttpd" "require_valid_user" "true"
check_config "chttpd" "enable_cors" "true"
check_config "chttpd" "max_http_request_size" "67108864"
check_config "couchdb" "max_document_size" "50000000"
check_config "cors" "credentials" "true"
check_config "cors" "origins" "app://obsidian.md,capacitor://localhost,http://localhost"

if (( ERRORS > 0 )); then
    echo ""
    echo "WARNING: ${ERRORS} config value(s) don't match expected values."
    echo "Check couchdb/local.ini is mounted correctly and restart the container."
else
    echo ""
    ok "All configuration values verified"
fi

# --- Summary ---
echo ""
echo "============================================"
if [[ "$ALREADY_INIT" == "true" ]]; then
    echo " CouchDB was already initialized."
else
    echo " CouchDB initialized successfully!"
fi
echo "============================================"
echo ""
echo "Next steps:"
echo "  1. Set up HTTPS via Tailscale:"
echo "     tailscale serve --bg 5984"
echo ""
echo "  2. Verify from another device on your tailnet:"
echo "     curl https://<pi-hostname>.<tailnet>.ts.net/"
echo ""
echo "  3. Configure Obsidian LiveSync plugin with that URL."
echo ""
