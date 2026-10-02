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
- [Give the anchors the time](#give-the-anchors-the-time)
- [Anchor console certificates](#anchor-console-certificates)
- [Use a broker you already run](#use-a-broker-you-already-run)
- [Upgrade](#upgrade)
- [Back up](#back-up)
- [Roll back](#roll-back)
- [Rotate a certificate or secret](#rotate-a-certificate-or-secret)
- [Reset the stored MQTT settings](#reset-the-stored-mqtt-settings)
- [Uninstall](#uninstall)
- [Not supported yet](#not-supported-yet)
- [Troubleshooting](#troubleshooting)

## Before you start

**Host.** Any 64-bit Linux host that runs Docker, `amd64` or `arm64`. On a Raspberry Pi:

- a **Pi 4 or Pi 5 with at least 4 GB** of RAM — 8 GB is comfortable. The stack itself needs
  about 500 MB: it has run on a 1 GB Pi 3, which is enough to try KenLens but leaves no room
  for a site's worth of position history;
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
| 8883 | MQTT over TLS | Anchors with a username and password, and anything else with a broker account |
| 1883 | MQTT, plain TCP, anonymous | Anchors, **only** while the anonymous listener is on — see [the anchors](#point-the-anchors-at-the-broker) |
| 123 | NTP (UDP) | Anchors, to set their clocks — see [the time](#give-the-anchors-the-time). Nothing else on the host may already serve NTP |

**Decide two things first:**

1. **The name or address** browsers and anchors will use to reach the host — a DNS name, a
   fixed IP, or both. It goes into the certificates; a name that is not in them makes browsers
   and anchors refuse the connection. Give the host a fixed IP address (a DHCP reservation is
   enough) before you install.
2. **Your site's DNS domain**, if anchors should also be reachable as
   `kenlens-anchor-xxxx.<domain>` and not only as `kenlens-anchor-xxxx.local`. Usually nothing to
   decide: the setup script uses the domain this host was given by DHCP, and `--domain` or
   `--no-domain` overrides it. See [anchor console certificates](#anchor-console-certificates).
3. **The tag height** — the height above the floor, in metres, at which tags are carried, in
   the same frame as your anchor survey. Positions are solved with the tag held at this
   height, so a guessed value makes every position wrong without any error. There is no
   default on purpose: measure it.

## Install

Install into a directory you will keep — the examples use `/opt/kenlens`. Docker Compose
names the database volume after the directory, so an upgrade must happen in the same place.

```bash
# The latest release, or set VERSION=vX.Y.Z by hand for another one from the Releases page.
VERSION=$(curl -fsSL https://api.github.com/repos/kenlens-rtls/kenlens-deploy/releases/latest \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
echo "$VERSION"

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
./kenlens-setup.sh --host kenlens.example.lan --host 192.168.1.20 --domain example.lan --tag-height 1.2
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
| Linux (Chrome, Chromium, Brave) | Settings → Privacy and security → Security → Manage certificates → Local certificates → Installed by you → **Trusted certificates** → Import. Older versions: Manage certificates → Authorities → Import, tick *identifying websites* |
| Firefox (any OS) | Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import, tick *identifying websites* |
| Debian / Raspberry Pi OS command line | `sudo cp kenlens-ca.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates` |

Import it as a **trusted** or **root** certificate authority. As an *intermediate* certificate the
page still loads but the browser keeps marking it "Not secure", because nothing trusts the chain's
root. The file holds no key, so importing it never asks for a password; a password prompt means
the import went to *Your certificates*, which is for a personal certificate and its key.

Restart the browser afterwards. The CA is valid for ten years; the web and broker certificates
for 825 days. Renew them with `--rotate web` and `--rotate broker` (see below) before they
expire. **Configuration → MQTT broker** shows when the broker's certificate and the CA expire,
and marks them 60 days before.

## Point the anchors at the broker

Anchors publish to the broker on this host; KenLens only ever reads from it. Anchor firmware
0.4.0 and later connects to **8883** over TLS with a username and password, which is the way to
set anchors up. Each anchor is configured from its own web console, on its **Config** tab: the
**MQTT broker** section takes the broker address, port, TLS and credential, and the **KenLens
certificates** section takes the certificate bundle.

In KenLens, **Configuration → MQTT broker** shows under *Setting up an anchor* the address, port
and TLS setting to enter on the anchor, and **Get certificates bundle** downloads
`kenlens-anchor-bundle.pem` to upload to it (the same button is on **Configuration → Devices**).
The bundle needs no login, so it can also be fetched directly from
`https://<host>:8443/api/mqtt/anchor-bundle`. On this bundled broker it holds the KenLens CA; it
is always exactly the set of certificates KenLens itself trusts for its broker.

**The broker address must be an IP address or a name in the site's DNS, and it must be one of
the `--host` values you gave the setup script.** The broker certificate names only those hosts.
An anchor cannot look up a `.local` name: it answers to its own `kenlens-anchor-xxxx.local`, but
it resolves the broker through the DNS server its DHCP lease names.

The username and password are an **anchor credential**. Create one on the same page, under
*Anchor credentials*: KenLens chooses the password and shows it once, to copy into the anchor.
Several anchors may share a credential, or each may have its own. The broker accepts exactly
the credentials listed there — **Rotate** gives one a new password and **Remove** deletes it,
both at once, and anchors using the old one are disconnected. Credentials may only publish
anchor data and read anchor configuration jobs. The broker's own users are managed by KenLens
alone; there is no password file to edit on the host. A username may be at most 63 characters,
because that is all an anchor stores.

### Anchor firmware older than 0.4.0

Older firmware connects anonymously, without TLS, to an IPv4 address. It cannot use port 8883,
so it needs the anonymous listener on **1883**. That listener is off by default. Turn it on in
KenLens under **Configuration → MQTT broker → Bundled broker → Insecure anonymous listener**:
the broker follows within seconds, with no restart, and KenLens checks that it did. Turning it
off there disconnects every anchor still using 1883.

`MQTT_ANONYMOUS_LISTENER` in `.env` is only the listener's state on the first start. After
that the switch on the page wins, and editing `.env` changes nothing.

> **⚠️ Port 1883 is unauthenticated and unencrypted.** While it is on, anyone who can reach the
> host can read every anchor's traffic and publish forged measurements that KenLens will
> position. Turn it on only on a network you control, keep 1883 closed at any firewall between
> that network and anything else, and turn it off once your anchors can connect over TLS.

## Give the anchors the time

Anchor firmware 0.7.0 and later checks the dates on the broker's certificate, and so refuses an
expired one, **only once its clock is set**. Its one time source is NTP on the host it uses as
the broker: this host, on UDP 123. The stack's `ntp` service answers there. Until an anchor gets
an answer it still connects, without checking the dates, and its console reports
`"clock":{"synced":false}` under `/api/status`.

Where the time comes from:

- **With Internet access**, from the public `pool.ntp.org` servers.
- **From the site's own time servers**: put a file ending in `.sources` in `config/ntp/`, with a
  line per server, then reload it. Upgrades leave `config/ntp/` alone.

  ```bash
  echo 'server ntp.example.lan iburst' > config/ntp/site.sources
  docker compose exec ntp chronyc reload sources
  ```

- **With neither**, from this host's own clock. Anchors accept that time, so it has to be right.
  **A Raspberry Pi has no battery-backed clock**: after it has been switched off, it starts at the
  last time it saved, and serves that time to the anchors as if it were correct. On an isolated
  site, give a Pi an RTC module, or give it a time server to follow.

The `ntp` service never sets this host's clock. Keep that clock right the usual way;
Raspberry Pi OS does it with `systemd-timesyncd` when it has a time server to reach.

To see what anchors are given, look at the first two lines of `docker compose exec ntp chronyc
tracking`. A reference ID of `7F7F0101` at stratum 10 means the service is serving this host's
own clock. `/health/ready` reads `Degraded` while that lasts, or while nothing answers on 123.

## Anchor console certificates

Each anchor's console, its web page at `https://kenlens-anchor-xxxx.local`, starts with a
self-signed certificate. Browsers warn about it, and Safari on iPhone and iPad may refuse it
outright. With anchor firmware **0.9.0 or later**, KenLens replaces it with a certificate signed
by the KenLens CA and renews it before it expires, over MQTT, with nothing to do. Once a browser
[trusts the KenLens CA](#trust-the-kenlens-ca), it opens anchor consoles with no warning too. The
anchor must already have the [certificates bundle](#point-the-anchors-at-the-broker), which is how
it knows a certificate from KenLens is genuine.

**Configuration → Devices** shows, for each anchor, which certificate its console serves and what
KenLens is doing about it. **Re-issue now** there sends it a new one at once; use it for an anchor
serving a certificate from another KenLens server, which is otherwise left alone until it nears
expiry. **Configuration → MQTT broker → Anchor console certificates** says
whether KenLens can issue them at all.

**What this asks you to trust.** Issuing certificates without you means the server holds a key
that can sign them. It is not the KenLens CA's key, which never leaves `config/ca/`. It is the key of
a second CA the setup script makes under it, `config/anchor-ca/`, which is **name-constrained**:

- it may sign only names under `.local` and the site domains you gave with `--domain`;
- it may sign no IP address at all.

So whoever steals the server's key gets certificates for this site's anchor names, and for no other
website. The constraint was checked on 2026-10-01: a certificate outside it is refused by Chrome
154, Chromium 153, Brave 1.96 and Firefox 148, and by `openssl verify`. **Safari was not checked.**
Until it is, assume a Mac or iPhone may not enforce the constraint.

**Names, not addresses.** An anchor's certificate names it, never its IP address. An anchor moved
to a new address by DHCP keeps a working certificate, and its console opens with no warning at its
name; browsing to its IP address still warns. `.local` names work on the anchors' own network
segment. Across routers, or for phones that do not resolve `.local`, give the setup script your site
domain: anchors send their name in their DHCP request, so a router that registers DHCP names in DNS
makes `kenlens-anchor-xxxx.example.lan` resolve. The setup script constrains the anchor console CA
to the domain this host was given by DHCP (the `domain` or `search` line of `/etc/resolv.conf`),
unless `--domain` names others or `--no-domain` asks for `.local` only, and every domain the CA
permits goes into every anchor's certificate with nothing to do. Each anchor's entry on the Devices
page says whether its names resolve from the KenLens host.

**Adding or removing a site domain is done on the MQTT page**, under **Anchor console
certificates**: untick one to stop using it, or type one in and save. KenLens cannot widen the anchor
console CA itself, since that takes the KenLens CA's key, which never leaves the host. A domain the
CA does not permit yet is therefore shown as *pending*, with the two commands that permit it, to run
on the host in the install directory. Nothing has to be trusted again, because the KenLens CA does
not change. For example:

```bash
./kenlens-setup.sh --rotate anchor-ca --domain example.lan --domain other.example
docker compose up -d --force-recreate --wait kenlens-server
```

The page lists every domain in that command, because `--domain` replaces the set rather than adding
to it. The same panel spells out what to run whenever KenLens cannot issue at all: no anchor console
CA, one about to expire, or a KenLens CA too old to have one.

**An install made before anchor console certificates existed** has a KenLens CA that cannot have a
CA under it. The setup
script says so and makes no anchor console CA, and anchors keep their self-signed certificates. To
have KenLens issue them, re-create the CA with `--rotate ca` (see [below](#rotate-a-certificate-or-secret)):
every browser and anchor then has to be given the new `kenlens-ca.crt`.

**Who can ask for one.** An anchor asks for a certificate by publishing on the broker. While the
[insecure anonymous listener](#anchor-firmware-older-than-040) is on, anyone on the network can
publish there, and so can anyone with an anchor credential. KenLens issues only to an anchor that
has reported its configuration, only for a name of the form `kenlens-anchor-xxxx`, and never for a
name it has already issued to another anchor. Someone who can publish could still obtain a
certificate for an anchor name no anchor has claimed yet. Keep the anonymous listener off once your
anchors connect over TLS.

## Use a broker you already run

**Configuration → MQTT broker** points KenLens at another broker: host or IP, port, TLS,
anonymous or username and password. If that broker's certificate is not signed by a public CA,
upload its CA (and any intermediates) there as a PEM file. **Test connection** tries the
settings without saving them; **Save and reconnect** tests again and only saves on success,
unless you choose **Save anyway**. The change takes effect at once, without a restart, and the
certificates you upload are what anchors get as their bundle. **Use the bundled broker** on the
same page goes back to the broker installed with KenLens.

Anchors accept a narrower bundle than KenLens does: one to four **CA** certificates, all
**ECDSA P-256**, 3 072 bytes at most. An anchor refuses the whole upload otherwise, so the MQTT
page says under *Setting up an anchor* when the certificates you uploaded break one of those
rules. Anchors have no public trust store either: a broker whose certificate comes from a public
CA can be used by KenLens, but not by anchors.

## Upgrade

Every release is a new bundle and a new server image. Unpack the new bundle over the old one —
it contains no `config/`, `.env`, `data/` or `logs/`, so your certificates, secrets, settings
and floor plans are left alone — then point `.env` at the new version:

```bash
# The latest release, or set VERSION=vX.Y.Z by hand.
VERSION=$(curl -fsSL https://api.github.com/repos/kenlens-rtls/kenlens-deploy/releases/latest \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
echo "$VERSION"

cd /opt/kenlens
curl -fsSLO "https://github.com/kenlens-rtls/kenlens-deploy/releases/download/${VERSION}/kenlens-deploy-${VERSION}.tar.gz"
tar -xzf "kenlens-deploy-${VERSION}.tar.gz" --strip-components=1
sed -i "s/^KENLENS_VERSION=.*/KENLENS_VERSION=${VERSION}/" .env
./kenlens-setup.sh --non-interactive   # adds anything the new release needs; replaces nothing

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
| Floor-plan images and the key ring | `data/` | The database stores only the images' file names. `data/keys/` holds the keys the stored MQTT password is encrypted with |
| Certificates, secrets, settings | `config/` and `.env` | **`config/ca/kenlens-ca.key` cannot be recreated.** Losing it means issuing a new CA and trusting it again on every browser and anchor. `config/dataprotection/` encrypts `data/keys/` |

The database, `data/keys/` and `config/dataprotection/` belong together: restored without either
of the other two, the database comes back with an MQTT password and anchor credentials nothing
can decrypt. The server stays off the broker until you
[reset the stored MQTT settings](#reset-the-stored-mqtt-settings), and each anchor credential must
be rotated.

The broker's volume, `<directory>_kenlens-mosquitto-data`, needs no backup of its own. It holds
the broker's users, and KenLens re-creates every one of them from the database each time it
starts — a lost broker volume comes back as soon as the server does.

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

Items are `ca`, `anchor-ca`, `web`, `broker`, `postgres`, `db-password` and `jwt-key`.

- **`ca`** re-issues every certificate with a new CA, the anchor console CA included. Every
  browser and anchor that trusted the old one must be given the new one; the script asks you to
  type `rotate` first.
- **`anchor-ca`** re-creates the [anchor console CA](#anchor-console-certificates), with the
  `--domain` values given, or else the ones it had. Nothing has to be trusted again; KenLens
  re-issues every anchor's certificate.
- **`db-password`** changes the file, but an existing database keeps the old password. The
  script prints the three commands that apply it; run them.
- **`jwt-key`** signs everyone out.
`config/secrets/mqtt-admin-password` is not an item either: the broker keeps the admin password
it was first started with, and KenLens manages the broker's users with it.

There is no `mqtt-password`. The server makes up the password of its own broker user on its first
start and keeps it, encrypted, with its MQTT settings; **Use the bundled broker** on the MQTT
settings page gives it a new one. An install from before that may still have
`config/secrets/mqtt-password`: nothing reads it, and it can be deleted.

There is no item for `config/dataprotection/`. Replacing it would make every key in
`data/keys/` unreadable, and with them the stored MQTT password.

## Reset the stored MQTT settings

The server keeps its MQTT settings — broker, port, TLS, user and password — in the database, and
nothing in `.env`, `docker-compose.yml` or `config/` changes them. On its first start, with none
stored, it stores the bundled broker: `mqtt-broker` on 8883 over TLS, as user `kenlens` with a
password it makes up and gives that user. Deleting them makes the next start do that again:

```bash
cd /opt/kenlens
docker compose exec postgres psql -U kenlens -d kenlens -c 'DELETE FROM mqtt_settings'
docker compose up -d --force-recreate --wait kenlens-server
```

You rarely need this: **Configuration → MQTT broker** changes every one of these settings
while the server runs, and **Use the bundled broker** there goes back to the bundled broker with
a new password. Resetting is for when that page cannot be reached. It is also a way back when the
stored password can no longer be decrypted — **Use the bundled broker**, or entering the password
again on that page, are the others.

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
| The first `docker compose up -d --wait` fails, and later starts are healthy | The database's first start was interrupted, and PostgreSQL finishes its setup only once | On a new installation with nothing to keep: `docker compose down -v`, then `docker compose up -d --wait` again. `docker compose logs postgres` shows why it stopped |
| `no matching manifest for linux/arm/v7` | A 32-bit OS | Reinstall with 64-bit Raspberry Pi OS |
| The server log says the stored MQTT password cannot be decrypted, and anchors never appear | `data/keys/` or `config/dataprotection/` was lost or replaced | Restore both from the same backup, or enter the MQTT password again on **Configuration → MQTT broker** |
| The browser warns about the certificate | The KenLens CA is not trusted, or the address is not one given to the setup script | [Trust the CA](#trust-the-kenlens-ca); use a listed name, or add it with `--host … --rotate web` |
| `/health/ready` says the database is unhealthy after a `--rotate db-password` | The database still has the old password | Run the commands the setup script printed |
| No anchor data arrives | Anchors cannot use 8883, and 1883 is off; or a TLS anchor's credential was rotated or removed | [Turn on the anonymous listener, or give the anchor a credential](#point-the-anchors-at-the-broker); check `docker compose logs mqtt-broker` |
| The `ntp` service will not start: `address already in use` on port 123 | The host already runs an NTP server (chronyd, ntpd) | Stop and disable it, then `docker compose up -d --wait`. `systemd-timesyncd` does not conflict |
| An anchor's console shows `"clock":{"synced":false}` | Nothing answers it on UDP 123 at the broker address | Check the [`ntp` service](#give-the-anchors-the-time), and open UDP 123 in any firewall between the anchors and this host |
| The broker will not start, and its log names `mqtt-admin-password` | An installation set up by an older release has no broker admin password | `./kenlens-setup.sh --non-interactive`, then `docker compose up -d --wait` |
| Anything else | — | `docker compose ps`, then `docker compose logs <service>`; the server also writes daily log files to `logs/` |
