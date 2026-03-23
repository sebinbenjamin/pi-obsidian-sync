# Obsidian LiveSync - Self-Hosted CouchDB on Raspberry Pi

[Obsidian](https://obsidian.md/)'s built-in Sync is a paid subscription. This project provides a free, self-hosted alternative using the community [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin. It runs [CouchDB](https://couchdb.apache.org/) in Docker on a Raspberry Pi and uses [Tailscale](https://tailscale.com/) for zero-config private networking with trusted HTTPS, no port forwarding, no public internet exposure, and no self-signed certificates. The result is reliable sync across desktop and Android devices on your private tailnet.

> **Note:** This repo provides the server-side infrastructure only (CouchDB + Docker + Tailscale). The Obsidian plugin ([Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync)) is a separate install done from within Obsidian.

## Features

- Docker Compose deployment of CouchDB optimized for ARM64 (Raspberry Pi 3B+/4/5)
- Trusted HTTPS via Tailscale Serve: real Let's Encrypt certificates, critical for Android compatibility
- Private access only: CouchDB bound to localhost, accessible only through your Tailscale network
- Security hardened: `cap_drop: ALL`, `no-new-privileges`, CORS restricted to Obsidian origins
- Automated local and encrypted off-site backup with configurable retention
- Idempotent initialization script (safe to re-run)
- SD card wear reduction: logs and temp files kept in tmpfs
- Setup URI generation for easy multi-device onboarding

## Architecture

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
- User in the `docker` group (`sudo usermod -aG docker $USER`) or use `sudo` for docker commands

## Quick Start

```bash
# 1. Clone to the Pi | use sudo if necessary to write to /srv
mkdir -p /srv/obsidian-livesync
chown $USER:$USER /srv/obsidian-livesync
git clone https://github.com/sebinbenjamin/pi-obsidian-sync.git /srv/obsidian-livesync
cd /srv/obsidian-livesync

# 2. Configure credentials
cp .env.example .env
nano .env                          # Set a strong password
chmod 600 .env                     # Restrict file permissions

# 3. Start CouchDB
docker compose up -d

# 4. Initialize (first time only)
./scripts/couchdb-init.sh

# 5. Enable HTTPS via Tailscale (requires sudo)
sudo tailscale serve --bg 5984

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
  backup.sh           # Local data backup utility
  offsite-backup.sh   # Encrypted off-site upload (Backblaze B2 via rclone)
docs/
  DESIGN.md           # Architecture decisions and design rationale
  OFFSITE_BACKUP.md   # Off-site backup design and decisions
```

## HTTPS via Tailscale Serve

`tailscale serve` acts as a reverse proxy with automatic trusted HTTPS:

```bash
# Enable (persists across reboots, requires sudo)
sudo tailscale serve --bg 5984

# Check status
sudo tailscale serve status

# Disable (syntax varies by Tailscale version; try one of these)
sudo tailscale serve reset
# or: sudo tailscale serve off
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

# Automated daily backup at 3 AM (add to root crontab: sudo crontab -e)
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

> **Note:** If you set a custom `COUCHDB_DATA_PATH` in `.env` (e.g., `/mnt/ssd/couchdb-data`), extract the backup to that location instead: `tar -xzf backups/backup-... -C /mnt/ssd/`

### Off-Site Backup

Local backups in `backups/` do not survive Pi hardware failure, SD-card failure, or physical loss. Off-site backup encrypts and uploads each local backup to Backblaze B2.

#### Prerequisites

```bash
sudo apt install rclone age
```

#### 1. Generate an age keypair

```bash
age-keygen -o age-key.txt
```

The output contains a public key on the third line starting with `age1...`. Copy that line into `.env` as `OFFSITE_ENCRYPTION_KEY`. Store `age-key.txt` outside the Pi (e.g., your password manager). You need this file to decrypt backups. Without it, encrypted backups cannot be recovered.

#### 2. Set up Backblaze B2

1. Create a free account at [backblaze.com](https://www.backblaze.com/)
2. Create a bucket (e.g., `obsidian-pi-backups`)
3. Create an **Application Key** scoped to that bucket with read and write permissions
4. Run `rclone config` on the Pi, add a new remote of type `b2`, and enter the Account ID and Application Key when prompted. Name it (e.g., `b2-obsidian`).

#### 3. Configure `.env`

```env
OFFSITE_REMOTE=b2-obsidian
OFFSITE_PATH=obsidian-pi-backups
OFFSITE_RETAIN_COUNT=7
OFFSITE_ENCRYPTION_KEY=age1...
```

#### 4. Test

```bash
# Create a local backup first if one does not exist
./scripts/backup.sh

# Run the off-site upload
./scripts/offsite-backup.sh
```

Verify that `backup-YYYYMMDD-HHMMSS.tar.gz.age` appears in your B2 bucket.

#### 5. Automate with cron

Replace the local-only cron entry with the chained version:

```bash
0 3 * * * cd /srv/obsidian-livesync && ./scripts/backup.sh >> backups/backup.log 2>&1 \
  && ./scripts/offsite-backup.sh >> backups/offsite-backup.log 2>&1
```

#### Restore from off-site

```bash
# 1. Download the backup from B2
rclone copy b2-obsidian:obsidian-pi-backups/backup-YYYYMMDD-HHMMSS.tar.gz.age ./restore/

# 2. Decrypt (requires age-key.txt)
age -d -i age-key.txt -o backup.tar.gz restore/backup-YYYYMMDD-HHMMSS.tar.gz.age

# 3. Stop CouchDB, clear data, restore, restart
docker compose down
rm -rf couchdb-data/*
tar -xzf backup.tar.gz
docker compose up -d
```

#### Optional hardening: B2 Object Lock

By default the offsite script manages retention by listing and deleting old remote files. A compromised Pi could prune that history. B2 Object Lock prevents uploaded files from being deleted or modified until a configurable retention date, making the remote store tamper-resistant. See [Backblaze Object Lock docs](https://www.backblaze.com/docs/cloud-storage-object-lock) for setup. If you enable it, set `OFFSITE_RETAIN_COUNT` high enough to accommodate the lock period.

For the full rationale behind these choices (destinations evaluated, encryption decision, v2 path with restic), see [docs/OFFSITE_BACKUP.md](docs/OFFSITE_BACKUP.md).

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

1. Open `https://<pi-hostname>.<tailnet>.ts.net/` in Android browser. It should show CouchDB welcome JSON with no certificate warnings.
2. If cert warning: ensure Tailscale is connected on the Android device
3. If no cert warning but plugin fails: enable **Use Request API** in LiveSync plugin settings
4. Check CouchDB logs: `docker compose logs -f couchdb`

### Init script reports config mismatches

The `local.ini` file may not be mounted correctly:

```bash
# Verify the mount
docker compose exec couchdb cat /opt/couchdb/etc/local.d/001-livesync.ini

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

| Layer        | Protection                                                |
| ------------ | --------------------------------------------------------- |
| Network      | Tailscale-only (no public internet, no LAN exposure)      |
| Transport    | Trusted HTTPS via Let's Encrypt                           |
| Port         | CouchDB bound to `127.0.0.1` only                         |
| Auth         | `require_valid_user = true` (no anonymous access)         |
| Container    | `cap_drop: ALL` + minimal `cap_add` + `no-new-privileges` |
| CORS         | Restricted to Obsidian app origins                        |
| Request size | 64 MB limit (prevents memory exhaustion)                  |
| Secrets      | `.env` gitignored, `chmod 600`                            |

## Design Rationale

For the full architecture decisions, risk analysis, and phased deployment strategy, see [docs/DESIGN.md](docs/DESIGN.md).

## License

[MIT](LICENSE)
