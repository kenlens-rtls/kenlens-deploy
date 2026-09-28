# KenLens — install bundle

KenLens is a real-time location system: UWB anchors report tag measurements over MQTT, and
KenLens turns them into live positions, zones and alerts in the browser. This bundle runs it
on one host with Docker Compose:

| Service | Image | Reached at |
|---|---|---|
| `kenlens-server` | `ghcr.io/kenlens-rtls/kenlens-server` | `https://<host>:8443` — the web UI, API and live updates |
| `mqtt-broker` | `eclipse-mosquitto:2.0` | `mqtts://<host>:8883` (TLS + password); `1883` only if you turn it on |
| `postgres` | `timescale/timescaledb:2.18.0-pg17` | Nowhere — the compose network only, TLS required |

Every image is public; no registry login is needed. Each release is a
[GitHub Release](https://github.com/kenlens-rtls/kenlens-deploy/releases) of this repository
with the bundle attached as `kenlens-deploy-vX.Y.Z.tar.gz`.

- [Before you start](#before-you-start)
- [Install](#install)
- [Trust the KenLens CA](#trust-the-kenlens-ca)
- [Point the anchors at the broker](#point-the-anchors-at-the-broker)
- [Upgrade](#upgrade)
- [Back up](#back-up)
- [Roll back](#roll-back)
- [Rotate a certificate or secret](#rotate-a-certificate-or-secret)
- [Uninstall](#uninstall)
- [Not supported yet](#not-supported-yet)
- [Troubleshooting](#troubleshooting)

## Before you start

**Host.** Any 64-bit Linux host that runs Docker, `amd64` or `arm64`. On a Raspberry Pi:

- a **Pi 4 or Pi 5 with at least 4 GB** of RAM — 8 GB is comfortable;
- **64-bit Raspberry Pi OS** — `uname -m` must print `aarch64`; there is no 32-bit image;
- an **SSD, not the SD card.** KenLens writes position history continuously, and an SD card
  wears out under that and is slow enough to hold the database back.

**Software.** Docker Engine with the Compose v2 plugin (`docker compose version` must work),
installed from [Docker's own packages](https://docs.docker.com/engine/install/) — the
distribution's `docker.io` package is often too old. Also `bash`, `openssl`, `curl` and `tar`,
which Raspberry Pi OS already has. Run everything below as a user in the `docker` group; the
setup script never needs `sudo`.

**Ports** the host must accept:

| Port | Protocol | Who connects |
|---|---|---|
| 8443 | HTTPS | Browsers |
| 8883 | MQTT over TLS | Anything that talks to the broker with the generated password |
| 1883 | MQTT, plain TCP, anonymous | Anchors, **only** while `MQTT_ANONYMOUS_LISTENER=true` — see [the anchors](#point-the-anchors-at-the-broker) |

**Decide two things first:**

1. **The name or address** browsers and anchors will use to reach the host — a DNS name, a
   fixed IP, or both. It goes into the certificates; a name that is not in them makes browsers
   and anchors refuse the connection. Give the host a fixed IP address (a DHCP reservation is
   enough) before you install.
2. **The tag height** — the height above the floor, in metres, at which tags are carried, in
   the same frame as your anchor survey. Positions are solved with the tag held at this
   height, so a guessed value makes every position wrong without any error. There is no
   default on purpose: measure it.

## Install

Install into a directory you will keep — the examples use `/opt/kenlens`. Docker Compose
names the database volume after the directory, so an upgrade must happen in the same place.

```bash
VERSION=v0.1.30   # the release you are installing — see the Releases page

sudo mkdir -p /opt/kenlens && sudo chown "$USER": /opt/kenlens
cd /opt/kenlens
curl -fsSLO "https://github.com/kenlens-rtls/kenlens-deploy/releases/download/${VERSION}/kenlens-deploy-${VERSION}.tar.gz"
tar -xzf "kenlens-deploy-${VERSION}.tar.gz" --strip-components=1
```

**Prepare the host.** The setup script asks for the host name(s) and the tag height:

```bash
./kenlens-setup.sh
```

or answers them from flags — repeat `--host` for every name and address:

```bash
./kenlens-setup.sh --host kenlens.example.lan --host 192.168.1.20 --tag-height 1.2
```

It creates a private **KenLens CA** and the certificates it signs (web, broker, database),
every password and key the stack uses, the broker's password file and `.env`. All of it lives
under `config/` and in `.env`, is made once, and is never overwritten by a later run — see
[rotating](#rotate-a-certificate-or-secret). `./kenlens-setup.sh --help` lists every option.

**Start it:**

```bash
docker compose up -d --wait
```

The first start pulls the images and creates the database; `--wait` returns once every service
is healthy. Then check readiness from the host, against the KenLens CA:

```bash
curl --cacert config/ca/kenlens-ca.crt https://kenlens.example.lan:8443/health/ready
```

`Healthy` means the server reaches both the database and the broker.

**First sign-in.** Browse to `https://<host>:8443`. A new installation asks you to **create the
first Admin** — KenLens ships no default account, and this page closes as soon as one user
exists. Sign in with it and follow the first-run wizard.

## Trust the KenLens CA

The web certificate is signed by the KenLens CA the setup script created, so until a machine
trusts that CA its browser warns on every visit. Copy `config/ca/kenlens-ca.crt` — the
**certificate** only, never `kenlens-ca.key` — to each machine that browses KenLens:

```bash
scp <user>@<host>:/opt/kenlens/config/ca/kenlens-ca.crt .
```

| Client | Where to import it |
|---|---|
| Windows (Edge, Chrome) | Open the file → **Install Certificate** → Local Machine → **Trusted Root Certification Authorities** |
| macOS (Safari, Chrome) | Keychain Access → System keychain → drag the file in → open it → **Trust: Always Trust** |
| Linux (Chrome, Chromium) | Settings → Privacy and security → Security → Manage certificates → Authorities → Import, tick *identifying websites* |
| Firefox (any OS) | Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import, tick *identifying websites* |
| Debian / Raspberry Pi OS command line | `sudo cp kenlens-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |

Restart the browser afterwards. The CA is valid for ten years and the web certificate for
825 days; renew the latter with `--rotate web` (see below) before it expires.

## Point the anchors at the broker

Anchors publish to the broker on this host; KenLens only ever reads from it. Configure each
anchor with this host's address as its MQTT broker.

**Today's anchor firmware connects anonymously, without TLS, to an IPv4 address.** It cannot
use port 8883, so it needs the anonymous listener on **1883**. That listener is off by
default; turn it on in `.env`:

```bash
MQTT_ANONYMOUS_LISTENER=true
```

then apply it with `docker compose up -d`. The broker log confirms it with
`serving anonymous plain-TCP MQTT on 1883 (insecure)`.

> **⚠️ Port 1883 is unauthenticated and unencrypted.** While it is on, anyone who can reach the
> host can read every anchor's traffic and publish forged measurements that KenLens will
> position. Turn it on only on a network you control, keep 1883 closed at any firewall between
> that network and anything else, and set it back to `false` once your anchors can connect
> over TLS.

Anchor firmware that supports TLS connects to **8883** with user `kenlens`, the password in
`config/secrets/mqtt-password`, and `config/ca/kenlens-ca.crt` as its trusted CA. The broker
certificate names the hosts you gave the setup script, so the anchor must use one of those.

## Upgrade

Every release is a new bundle and a new server image. Unpack the new bundle over the old one —
it contains no `config/`, `.env`, `data/` or `logs/`, so your certificates, secrets, settings
and floor plans are left alone — then point `.env` at the new version:

```bash
VERSION=v0.1.31   # the release you are upgrading to

cd /opt/kenlens
curl -fsSLO "https://github.com/kenlens-rtls/kenlens-deploy/releases/download/${VERSION}/kenlens-deploy-${VERSION}.tar.gz"
tar -xzf "kenlens-deploy-${VERSION}.tar.gz" --strip-components=1
sed -i "s/^KENLENS_VERSION=.*/KENLENS_VERSION=${VERSION}/" .env

docker compose pull
docker compose up -d --wait
```

The new server applies any database migration it carries when it starts. **Back up first**
(below): a migration is one-way, and it is what makes a later [rollback](#roll-back) need a
restore. Read the release notes for anything else the upgrade asks of you.

## Back up

Everything that makes this installation what it is lives in three places:

| What | Where | Why it matters |
|---|---|---|
| The database | Docker volume `<directory>_kenlens-postgres-data` — `kenlens_kenlens-postgres-data` for `/opt/kenlens` | Users, configuration, anchors, zones, position history, audit log |
| Floor-plan images | `data/` | The database stores only their file names |
| Certificates, secrets, settings | `config/` and `.env` | **`config/ca/kenlens-ca.key` cannot be recreated.** Losing it means issuing a new CA and trusting it again on every browser and anchor |

**Whole-installation backup.** Stop the stack so the database files are consistent, archive
them with the directory, and start it again:

```bash
cd /opt/kenlens
docker compose stop
sudo tar -czf ~/kenlens-backup-$(date +%F).tar.gz config .env data
docker run --rm -v kenlens_kenlens-postgres-data:/volume:ro -v ~:/backup alpine \
  tar -czf "/backup/kenlens-db-$(date +%F).tar.gz" -C /volume .
docker compose start
```

`sudo` is needed because some files under `config/` belong to the containers' users. Keep
both archives off the host — they contain every secret of the installation.

**Configuration-only backup.** An Admin can download a configuration archive from **Admin →
Configuration → Export** while KenLens runs. It holds the configuration, including floor-plan
images, but no position history, audit log, certificates or secrets — enough to rebuild on a
new host, not to restore this one exactly.

**Restoring the whole installation** onto a fresh install of the **same release**, in a
directory with the same name:

```bash
cd /opt/kenlens
docker compose down                  # stop, keep volumes
sudo tar -xzf ~/kenlens-backup-YYYY-MM-DD.tar.gz
docker run --rm -v kenlens_kenlens-postgres-data:/volume -v ~:/backup alpine \
  sh -c 'rm -rf /volume/* && tar -xzf /backup/kenlens-db-YYYY-MM-DD.tar.gz -C /volume'
docker compose up -d --wait
```

## Roll back

Rolling back is setting the previous `KENLENS_VERSION` in `.env` and restarting the server.
Release images are immutable, so this pulls exactly the bytes that ran before:

```bash
sed -i "s/^KENLENS_VERSION=.*/KENLENS_VERSION=v0.1.30/" .env
docker compose pull kenlens-server
docker compose up -d --wait kenlens-server
```

> **The migration caveat.** Migrations are never undone. If the release you are leaving
> changed the database schema, the older server does not understand the database it finds
> and fails to start — or worse, misreads it. Such a rollback needs the backup taken before the
> upgrade: [restore it](#back-up) with the older version in `.env`. Release notes say when a
> release carries a migration.

## Rotate a certificate or secret

The setup script replaces an item only when you name it:

```bash
./kenlens-setup.sh --rotate web                    # re-issue the web certificate
./kenlens-setup.sh --host new.name --host 192.168.1.20 --rotate web --rotate broker
docker compose up -d --force-recreate --wait       # containers read files at start
```

The second line changes the host names. The `--host` flags replace the old list rather than
adding to it, so name every host again.

Items are `ca`, `web`, `broker`, `postgres`, `db-password`, `jwt-key` and `mqtt-password`.

- **`ca`** re-issues every certificate with a new CA. Every browser and anchor that trusted
  the old one must be given the new one; the script asks you to type `rotate` first.
- **`db-password`** changes the file, but an existing database keeps the old password. The
  script prints the three commands that apply it; run them.
- **`jwt-key`** signs everyone out.
- **`mqtt-password`** must also be given to anything that connects to 8883 with it.

## Uninstall

```bash
cd /opt/kenlens
docker compose down          # removes the containers; keeps the database and broker volumes
docker compose down -v       # ...and deletes the database — every user, zone and position
sudo rm -rf /opt/kenlens     # certificates, secrets, settings, floor plans, logs
```

`down -v` and deleting the directory cannot be undone. [Back up](#back-up) first if there is
anything to keep.

## Not supported yet

- **Running behind your own reverse proxy**, on port 443, or with a public certificate such as
  Let's Encrypt. KenLens serves HTTPS on 8443 itself with the KenLens CA's certificate; a proxy
  in front of it is untested and unsupported for now.
- **Installing without internet access.** The images are pulled from `ghcr.io` and Docker Hub
  at install and upgrade time.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `docker compose up` stops at `set KENLENS_TAG_HEIGHT_METRES in .env` | The tag height was never set | Set it in `.env`, or re-run `./kenlens-setup.sh --tag-height <metres>` |
| `no matching manifest for linux/arm/v7` | A 32-bit OS | Reinstall with 64-bit Raspberry Pi OS |
| The browser warns about the certificate | The KenLens CA is not trusted, or the address is not one given to the setup script | [Trust the CA](#trust-the-kenlens-ca); use a listed name, or add it with `--host … --rotate web` |
| `/health/ready` says the database is unhealthy after a `--rotate db-password` | The database still has the old password | Run the commands the setup script printed |
| No anchor data arrives | Anchors cannot use 8883, and 1883 is off | [Turn on the anonymous listener](#point-the-anchors-at-the-broker); check `docker compose logs mqtt-broker` |
| Anything else | — | `docker compose ps`, then `docker compose logs <service>`; the server also writes daily log files to `logs/` |
