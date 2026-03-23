# Off-Site Backup Design

> This document captures the problem statement, options evaluated, and decisions made when adding off-site backup to this project. It is a permanent reference for why specific choices were made.

---

## Problem

The existing backup script (`scripts/backup.sh`) creates timestamped `.tar.gz` archives in `backups/` on the Pi itself. This is useful for recovering from accidental deletion or data corruption, but it is not a real backup strategy. All copies live on the same hardware.

Failure modes that local backups do not protect against:

- SD card failure (common on Pis writing frequently)
- Pi hardware failure (power surge, physical damage)
- Theft or physical loss of the device
- Accidental deletion of the entire project directory

Off-site backup sends an encrypted copy to a remote destination after each local backup completes.

---

## Two Separate Design Decisions

Off-site backup involves two choices that should not be conflated:

**A. Destination: where do the backups live?**
This is a storage provider or target machine.

**B. Backup engine: what tool writes and manages them?**
This is the software that handles encryption, upload, deduplication, and retention.

Conflating these leads to poor comparisons. For example, comparing "GitHub" (a source-code platform) directly against "Backblaze B2" (an object-storage service) is mixing a specific destination with a tooling ecosystem.

---

## Destinations Considered

### GitHub: not suitable

Git enforces a 100 MB hard limit per object. Repos should stay under 1 GB, with 5 GB as the outer limit. LFS extends this but adds billing complexity and operational friction. Git was designed for source code history, not rotating binary blobs. Even a modest CouchDB backup tarball (200 MB) would exceed the per-object limit without LFS.

**Decision: ruled out. Wrong tool for this use case.**

### Google Drive

rclone supports Google Drive with a well-documented headless setup path (do the OAuth browser step on another machine, copy the token). The one-time friction is real but not a blocker.

The more significant issue: the 15 GB free tier is shared across Google Drive, Gmail, and Photos. Effective available space is unpredictable and may be much less than 15 GB in practice. Google Drive is a consumer file-sync product, not a backup system.

This setup has no secondary machine available, which makes the initial headless OAuth step more difficult and removes the SFTP-to-own-machine option entirely.

**Decision: not the primary recommendation given no secondary machine. Acceptable fallback if someone already has Google One storage and wants simplicity.**

### SFTP via Tailscale (another machine)

If you have an always-on machine at a different physical location on your Tailscale network, rclone's SFTP remote makes it a valid off-site target. This is the highest-trust option because no third party holds the data.

However, plain `rsync` or `rclone copy` to a remote machine is a copy mechanism, not a backup system. Without snapshotting or append-only discipline on the receiving end (e.g., a restic/borg repository, or a snapshotting NAS), accidental deletion or corruption can propagate from the source to the destination.

Additionally, "off-site" only helps if the second machine is physically elsewhere. Same building does not protect against fire, flooding, or theft.

**Decision: not applicable for this setup (no secondary machine). Good secondary option for others who have an off-site machine with snapshotting discipline.**

### Backblaze B2

Purpose-built object storage, not a file-sync or version-control system. Key properties:

- Headless-friendly: authentication uses a static Account ID and Application Key, no OAuth browser step
- Application keys can be scoped to a single bucket, limiting blast radius if the Pi is compromised
- 10 GB free storage; $0.005/GB/month beyond that
- No per-file size limit (up to 10 TB per object)
- Download pricing: first 1 GB/day free, then $0.01/GB
- Supports Object Lock: uploaded files can be made undeletable until a configurable retention date (see Hardening section below)
- First-class rclone support

**Decision: primary recommendation.**

---

## Backup Engine

### v1: tar.gz + age + rclone

The simplest approach that delivers correctness:

1. `scripts/backup.sh` creates a `.tar.gz` of the CouchDB data directory (already implemented)
2. `scripts/offsite-backup.sh` encrypts the latest tarball with `age` and uploads it via rclone

This is understandable, debuggable, and extends the existing backup pattern with minimal new complexity.

Trade-offs:

- Each upload is a full opaque blob, no block-level deduplication
- Upload volume grows with vault size; no delta compression
- Integrity verification is manual (decrypt and extract)
- Retention logic lives in the script, meaning the Pi can also delete remote history

### v2: restic (future path)

restic is a backup tool specifically designed for this class of problem. Relevant properties:

- Encrypted at rest (AES-256 with a content-defined chunking scheme)
- Block-level deduplication: only changed chunks are uploaded on each run
- Built-in integrity verification (`restic check`)
- Native support for many backends including Backblaze B2
- Append-only repository mode: a compromised client cannot delete historical snapshots
- For Backblaze B2 specifically, the restic documentation recommends using the S3-compatible API endpoint rather than the native B2 backend due to error-handling issues in the current B2 library

restic is the right long-term tool. For a single-vault personal setup, v1 is sufficient to start. If the vault grows significantly or stronger integrity/audit guarantees are needed, migrating to restic is the natural next step.

---

## Encryption

### Why encrypt before upload

The vault contains personal notes. Uploading plaintext to a third-party object store means the provider can read the content. Encryption ensures that even if Backblaze credentials are compromised or the provider is subpoenaed, the backup contents are unreadable without the private key.

The off-site script makes encryption mandatory. There is no flag to skip it.

### age over gpg

`age` is preferred over GPG for unattended scripts:

- No keyring, no agent, no trust database
- Encrypting is a single command: `age -r <public-key> -o output.age input`
- No interactive prompts that could stall a cron job
- The public key is a single short string that fits cleanly in `.env`
- Available in Debian/Ubuntu repos since Bullseye (`sudo apt install age`)

GPG works but requires managing a keyring and agent, which adds operational surface area for a headless cron job.

### Key management

- The private key is generated once with `age-keygen -o age-key.txt`
- The public key (one line starting with `age1...`) is placed in `.env` as `OFFSITE_ENCRYPTION_KEY`
- The private key file (`age-key.txt`) must be stored outside the Pi, such as a password manager or encrypted local storage on a trusted machine
- Loss of the private key means encrypted backups cannot be recovered. Store it carefully.

### What the provider sees

Once encryption is applied, the provider (Backblaze in this case) sees:

- Ciphertext: unreadable without the private key
- Metadata: file name, file size, upload timestamp

The file names include timestamps (e.g., `backup-20260323-030000.tar.gz.age`) but not vault contents. The provider cannot determine what is in your Obsidian vault.

---

## Retention

The off-site script lists remote files, sorts by name (timestamps are encoded in the filename), and deletes the oldest beyond `OFFSITE_RETAIN_COUNT`.

This is simple and correct for normal operation, but has a weakness: the same Pi that creates backups can also delete them. A compromised Pi, a misconfigured script, or operator error could prune remote history.

### Optional hardening: B2 Object Lock

Backblaze B2 supports Object Lock, which marks uploaded objects as undeletable until a configured retention date. With Object Lock enabled on the bucket, the retention deletion loop in the script will fail for locked objects (which is the desired behavior during the lock period). Set a retention window (e.g., 30 days) and set `OFFSITE_RETAIN_COUNT` high enough to accommodate it.

This makes the remote backup store tamper-resistant: even a fully compromised Pi cannot delete the locked copies.

See: https://www.backblaze.com/docs/cloud-storage-object-lock

---

## Decision Summary

| Question | Decision | Reason |
|---|---|---|
| Destination | Backblaze B2 | Headless-friendly, cheap, purpose-built, Object Lock available |
| Backup engine | tar.gz + age + rclone (v1) | Simple, understandable, builds on existing backup pattern |
| Encryption tool | age | No keyring/agent, unattended-safe, clean CLI |
| Encryption mandatory | Yes | Personal vault data must not be uploaded in plaintext |
| Remote-agnostic | Yes (rclone) | Same script works for B2, Drive, SFTP; configured via `.env` |
| v2 path | restic | Dedup, integrity checks, append-only mode when scale demands it |
