# Obsidian LiveSync - Self-Hosted CouchDB on Raspberry Pi

Docker Compose deployment of CouchDB for [Obsidian LiveSync](https://github.com/vrtmrz/obsidian-livesync), designed for Raspberry Pi with Tailscale for secure private access.

```
Obsidian (Desktop / Android)
        |
        | HTTPS (trusted Let's Encrypt cert)
        v
https://<pi>.<tailnet>.ts.net
        |
        | tailscale serve (reverse proxy)
        v
127.0.0.1:5984
        |
        v
CouchDB container (Docker)
        |
        v
Persistent data on disk
```

## Prerequisites

- **Raspberry Pi 3B+/4/5** running **64-bit OS** (`uname -m` must show `aarch64`)
- **Docker** and **Docker Compose v2** (`docker compose version`)
- **Tailscale** installed and connected to your tailnet
- All client devices (phones, laptops) on the same Tailscale network

## Quick Start

```bash
# 1. Clone to the Pi
git clone <this-repo> /srv/obsidian-livesync
cd /srv/obsidian-livesync

# 2. Configure credentials
cp .env.example .env
nano .env                          # Set a strong password
chmod 600 .env                     # Restrict file permissions

# 3. Start CouchDB
docker compose up -d

# 4. Initialize (first time only)
chmod +x scripts/couchdb-init.sh
./scripts/couchdb-init.sh

# 5. Enable HTTPS via Tailscale
tailscale serve --bg 5984

# 6. Verify
curl -u <user>:<pass> http://127.0.0.1:5984/_up   # Local check
# From another device on your tailnet:
curl https://<pi-hostname>.<tailnet>.ts.net/        # HTTPS check
```

## File Structure

```
.env.example          # Configuration template (safe to commit)
.env                  # Your real credentials (gitignored)
docker-compose.yml    # CouchDB service definition
couchdb/
  local.ini           # CouchDB config: CORS, auth, limits
scripts/
  couchdb-init.sh     # One-time cluster setup
  backup.sh           # Data backup utility
```

## HTTPS via Tailscale Serve

`tailscale serve` acts as a reverse proxy with automatic trusted HTTPS:

```bash
# Enable (persists across reboots)
tailscale serve --bg 5984

# Check status
tailscale serve status

# Disable
tailscale serve --bg --remove 5984
```

This gives you `https://<pi-hostname>.<tailnet>.ts.net` with a real Let's Encrypt certificate. No extra containers, no cert management, no public internet exposure.

**Why not Caddy/Traefik?** For a Tailscale-only deployment, `tailscale serve` is simpler and achieves the same result. If you later need more control (custom headers, path routing), add Caddy to the compose file.

## Configuring Obsidian LiveSync

### Option A: Setup URI (Recommended)

Generate a setup URI on a desktop device to avoid manual configuration:

```bash
# Install deno if not available: https://deno.land/
export hostname=https://<pi-hostname>.<tailnet>.ts.net
export database=obsidiannotes
export passphrase=your-e2ee-passphrase    # For end-to-end encryption
export username=<your COUCHDB_USER>
export password=<your COUCHDB_PASSWORD>
deno run -A https://raw.githubusercontent.com/vrtmrz/obsidian-livesync/main/utils/flyio/generate_setupuri.ts
```

Then on each device:
1. Install the **Self-hosted LiveSync** plugin in Obsidian
2. Open command palette: **Use the copied setup URI**
3. Paste the URI and enter the setup-URI passphrase
4. Follow the prompts

### Option B: Manual Configuration

In the LiveSync plugin settings:
- **URI**: `https://<pi-hostname>.<tailnet>.ts.net`
- **Username**: your `COUCHDB_USER`
- **Password**: your `COUCHDB_PASSWORD`
- **Database name**: `obsidiannotes` (or your choice)

Use the **Setup wizard** in the plugin for recommended settings.

## Backup & Restore

### Creating Backups

```bash
# Manual backup
./scripts/backup.sh

# Automated daily backup at 3 AM (add to crontab -e)
0 3 * * * cd /srv/obsidian-livesync && ./scripts/backup.sh >> backups/backup.log 2>&1
```

Backups are tarballs of the CouchDB data directory, stored in `backups/` with 7-day retention.

### Restoring

```bash
docker compose down
rm -rf couchdb-data/*
tar -xzf backups/backup-YYYYMMDD-HHMMSS.tar.gz
docker compose up -d
```

## Operations

### Container Management

```bash
docker compose ps              # Status
docker compose logs -f couchdb # Follow logs
docker compose restart couchdb # Restart (e.g., after editing local.ini)
docker compose down            # Stop
docker compose up -d           # Start
```

### Updating CouchDB

```bash
# Edit .env to change COUCHDB_IMAGE_TAG (e.g., 3.4.3 -> 3.5.1)
docker compose pull
docker compose up -d
```

Data persists across container updates within the CouchDB 3.x series.

### Resource Monitoring

```bash
docker stats obsidian-couchdb  # Live memory/CPU usage
```

If CouchDB is OOM-killed, increase `COUCHDB_MEM_LIMIT` in `.env` and restart.

## Troubleshooting

### Container won't start

```bash
docker compose logs couchdb    # Check error messages
```

Common causes:
- **Permission denied on data dir**: The entrypoint needs to run as root initially. Do not set `user:` in the compose override.
- **Port already in use**: Another service on port 5984. Check with `ss -tlnp | grep 5984`.

### Android "Failed to fetch"

1. Open `https://<pi-hostname>.<tailnet>.ts.net/` in Android browser — should show CouchDB welcome JSON with no cert warnings
2. If cert warning: ensure Tailscale is connected on the Android device
3. If no cert warning but plugin fails: enable **Use Request API** in LiveSync plugin settings
4. Check CouchDB logs: `docker compose logs -f couchdb`

### Init script reports config mismatches

The `local.ini` file may not be mounted correctly:

```bash
# Verify the mount
docker compose exec couchdb cat /opt/couchdb/etc/local.d/livesync.ini

# If missing, check the path in docker-compose.yml volumes
docker compose restart couchdb
./scripts/couchdb-init.sh       # Re-verify
```

### Sync is slow

CouchDB on Raspberry Pi with SD card storage will be slower than SSD. For better performance:
- Use an external USB SSD: set `COUCHDB_DATA_PATH=/mnt/ssd/couchdb-data` in `.env`
- Increase memory limit if the Pi has headroom

## Security

This deployment is hardened with multiple layers:

| Layer | Protection |
|-------|-----------|
| Network | Tailscale-only (no public internet, no LAN exposure) |
| Transport | Trusted HTTPS via Let's Encrypt |
| Port | CouchDB bound to `127.0.0.1` only |
| Auth | `require_valid_user = true` (no anonymous access) |
| Container | `cap_drop: ALL` + `no-new-privileges` |
| CORS | Restricted to Obsidian app origins |
| Request size | 64 MB limit (prevents memory exhaustion) |
| Secrets | `.env` gitignored, `chmod 600` |
