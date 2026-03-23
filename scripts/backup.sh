#!/usr/bin/env bash
# Simple CouchDB data backup for Obsidian LiveSync.
# Creates a timestamped tarball and removes old backups beyond retention.
#
# CouchDB uses append-only storage; file-level copy while running
# is safe — CouchDB will recover from any partial writes on restore.
#
# Usage:
#   ./scripts/backup.sh
#
# Cron example (daily at 3 AM):
#   0 3 * * * cd /srv/obsidian-livesync && ./scripts/backup.sh >> backups/backup.log 2>&1

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env for COUCHDB_DATA_PATH if available
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
fi

DATA_DIR="${COUCHDB_DATA_PATH:-${PROJECT_DIR}/couchdb-data}"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/backups}"
RETAIN_COUNT="${RETAIN_COUNT:-7}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="backup-${TIMESTAMP}.tar.gz"

# --- Preflight ---
if [[ ! -d "$DATA_DIR" ]]; then
    echo "ERROR: Data directory not found: ${DATA_DIR}"
    echo "Is CouchDB running? Has it created data yet?"
    exit 1
fi

mkdir -p "$BACKUP_DIR"

# --- Create backup ---
echo "[$(date -Iseconds)] Starting backup ..."
tar -czf "${BACKUP_DIR}/${BACKUP_FILE}" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"

SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
echo "[$(date -Iseconds)] Created: ${BACKUP_FILE} (${SIZE})"

# --- Cleanup old backups ---
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "backup-*.tar.gz" -type f | wc -l)
if (( BACKUP_COUNT > RETAIN_COUNT )); then
    REMOVE_COUNT=$((BACKUP_COUNT - RETAIN_COUNT))
    # shellcheck disable=SC2012
    ls -1t "${BACKUP_DIR}"/backup-*.tar.gz | tail -n "$REMOVE_COUNT" | while read -r old; do
        echo "[$(date -Iseconds)] Removing old backup: $(basename "$old")"
        rm -f "$old"
    done
fi

echo "[$(date -Iseconds)] Backup complete. ${RETAIN_COUNT} most recent backups retained."
