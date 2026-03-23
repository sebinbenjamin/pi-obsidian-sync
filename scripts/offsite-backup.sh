#!/usr/bin/env bash
# Off-site backup for Obsidian LiveSync.
# Encrypts the most recent local backup with age and uploads it to a configured rclone remote.
#
# Prerequisites:
#   sudo apt install rclone age
#   rclone config  (configure your Backblaze B2 remote)
#
# Usage:
#   ./scripts/offsite-backup.sh
#
# Cron (daily at 3 AM, after local backup):
#   0 3 * * * cd /srv/obsidian-livesync && ./scripts/backup.sh >> backups/backup.log 2>&1 \
#     && ./scripts/offsite-backup.sh >> backups/offsite-backup.log 2>&1
#
# Configuration: set OFFSITE_* variables in .env

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Source .env for OFFSITE_* variables if available
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/.env"
    set +a
fi

BACKUP_DIR="${BACKUP_DIR:-${PROJECT_DIR}/backups}"
OFFSITE_REMOTE="${OFFSITE_REMOTE:-}"
OFFSITE_PATH="${OFFSITE_PATH:-}"
OFFSITE_RETAIN_COUNT="${OFFSITE_RETAIN_COUNT:-7}"
OFFSITE_ENCRYPTION_KEY="${OFFSITE_ENCRYPTION_KEY:-}"

# --- Preflight checks ---
if ! command -v rclone &>/dev/null; then
    echo "ERROR: rclone not found. Install with: sudo apt install rclone"
    exit 1
fi

if ! command -v age &>/dev/null; then
    echo "ERROR: age not found. Install with: sudo apt install age"
    exit 1
fi

if [[ -z "$OFFSITE_REMOTE" ]]; then
    echo "ERROR: OFFSITE_REMOTE is not set in .env"
    exit 1
fi

if [[ -z "$OFFSITE_PATH" ]]; then
    echo "ERROR: OFFSITE_PATH is not set in .env"
    exit 1
fi

if [[ -z "$OFFSITE_ENCRYPTION_KEY" ]]; then
    echo "ERROR: OFFSITE_ENCRYPTION_KEY is not set in .env"
    echo "       Uploading unencrypted vault data to a third-party store is not allowed."
    echo "       Generate a keypair: age-keygen -o age-key.txt"
    echo "       Set OFFSITE_ENCRYPTION_KEY to the public key (age1...) in .env"
    exit 1
fi

# --- Find latest local backup ---
# shellcheck disable=SC2012
LATEST=$(ls -1t "${BACKUP_DIR}"/backup-*.tar.gz 2>/dev/null | head -1 || true)
if [[ -z "$LATEST" ]]; then
    echo "ERROR: No local backup tarballs found in ${BACKUP_DIR}"
    echo "       Run ./scripts/backup.sh first."
    exit 1
fi

BASENAME=$(basename "$LATEST")
ENCRYPTED_NAME="${BASENAME}.age"
TEMP_FILE="/tmp/${ENCRYPTED_NAME}"

echo "[$(date -Iseconds)] Starting off-site backup ..."
echo "[$(date -Iseconds)] Source: ${BASENAME}"

# --- Encrypt ---
age -r "$OFFSITE_ENCRYPTION_KEY" -o "$TEMP_FILE" "$LATEST"

# --- Upload ---
echo "[$(date -Iseconds)] Uploading to ${OFFSITE_REMOTE}:${OFFSITE_PATH}/ ..."
rclone copy "$TEMP_FILE" "${OFFSITE_REMOTE}:${OFFSITE_PATH}/" --retries 3

# --- Cleanup temp file ---
rm -f "$TEMP_FILE"
echo "[$(date -Iseconds)] Uploaded: ${ENCRYPTED_NAME}"

# --- Remote retention ---
mapfile -t REMOTE_FILES < <(rclone lsf "${OFFSITE_REMOTE}:${OFFSITE_PATH}/" --files-only 2>/dev/null | sort -r)
REMOTE_COUNT=${#REMOTE_FILES[@]}

if (( REMOTE_COUNT > OFFSITE_RETAIN_COUNT )); then
    REMOVE_COUNT=$(( REMOTE_COUNT - OFFSITE_RETAIN_COUNT ))
    for old in "${REMOTE_FILES[@]: -$REMOVE_COUNT}"; do
        echo "[$(date -Iseconds)] Removing old remote backup: ${old}"
        rclone deletefile "${OFFSITE_REMOTE}:${OFFSITE_PATH}/${old}"
    done
fi

echo "[$(date -Iseconds)] Off-site backup complete. ${OFFSITE_RETAIN_COUNT} most recent backups retained remotely."
