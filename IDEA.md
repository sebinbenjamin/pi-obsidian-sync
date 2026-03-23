# Obsidian LiveSync Self-Hosted Setup Plan

**Raspberry Pi + CouchDB + Tailscale + Trusted HTTPS + Android-safe rollout**

## 1. Purpose

Set up a **self-hosted Obsidian sync system** using:

- Raspberry Pi as the always-on server
- Dockerized CouchDB as the LiveSync backend
- Tailscale for private connectivity
- a **trusted HTTPS endpoint** on the Pi’s stable DNS name
- Obsidian **Self-hosted LiveSync** plugin
- plugin **setup wizard / setup URI**
- **Request API** fallback if Android or CORS issues appear

This plan is designed to maximise the chances of **Android working reliably**, based on the issues and documentation we reviewed.

---

## 2. Why this architecture

## Truth

A plain Pi + CouchDB setup is **not enough** for Android.

What we learned:

- Android cannot reliably use a plain `http://` endpoint.
- Android also cannot reliably use a **self-signed certificate**.
- A **trusted HTTPS endpoint** is required.
- Even with trusted HTTPS, there can still be issues related to:
  - CORS
  - proxy configuration
  - redirects
  - mobile/WebView or local DB behaviour

- The plugin’s own docs recommend:
  - **setup wizard / setup URI**
  - **Use Request API** if needed to work around CORS/fetch problems

## Nuance

Trusted HTTPS is **necessary but not sufficient**.

So the plan must reduce risk across all of these layers:

- transport security
- DNS consistency
- proxy simplicity
- CORS correctness
- careful phased rollout
- Android-first risk mitigation
- backups before trusting production notes

## Decision

We will use:

- **Pi**
- **Docker CouchDB**
- **Tailscale**
- **trusted HTTPS endpoint on a stable DNS name**
- **simple routing**
- **no public internet exposure**
- **desktop-first test vault rollout**
- **Android second**
- **Request API only if needed**

---

## 3. Target architecture

```text
Obsidian Desktop / Android
        |
        | HTTPS
        v
Trusted stable DNS endpoint
(on Pi, reachable over Tailscale)
        |
        v
Reverse proxy / HTTPS termination
        |
        v
CouchDB container on Raspberry Pi
        |
        v
Persistent Docker volume / SSD storage
```

### Principles

- Do not expose CouchDB directly to the public internet
- Do not use self-signed certificates
- Do not use plain HTTP for Android
- Keep routing simple
- Avoid subpath routing if possible
- Use one clean hostname for the sync endpoint
- Keep the first version boring and predictable

---

## 4. Goals

## Primary goals

- Reliable sync between:
  - Android phone
  - Windows 11 laptops
  - Ubuntu laptops

- Always-on backend on Raspberry Pi
- Secure private access
- Trusted HTTPS endpoint for Android compatibility
- Reproducible setup using setup URI
- Backed-up server data

## Secondary goals

- Minimal operational complexity
- Easy onboarding of additional devices
- Easy rollback if sync issues appear
- Clear validation path before using real vault

---

## 5. Non-goals for v1

We will **not** aim for these in v1:

- public internet access without Tailscale
- complex public reverse proxy chains
- Cloudflare in front of sync endpoint
- domain-wide routing experiments
- multiple reverse proxies
- subdirectory-based endpoint mapping
- migrating the real vault before validation
- mixing LiveSync with another sync method on the same vault

---

## 6. Main risks

## Known risks

### 1. Android transport constraints

Android requires:

- trusted HTTPS
- no self-signed cert
- no plain HTTP

### 2. CORS / proxy configuration

Even with HTTPS, sync may fail if:

- proxy rewrites headers incorrectly
- proxy handles CORS instead of CouchDB
- redirects are introduced
- host forwarding is wrong

### 3. Mobile-specific behaviour

Android may still show:

- “Failed to fetch”
- incomplete sync
- intermittent failures
- local storage / IndexedDB style issues

### 4. Data integrity risk

Like any sync system:

- bad config can produce conflicts
- plugin bugs or restore bugs may surface
- first sync on a real vault is risky without testing

### 5. Operational complexity

This is a power-user setup, not a consumer appliance setup.

---

## 7. Project phases

## Phase 0: Preparation

### Deliverables

- Pi available and stable
- Docker already installed
- Tailscale already installed
- storage path decided
- backup path decided
- test vault ready

### Tasks

- confirm Pi hostname
- confirm Tailscale connectivity from all client devices
- confirm Pi has enough storage
- prefer SSD over SD card if possible
- create a dedicated project folder, e.g.:

```bash
/srv/obsidian-livesync
```

### Exit criteria

- Pi is reachable over Tailscale
- Docker works
- stable DNS name is known
- backup target exists

---

## Phase 1: CouchDB deployment

### Goal

Deploy a clean CouchDB backend on the Pi.

### Tasks

- create `docker-compose.yml`
- create persistent storage volume
- use strong admin credentials
- start CouchDB container
- validate container health locally

### Suggested directory layout

```text
/srv/obsidian-livesync/
  docker-compose.yml
  data/
  backups/
```

### Example compose file

```yaml
version: "3.8"

services:
  couchdb:
    image: couchdb:3
    container_name: obsidian-couchdb
    restart: unless-stopped
    environment:
      COUCHDB_USER: obsidian_admin
      COUCHDB_PASSWORD: change-this-to-a-long-random-password
    volumes:
      - ./data:/opt/couchdb/data
    ports:
      - "5984:5984"
```

### Validation

- `docker ps`
- local access to CouchDB
- persistent storage mounted
- restart test passes

### Exit criteria

- CouchDB is running
- local access works
- data survives restart

---

## Phase 2: Trusted HTTPS endpoint on stable DNS name

### Goal

Provide a **trusted HTTPS endpoint** suitable for Android.

## Key requirement

This is mandatory for Android compatibility.

### Design requirements

- stable DNS name
- trusted certificate
- simple route
- no redirect loops
- no subpath complexity if avoidable

### Recommended shape

Use a dedicated hostname for sync, for example:

```text
https://obsidian-sync.<stable-domain-or-tailnet-name>
```

or equivalent stable DNS name that resolves consistently for all devices.

### Rules

- no self-signed cert
- no raw `http://`
- avoid certificate mismatch
- avoid connecting via bare IP if certificate is for hostname
- keep endpoint shape stable from day one

### Validation

From desktop and Android:

- open the HTTPS URL in browser
- verify no cert warning
- verify certificate is trusted
- verify no redirect loop

### Exit criteria

- Android browser can open endpoint over HTTPS
- no cert warnings
- stable DNS name confirmed

---

## Phase 3: Reverse proxy and request path hardening

### Goal

Make the path between client and CouchDB predictable.

### Principles

- keep proxy logic minimal
- do not add unnecessary layers
- no Cloudflare in front for v1
- no subpath routing if avoidable
- avoid path rewriting tricks

### CORS strategy

Important:

- **CouchDB should handle CORS**
- reverse proxy should not become the CORS authority
- preserve:
  - `Host`
  - `X-Forwarded-For`

- avoid mishandling `OPTIONS`

### Request API strategy

Use **normal mode first** if setup is clean.

Enable **Request API** if:

- Android gets “Failed to fetch”
- CORS errors appear
- behaviour differs between browser and plugin
- desktop works but Android does not

### Exit criteria

- HTTPS endpoint works without browser issues
- no redirect loops
- path is stable and simple

---

## Phase 4: Desktop test vault rollout

### Goal

Prove the stack works on desktop before Android.

### Tasks

- create a small throwaway Obsidian vault
- install Self-hosted LiveSync plugin on one desktop
- use plugin **setup wizard**
- connect to the trusted HTTPS endpoint
- complete initial sync

### Rules

- do not use the real vault yet
- do not configure multiple devices yet
- do not enable additional sync tools on this vault

### Validation tests

- create a note
- edit a note
- rename a note
- create nested folders
- move notes between folders
- attach an image/file
- restart Obsidian and verify state
- restart Pi and verify sync still works

### Exit criteria

- desktop sync is stable
- no unexplained errors
- nested folders and attachments behave correctly

---

## Phase 5: Setup URI generation

### Goal

Use setup URI to reduce configuration errors on additional devices.

### Tasks

- once desktop is stable, generate the plugin setup URI
- store it securely
- document how to reuse it for new devices

### Rules

- do not hand-configure every device from scratch unless necessary
- use the same canonical configuration

### Exit criteria

- setup URI available
- setup can be repeated consistently

---

## Phase 6: Android test vault rollout

### Goal

Validate Android behaviour before using real notes.

### Tasks

- install Obsidian on Android
- open the same small test vault pattern locally
- install LiveSync plugin
- configure using setup URI
- connect to trusted HTTPS endpoint
- test initial sync

### Validation tests

- sync existing notes from desktop
- create a note on Android and verify desktop receives it
- edit a note on Android and verify desktop receives it
- create nested folder and note
- attach a small file
- close and reopen app
- test over Wi-Fi
- test over mobile data if relevant
- test after phone sleep / wake
- test after Pi restart

### Failure-response plan

If Android fails:

1. verify endpoint opens in Android browser
2. confirm cert is trusted
3. confirm hostname matches certificate
4. check proxy / redirects
5. check CouchDB CORS config
6. enable **Request API**
7. retest
8. inspect logs

### Exit criteria

- Android can sync test vault reliably
- no repeated fetch failures
- no missing subfolders or partially restored vault state

---

## Phase 7: Multi-device rollout

### Goal

Add the rest of your laptops after desktop + Android are proven.

### Tasks

- onboard one additional device at a time
- use setup URI
- test basic sync after each addition

### Rules

- no mass onboarding
- validate each device before adding the next
- avoid simultaneous heavy editing during rollout

### Exit criteria

- all intended devices connected
- all pass the basic sync validation set

---

## Phase 8: Real vault migration

### Goal

Move from test vault to production vault safely.

### Preconditions

All earlier phases must be green.

### Tasks

- back up current real vault
- back up Pi-side CouchDB data
- create a restore point
- onboard real vault through the validated workflow
- monitor carefully for several days

### Rules

- do not migrate without verified backups
- do not edit the same note on multiple devices during the first few days
- do not add unrelated plugin experiments at the same time

### Exit criteria

- production vault syncs correctly across devices
- no unexplained missing files
- no repeated Android failures
- restore plan tested or at least documented

---

## 8. Validation checklist

## Infrastructure validation

- [ ] Pi stable
- [ ] Docker persistent
- [ ] CouchDB restarts cleanly
- [ ] storage persists
- [ ] Tailscale connectivity works from all devices
- [ ] stable DNS name chosen
- [ ] HTTPS certificate trusted
- [ ] no redirect loop
- [ ] no certificate mismatch

## Desktop validation

- [ ] initial sync works
- [ ] note create/edit/delete works
- [ ] folders sync correctly
- [ ] attachments sync correctly
- [ ] restart survives
- [ ] reconnection after Pi restart works

## Android validation

- [ ] endpoint opens in browser
- [ ] no cert warning
- [ ] initial sync completes
- [ ] note create/edit/delete works
- [ ] folders sync correctly
- [ ] attachments sync correctly
- [ ] sleep/wake does not break sync
- [ ] app restart survives
- [ ] no repeated fetch failure
- [ ] Request API tested if needed

## Production readiness validation

- [ ] backups configured
- [ ] restore procedure documented
- [ ] setup URI stored securely
- [ ] real vault backup taken before migration

---

## 9. Backup plan

## Principle

Sync is not backup.

### Back up these things

- CouchDB data directory / Docker volume
- exported or copied Obsidian vault
- important setup details:
  - hostname
  - credentials
  - setup URI
  - encryption keys/secrets if applicable

### Minimum backup strategy

- nightly backup of `/srv/obsidian-livesync`
- retain several historical copies
- optional copy to another machine or disk

### Example approach

- tarball backup
- rsync to another host
- snapshot if storage supports it

### Backup success criteria

- backups run automatically
- at least one restore drill is documented
- critical secrets are stored securely

---

## 10. Security plan

### Requirements

- strong CouchDB admin password
- trusted HTTPS only
- no public raw port exposure
- no router port-forward to CouchDB
- Tailscale for private access
- minimal proxy surface
- principle of least exposure

### Avoid

- self-signed certificates
- plain HTTP
- public unauthenticated CouchDB
- exposing port 5984 directly to the open internet

---

## 11. Troubleshooting flow

## Symptom: Android browser opens endpoint, plugin still fails

Possible causes:

- CORS
- Request API needed
- redirect/proxy issue
- plugin-side fetch behaviour
- local mobile DB state issue

Actions:

1. enable Request API
2. verify no redirect chain
3. confirm CouchDB handles CORS
4. inspect logs
5. retry with clean test vault

## Symptom: Desktop works, Android does not

Possible causes:

- Android HTTPS/cert trust edge
- plugin fetch path issue
- mobile storage state issue

Actions:

1. re-check hostname and cert match
2. enable Request API
3. re-test on small clean vault
4. compare logs between desktop and phone

## Symptom: Initial restore incomplete or folders missing

Possible causes:

- onboarding/restore issue
- interrupted first sync
- plugin state problem

Actions:

1. stop rollout
2. discard broken test vault
3. retry from clean state
4. confirm completion before further testing

## Symptom: intermittent failures after it once worked

Possible causes:

- mobile local DB problems
- network instability
- proxy redirect issue
- server restart handling issue

Actions:

1. test with one desktop + Android only
2. reduce variables
3. inspect container logs
4. inspect plugin logs
5. validate after restart cycle

---

## 12. Project decisions

## Decision 1

Use **trusted HTTPS** from day one.

Reason:
Android requires it.

## Decision 2

Use **stable DNS hostname**, not ad hoc IP-based access.

Reason:
certificate trust and consistency.

## Decision 3

Use **desktop-first rollout**.

Reason:
reduces debugging complexity.

## Decision 4

Use **small test vault before real vault**.

Reason:
data safety.

## Decision 5

Use **setup wizard / setup URI**.

Reason:
fewer config mistakes.

## Decision 6

Use **Request API only if needed**, not blindly from the start.

Reason:
keep setup simple, but have a documented fallback ready.

## Decision 7

Do **not** stack Cloudflare or extra public proxy layers in v1.

Reason:
reduces redirect and CORS complexity.

---

## 13. Definition of done

This project is done when:

- CouchDB runs reliably on the Pi
- sync endpoint is reachable on a **trusted HTTPS stable DNS name**
- desktop test vault works reliably
- Android test vault works reliably
- Request API fallback path is understood and tested if required
- additional laptops can be onboarded using setup URI
- backups are configured
- real vault migration completes without data loss
- no major recurring sync issues appear during the monitoring period

---

## 14. Immediate next actions

1. Create project folder on Pi
2. Deploy CouchDB container
3. Validate local CouchDB health
4. Create the trusted HTTPS endpoint on stable DNS name
5. Verify Android browser trust
6. Create desktop test vault
7. Install LiveSync and use setup wizard
8. Validate desktop sync
9. Generate setup URI
10. Add Android test vault
11. Enable Request API only if needed
12. Roll out to remaining devices
13. Migrate real vault only after successful validation

---

## 15. Final recommendation

The safest path is:

**boring infrastructure, trusted HTTPS, simple routing, desktop-first validation, Android second, real vault last.**

That gives you the best chance of making **LiveSync on Android** work without turning the setup into a fragile experiment.
