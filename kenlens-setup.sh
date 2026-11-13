#!/usr/bin/env bash
# KenLens host setup.
#
# Prepares this directory for `docker compose up -d`: a private KenLens CA, the three
# certificates it signs, the name-constrained CA the server signs anchor consoles with, every
# secret the stack reads and `.env`. Run it once per host, from anywhere; it always works on the directory it lives in.
#
#   ./kenlens-setup.sh                                   # asks for what it needs
#   ./kenlens-setup.sh --host kenlens.lan --host 192.168.1.20 --https-port 443 \
#                      --non-interactive                 # CI, or a scripted install
#   ./kenlens-setup.sh --rotate broker                   # re-issue one item
#   ./kenlens-setup.sh --update latest                   # upgrade to a release (or --update vX.Y.Z)
#   ./kenlens-setup.sh --version                         # the release installed here
#   ./kenlens-setup.sh --restore backups/kenlens-<time>-<release> --key <file>
#                                                        # put a scheduled backup back, and check it
#
# Options:
#   --host <name|ip>     A name or IPv4/IPv6 address browsers and anchors use to reach this
#                        host. Repeat for several. Goes into the web and broker certificates
#                        and is remembered in .env as KENLENS_HOST.
#   --domain <dns>       A site DNS domain anchors are also reached under (e.g. asgard.qc.ca);
#                        repeat for several. Anchor console certificates may name only
#                        <host>.local and <host>.<domain>: the anchor console CA is constrained
#                        to them. Remembered in .env as KENLENS_ANCHOR_DOMAINS. Changing them
#                        later takes --rotate anchor-ca. Without --domain, the domain this host
#                        was given by DHCP (/etc/resolv.conf `domain` or `search`) is used;
#                        KenLens's MQTT page shows the exact command to change it.
#   --no-domain          Constrain anchor console certificates to <host>.local only: no
#                        site domain, detected or stored.
#   --https-port <n>     The port browsers connect to; 8443 unless given, asked for on a fresh
#                        install. Only the host side of the mapping: inside the container the
#                        server always listens on 8443. Remembered in .env as KENLENS_HTTPS_PORT;
#                        to change it later run --https-port again, then docker compose up -d.
#   --tag-height <m>     Select the planar fallback: hold every tag at this height, in metres
#                        (KENLENS_TAG_HEIGHT_METRES). Without it tags are solved in three
#                        dimensions, which needs anchors mounted at least 1 m above the highest
#                        tagged object. To go back to 3D, remove the line from .env.
#   --version            Alone, with no value: print the release installed here (the
#                        KENLENS_VERSION .env pins) and exit; nothing else on the line runs.
#   --version <vX.Y.Z>   On a fresh install, the release .env pins. Defaults to the one in
#                        .env.example.
#   --rotate <item>      Replace one existing item; repeatable. Items: ca, anchor-ca, web,
#                        broker, postgres, db-password, jwt-key. Rotating `ca`
#                        re-issues every certificate with it. Rotating `anchor-ca` re-issues
#                        only the anchor console CA: nothing has to trust anything new.
#                        mqtt-admin-password is not rotatable: the broker keeps the one it
#                        started with. There is no mqtt-password: the server makes up its own
#                        broker password and keeps it with its MQTT settings.
#   --non-interactive    Never prompt; fail naming the missing flag instead.
#   --update <tag>       Upgrade (or downgrade) this install to a release: downloads that
#                        release's bundle from GitHub, checks it, unpacks it over this directory
#                        (never touching .env, config/, data/ or logs/), pins KENLENS_VERSION,
#                        runs the new script once, then docker compose pull and up -d --wait.
#                        <tag> is vX.Y.Z or `latest`. Takes no option but the two below.
#                        Backs the install up first: see --backup-dir.
#   --backup-dir <path>  With --update: where the backup is written; backups/ in this directory
#                        unless given. Two archives, taken with the stack stopped and started
#                        again straight after — the directory (all but backups/ and logs/) and
#                        the database volume — in the format the wiki's restore steps read. The
#                        newest two backups there are kept and older ones deleted. They hold
#                        every secret of the install: copy them off this host.
#   --no-backup          With --update: take no backup.
#   --restore <dir>      Restore a scheduled backup — one kenlens-<time>-<release>/ directory the
#                        backup service wrote — into this directory, start KenLens and check that
#                        it works. Run it from the bundle of the backup's release, set up or not:
#                        this directory's own .env, config/ and data/ are moved to
#                        before-restore-<time>/, never deleted. Nothing changes until the backup has
#                        decrypted and verified. Needs --key; takes no option but --key and --force.
#                        Pulls the images it needs when they are missing; otherwise it needs no
#                        network. See the wiki's Back up and restore page.
#   --key <file>         With --restore: the private key the backup was encrypted to.
#   --force              With --restore: replace a database that is already here. Nothing of it is
#                        kept.
#   -h, --help           Show this help.
#
# Idempotent: a secret, key or certificate that already exists is never replaced unless its
# item is named by --rotate. Regenerating the CA silently would lock out every anchor and
# browser that trusts it. An existing .env is only ever added to, never rewritten.
#
# What it writes (the layout docker-compose.yml mounts — its header is the authority):
#
#   config/ca/kenlens-ca.crt       the CA certificate — install it in browsers and anchors
#   config/ca/kenlens-ca.key       the CA key — never leaves this host; back it up
#   config/anchor-ca/              anchor-console-ca.{crt,key} — an intermediate the CA signs,
#                                  name-constrained to .local and the --domain values; the
#                                  server holds its key and signs anchor console certificates
#   config/secrets/                db-password, jwt-key, mqtt-admin-password,
#                                  cert-password, server-cert.pfx (web), db-ca.crt (copy of the CA)
#   config/tls/                    postgres.{crt,key}, mqtt-broker.{crt,key}, web.crt
#   config/dataprotection/         key-ring.{crt,key} — encrypts the server's data/keys at rest
#   config/ntp/                    the site's own time servers for the anchors, if any
#                                  (created empty; see chrony/chrony.conf)
#   data/keys/                     the server's key ring (created empty, mode 0700)
#   data/web-tls/                  the uploaded organisation web certificate (created empty, mode 0700)
#   .env                           KENLENS_VERSION, KENLENS_HTTPS_PORT, KENLENS_HOST,
#                                  KENLENS_ANCHOR_DOMAINS, KENLENS_TAG_HEIGHT_METRES,
#                                  KENLENS_DB_TUNE_MEMORY
#
# Owners: postgres.key and db-password belong to uid 70 (the Postgres image's user),
# mqtt-broker.key to uid 1883 (Mosquitto's). Without root the script sets them through the
# broker image, so it never needs sudo.
#
# Needs bash, openssl and docker; --update also curl and tar. No network access beyond pulling
# the broker image once, except --update, which downloads the bundle from GitHub.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR
# Keep in step with docker-compose.yml; used only to set file owners without root.
readonly MOSQUITTO_IMAGE="eclipse-mosquitto:2.0"
readonly POSTGRES_UID=70
readonly MOSQUITTO_UID=1883
readonly CA_DAYS=3650
readonly LEAF_DAYS=825
readonly KEY_RING_DAYS=9125
# Inside the CA's ten years by construction: an intermediate is never re-issued past it.
readonly ANCHOR_CA_DAYS=1825
readonly ROTATABLE="ca anchor-ca web broker postgres db-password jwt-key"

readonly CA_CRT="config/ca/kenlens-ca.crt"
readonly CA_KEY="config/ca/kenlens-ca.key"
readonly ANCHOR_CA_CRT="config/anchor-ca/anchor-console-ca.crt"
readonly ANCHOR_CA_KEY="config/anchor-ca/anchor-console-ca.key"
readonly SECRETS="config/secrets"
readonly TLS="config/tls"
# Retired: the broker's users now live in its data volume. An old install's file is left alone.
readonly OLD_PASSWD="config/mosquitto/passwd"
# Retired by issue #238: the server keeps its broker password with its MQTT settings.
readonly OLD_MQTT_PASSWORD="$SECRETS/mqtt-password"
readonly KEY_RING="config/dataprotection/key-ring"

hosts=()
domains=()
no_domain=false
tag_height=""
https_port=""
readonly DEFAULT_HTTPS_PORT=8443
version=""
update_tag=""
backup=true
backup_dir=""
restore_src=""
restore_key=""
force=false
failed_image=""     # the image ensure_images could not pull
readonly DEPLOY_REPO="kenlens-rtls/kenlens-deploy"
# Overridable so a test can stand GitHub in; the convention scripts/publish-deploy-bundle.sh set.
readonly GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
readonly KENLENS_DOWNLOAD_URL="${KENLENS_DOWNLOAD_URL:-https://github.com/$DEPLOY_REPO/releases/download}"
interactive=true
declare -A rotate=()

die() { echo "kenlens-setup: $*" >&2; exit 1; }
say() { echo "kenlens-setup: $*"; }

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

show_version() { # the KENLENS_VERSION .env pins, alone on stdout — what --update writes
  local installed bundled
  bundled=$(sed -n 's/^KENLENS_VERSION=//p' "$DIR/.env.example" 2>/dev/null | head -n 1)
  [[ -f "$DIR/.env" ]] \
    || die "not set up here: no .env in $DIR (this bundle is ${bundled:-of an unknown release})"
  installed=$(sed -n 's/^KENLENS_VERSION=//p' "$DIR/.env" | tail -n 1)
  [[ -n "$installed" ]] || die "$DIR/.env pins no KENLENS_VERSION"
  printf '%s\n' "$installed"
}

abs_path() { # abs_path <path> → absolute, from where the script was started; no symlink is resolved
  local p=$1
  [[ "$p" == /* ]] || p="$PWD/$p"
  while [[ "$p" == */ && "$p" != / ]]; do p=${p%/}; done
  printf '%s' "$p"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)            [[ $# -ge 2 ]] || die "--host needs a value"; hosts+=("$2"); shift 2 ;;
    --domain)          [[ $# -ge 2 ]] || die "--domain needs a value"; domains+=("$2"); shift 2 ;;
    --no-domain)       no_domain=true; shift ;;
    --https-port)      [[ $# -ge 2 ]] || die "--https-port needs a value"; https_port="$2"; shift 2 ;;
    --tag-height)      [[ $# -ge 2 ]] || die "--tag-height needs a value"; tag_height="$2"; shift 2 ;;
    --version)         if [[ $# -lt 2 || "$2" == -* ]]; then show_version; exit 0; fi
                       version="$2"; shift 2 ;;
    --update)          [[ $# -ge 2 && -n "$2" ]] || die "--update needs a release tag (vX.Y.Z) or 'latest'"; update_tag="$2"; shift 2 ;;
    --backup-dir)      [[ $# -ge 2 && -n "$2" ]] || die "--backup-dir needs a path"; backup_dir=$(realpath -m -s -- "$2"); shift 2 ;;
    --no-backup)       backup=false; shift ;;
    --restore)         [[ $# -ge 2 && -n "$2" ]] || die "--restore needs a backup's directory (kenlens-<time>-<release>)"
                       restore_src=$(abs_path "$2"); shift 2 ;;
    --key)             [[ $# -ge 2 && -n "$2" ]] || die "--key needs the private key file the backup was encrypted to"
                       restore_key=$(abs_path "$2"); shift 2 ;;
    --force)           force=true; shift ;;
    --rotate)          [[ $# -ge 2 ]] || die "--rotate needs an item: $ROTATABLE"
                       [[ " $ROTATABLE " == *" $2 "* ]] || die "cannot rotate '$2'; items: $ROTATABLE"
                       rotate[$2]=1; shift 2 ;;
    --non-interactive) interactive=false; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown option '$1' (see --help)" ;;
  esac
done

# Captured before a new CA adds its certificates to the set: only an operator's rotation
# needs the "recreate the containers" hint.
readonly rotations_requested=${#rotate[@]}

command -v openssl >/dev/null || die "openssl is required"
command -v docker  >/dev/null || die "docker is required"

cd "$DIR"
umask 077

# Prompting needs a terminal; without one, a missing value is an error, not a hang.
[[ -t 0 ]] || interactive=false

ask() { # ask <flag> <question> → answer on stdout
  $interactive || die "$1 is required (non-interactive run)"
  local answer
  read -r -p "$2: " answer
  printf '%s' "$answer"
}

env_get() { # env_get <key> → value of an uncommented KEY= line in .env, or nothing
  [[ -f .env ]] || return 0
  sed -n "s/^$1=//p" .env | tail -n 1
}

env_set() { # env_set <key> <value> — replace `KEY=` or `# KEY=`, else append
  local key=$1 value=$2
  if grep -qE "^#? ?$key=" .env; then
    local tmp
    tmp=$(mktemp .env.XXXXXX)
    awk -v k="$key" -v v="$value" '
      !done && $0 ~ "^#? ?" k "=" { print k "=" v; done = 1; next } { print }
    ' .env > "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

wants() { # wants <item> <file> — true when the file is missing or its item is rotated
  [[ ! -e "$2" || -n "${rotate[$1]:-}" ]]
}

version_lt() { # version_lt <vA.B.C> <vX.Y.Z> — the first is older; both must be vX.Y.Z
  local a b
  IFS=. read -r -a a <<< "${1#v}"
  IFS=. read -r -a b <<< "${2#v}"
  (( 10#${a[0]} < 10#${b[0]} || (10#${a[0]} == 10#${b[0]} && (10#${a[1]} < 10#${b[1]} \
     || (10#${a[1]} == 10#${b[1]} && 10#${a[2]} < 10#${b[2]}))) ))
}

url_host() { # url_host <name|ip> — the host part of a URL; an IPv6 literal goes in brackets
  if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

# ---------------------------------------------------------------------------
# --update — fetch a release's bundle, apply it here, start it.
#
# Called before anything below, and it exits the process itself: once the bundle is unpacked
# over this directory THIS FILE has been replaced, and bash reads a script as it runs it, so
# nothing after the call may ever execute from the old file. Everything is checked in a
# temporary directory first; the install directory is touched only once the bundle is known
# to be the right one.
# ---------------------------------------------------------------------------

# The backup --update takes before it changes anything: the whole-installation backup of the
# wiki's *Back up and restore* page, so its restore steps read it unchanged. Both archives are
# written from a container: files under config/ belong to the containers' users, and the
# database is reached through the compose service, so its volume's name is never guessed.
readonly PGDATA_DIR=/var/lib/postgresql/data
readonly BACKUPS_KEPT=2
restart_after_backup() { # restart_after_backup <service...> — a failure is reported, not fatal
  (( $# == 0 )) || docker compose start "$@" \
    || say "warning: could not start $* again after the backup; the upgrade starts the stack anyway"
}
update_backup() { # update_backup <current-version> — changes nothing on failure
  local from=${1:-unknown} stamp name files db db_kib dir_kib need free probe exclude=() running=() f
  [[ -n "$backup_dir" ]] || backup_dir="$DIR/backups"
  [[ "$from" =~ ^[A-Za-z0-9._-]+$ ]] || from=unknown
  # An archive of the directory must not contain the backups, wherever they are kept inside it.
  # The scheduled backups (Story 6.7) go to KENLENS_BACKUP_DIR, ./backups unless .env says otherwise.
  local skip=(backups logs) sched rel other keep
  sched=$(env_get KENLENS_BACKUP_DIR)
  if [[ -n "$sched" ]]; then
    # -s: DIR is the logical path (pwd), so compare without resolving symlinks on either side.
    [[ "$sched" == /* ]] && sched=$(realpath -m -s -- "$sched") || sched=$(realpath -m -s -- "$DIR/$sched")
    [[ "$sched/" != "$DIR/"* || "$sched" == "$DIR" ]] || skip+=("${sched#"$DIR/"}")
  fi
  [[ "$backup_dir/" != "$DIR/"* ]] || skip+=("${backup_dir#"$DIR/"}")
  # Each entry once, and none inside another: the measurement subtracts every entry's size.
  exclude=(); local kept=()
  for rel in "${skip[@]}"; do
    keep=true
    for other in "${skip[@]}"; do
      [[ "$other" != "$rel" && "$rel/" == "$other/"* ]] && keep=false
    done
    [[ " ${kept[*]} " != *" $rel "* ]] || keep=false
    ! $keep || kept+=("$rel")
  done
  for rel in "${kept[@]}"; do exclude+=("--exclude=./$rel"); done
  skip=("${kept[@]}")

  # Room for both archives, counted uncompressed, before anything is stopped.
  db_kib=$(docker compose run -T --rm --no-deps --entrypoint du postgres -sk "$PGDATA_DIR" | awk '{ print $1; exit }') \
    && dir_kib=$(docker run --rm --user 0 --entrypoint /bin/sh -v "$DIR:/b:ro" "$MOSQUITTO_IMAGE" \
                   -c 'cd /b && t=$(du -sk . | cut -f1) && for p in "$@"; do
                         [ -e "$p" ] && t=$((t - $(du -sk "$p" | cut -f1)))
                       done; echo "$t"' sh "${skip[@]}") \
    && [[ "$db_kib" =~ ^[0-9]+$ && "$dir_kib" =~ ^[0-9]+$ ]] \
    || die "could not measure the database and this directory for the backup; nothing was changed." \
           "To upgrade without one: --no-backup"
  need=$(( db_kib + dir_kib ))
  probe=$backup_dir
  until [[ -d "$probe" ]]; do probe=$(dirname "$probe"); done
  free=$(df -Pk "$probe" | awk 'NR == 2 { print $4 }')
  (( free > need )) \
    || die "the backup needs up to $(( need / 1024 )) MiB and $probe has $(( free / 1024 )) MiB free;" \
           "nothing was changed. Free some space, write it elsewhere with --backup-dir <path>," \
           "or upgrade without one: --no-backup"

  mkdir -p "$backup_dir" && chmod 0700 "$backup_dir" || die "cannot create $backup_dir; nothing was changed"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  name="kenlens-$stamp-$from"
  files="$backup_dir/$name-files.tar.gz"
  db="$backup_dir/$name-db.tar.gz"
  [[ ! -e "$files" && ! -e "$db" ]] || die "$files already exists; nothing was changed. Run --update again."

  # Only what was running is started again: `start` on the whole project refuses a service whose
  # dependency has no container. The upgrade's `up -d` starts everything in any case.
  mapfile -t running < <(docker compose ps --services --status running)
  say "backing up $from to $backup_dir (stopping the stack)"
  docker compose stop || { restart_after_backup "${running[@]}"
                           die "could not stop the stack for the backup; nothing was changed"; }
  # Both archives are 0600 — they hold every secret of the install.
  if ! ( umask 077
         docker run --rm --user 0 --entrypoint /bin/sh -v "$DIR:/b:ro" "$MOSQUITTO_IMAGE" \
           -c 'cd /b && tar -czf - "$@" .' sh "${exclude[@]}" > "$files" \
         && docker compose run -T --rm --no-deps --entrypoint tar postgres -czf - -C "$PGDATA_DIR" . > "$db" ); then
    rm -f "$files" "$db"
    restart_after_backup "${running[@]}"
    die "the backup failed (see above); nothing was changed. To upgrade without one: --no-backup"
  fi
  restart_after_backup "${running[@]}"
  say "backup: $files"
  say "        $db"
  say "        copy both off this host; restore them as the wiki's Back up and restore page shows"

  # Keep the newest backups; a backup is a pair, named by its time, so the names sort by age.
  for f in $(ls -1 "$backup_dir" | { grep -E '^kenlens-[0-9]{8}T[0-9]{6}Z-.*-files\.tar\.gz$' || true; } \
               | sort -r | tail -n +$(( BACKUPS_KEPT + 1 ))); do
    rm -f "$backup_dir/$f" "$backup_dir/${f%-files.tar.gz}-db.tar.gz"
    say "removed the older backup ${f%-files.tar.gz}"
  done
}

update_stage=""
update() { # update <tag|latest> — never returns
  local tag=$1 current asset pinned f host old_port
  [[ -f .env ]] || die "nothing is installed in $DIR (no .env); follow the install guide first"
  command -v curl >/dev/null || die "curl is required for --update"
  command -v tar  >/dev/null || die "tar is required for --update"
  if [[ "$tag" == latest ]]; then
    tag=$(curl -fsSL "$GITHUB_API_URL/repos/$DEPLOY_REPO/releases/latest" \
          | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p') \
      || die "could not get the latest release from $GITHUB_API_URL (no network, or GitHub's rate" \
             "limit for unauthenticated requests); name the release instead: --update vX.Y.Z"
    [[ -n "$tag" ]] || die "no latest release at $GITHUB_API_URL/repos/$DEPLOY_REPO"
  fi
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$tag' is not a release tag (vX.Y.Z) or 'latest'"
  current=$(env_get KENLENS_VERSION)
  # Both the pin and the bundle on disk (its .env.example names its release): an install made
  # with --version <other> has a pin that says one thing and files that say another.
  if [[ "$tag" == "$current" && "$tag" == "$(sed -n 's/^KENLENS_VERSION=//p' .env.example 2>/dev/null)" ]]; then
    say "already on $tag; nothing to do"
    exit 0
  fi

  # The bundle's files are read by the containers (start.sh by the broker's user, the chrony
  # config by chrony's), so they must not inherit this script's umask of 077. .env is never
  # written by the copy below; env_set keeps it 0600.
  umask 022
  update_stage=$(mktemp -d "${TMPDIR:-/tmp}/kenlens-update.XXXXXX")
  trap 'rm -rf "$update_stage"' EXIT
  asset="kenlens-deploy-$tag.tar.gz"
  say "downloading $asset"
  curl -fsSL -o "$update_stage/$asset" "$KENLENS_DOWNLOAD_URL/$tag/$asset" \
    || die "could not download $KENLENS_DOWNLOAD_URL/$tag/$asset; is $tag a published release? Nothing was changed."
  mkdir "$update_stage/bundle"
  tar -xzf "$update_stage/$asset" -C "$update_stage/bundle" --strip-components=1 \
    || die "$asset did not unpack; nothing was changed"
  for f in kenlens-setup.sh docker-compose.yml .env.example; do
    [[ -f "$update_stage/bundle/$f" ]] || die "$asset holds no $f, so it is not a KenLens deploy bundle; nothing was changed"
  done
  pinned=$(sed -n 's/^KENLENS_VERSION=//p' "$update_stage/bundle/.env.example" | head -n 1)
  [[ "$pinned" == "$tag" ]] || die "$asset is pinned to '$pinned', not $tag; nothing was changed"
  for f in .env config data logs backups; do
    [[ ! -e "$update_stage/bundle/$f" ]] || die "$asset carries $f, which a bundle never does; nothing was changed"
  done

  if [[ "$current" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_lt "$tag" "$current"; then
    say "warning: $tag is older than $current. The database keeps the newer release's schema;" \
        "it is not migrated back."
  fi
  if $backup; then update_backup "$current"; else say "--no-backup: taking no backup"; fi
  # An install made before KENLENS_HTTPS_PORT existed could only choose its port by editing the
  # mapping in docker-compose.yml, which the copy below replaces: keep that choice in .env.
  if [[ -z "$(env_get KENLENS_HTTPS_PORT)" ]]; then
    old_port=$(sed -n 's/^ *- "\([0-9]\{1,5\}\):8443"$/\1/p' docker-compose.yml 2>/dev/null)
    [[ -z "$old_port" || "$old_port" == "$DEFAULT_HTTPS_PORT" ]] || env_set KENLENS_HTTPS_PORT "$old_port"
  fi
  # From here this file is gone: see the banner above.
  cp -R "$update_stage/bundle/." "$DIR/" \
    || die "copying the $tag bundle into $DIR failed part-way (see above): this directory now holds" \
           "files from two releases and .env still pins $current. Fix the cause, then run --update $tag again."
  env_set KENLENS_VERSION "$tag"
  say "applied the $tag bundle; preparing the host with its setup script"
  "$DIR/kenlens-setup.sh" --non-interactive </dev/null \
    || die "the $tag setup script failed; the bundle is in place and .env pins $tag"
  say "pulling the $tag images"
  docker compose pull || die "docker compose pull failed; run it again, then docker compose up -d --wait"
  # --remove-orphans: a release that drops or renames a service must not leave the old container
  # running, holding its ports.
  docker compose up -d --wait --remove-orphans || die "the stack did not become healthy; see docker compose logs"
  host=$(env_get KENLENS_HOST)
  host=${host%%,*}
  [[ -n "$host" ]] && host=$(url_host "$host") || host="<host>"
  say "KenLens $tag is at https://$host:$(env_get KENLENS_HTTPS_PORT)"
  exit 0
}

# ---------------------------------------------------------------------------
# --restore — put a scheduled backup (Story 6.7) back into this directory, start it and prove it
# serves (Story 6.8, docs/superpowers/specs/2026-11-10-restore-from-backup-design.md).
#
# Steps 1-6 change nothing, and every refusal there says so. From step 7 the directory changes, and
# a failure says what it then holds (restore_failed). Every container given a path gets it through
# --mount, which refuses a missing source where -v would create it as a root-owned directory.
# ---------------------------------------------------------------------------
readonly RESTORE_READY_SECONDS=120
restore_work=""          # .restore-<time>/: the decrypted backup, every secret of the install in plaintext
restore_aside=""         # before-restore-<time>/, once this directory's own files are in it
restore_stopped=false    # once step 7's docker compose down has succeeded
restore_db_emptied=false
restore_pg_volume=""

manifest_get() { # manifest_get <manifest.json> <top-level key> → its string value, or nothing
  # The agent writes the manifest indented by two (BackupContract.Json), one key per line.
  sed -n "s/^  \"$2\": \"\([^\"]*\)\",\{0,1\}\$/\1/p" "$1" | head -n 1
}

manifest_part_bytes() { # manifest_part_bytes <manifest.json> <part file> → its size in bytes, or nothing
  awk -v want="\"$2\"," '
    $1 == "\"file\":"  { part = $2 }
    $1 == "\"bytes\":" && part == want { sub(/,$/, "", $2); print $2; part = "" }' "$1"
}

compose_volume() { # compose_volume <volume> [env-file] → the name compose gives it in this directory's project
  local out
  out=$(docker compose ${2:+--env-file "$2"} config 2>/dev/null) || return 0
  # awk reads to the end: an early exit would fail the pipe under pipefail (#249).
  awk -v key="  $1:" '
    /^[^ ]/               { top = ($0 == "volumes:"); want = 0; next }
    top && $0 == key      { want = 1; next }
    top && want && /^    name: / { print $2; want = 0 }
    top && /^  [^ ]/      { want = 0 }' <<<"$out"
}

compose_project() { # compose_project → the name of this directory's compose project, or nothing
  local out
  out=$(docker compose config 2>/dev/null) || return 0
  # Quoted when it reads as a number ("2024"). sed reads to the end, as compose_volume's awk does (#249).
  sed -n 's/^name: "\{0,1\}\([a-z0-9][a-z0-9_-]*\)"\{0,1\}$/\1/p' <<<"$out"
}

root_sh() { # root_sh <docker run args...> — /bin/sh as root with no network; mounts, then image and script
  docker run --rm --network none --user 0 --entrypoint /bin/sh "$@"
}

ensure_images() { # ensure_images <image...> — pulls each one missing; false, with failed_image set, when a pull fails
  local image
  for image in "$@"; do
    docker image inspect "$image" >/dev/null 2>&1 && continue
    say "pulling $image"
    docker pull -q "$image" >/dev/null || { failed_image=$image; return 1; }
  done
}

restore_cleanup() { # the EXIT trap from step 6: the plaintext never outlives the script
  [[ -n "$restore_work" && -d "$restore_work" ]] || return 0
  root_sh --mount "type=bind,src=$restore_work,dst=/w" "$MOSQUITTO_IMAGE" -c 'rm -rf /w/parts /w/files' >/dev/null 2>&1 || true
  rm -f "$restore_work/restored.env"
  rmdir "$restore_work" 2>/dev/null \
    || say "warning: could not delete $restore_work, which holds the decrypted backup: delete it (it is root's)"
  restore_work=""
}

restore_failed() { # restore_failed <message...> — from step 7 on: what failed, and what the directory now holds
  echo "kenlens-setup: $*" >&2
  if $restore_stopped; then
    echo "kenlens-setup: the restore stopped part-way, with KenLens stopped." >&2
  else
    echo "kenlens-setup: the restore stopped part-way." >&2
  fi
  if [[ -n "$restore_aside" ]]; then
    echo "kenlens-setup: this directory's own files from before are in $restore_aside/; nothing there is deleted." >&2
  fi
  if $restore_db_emptied; then
    echo "kenlens-setup: the database volume $restore_pg_volume may hold part of a database." >&2
  fi
  if $restore_db_emptied || $force; then
    echo "kenlens-setup: fix the cause, then run --restore again with --force." >&2
  else
    echo "kenlens-setup: fix the cause, then run --restore again." >&2
  fi
  exit 1
}

restore() { # restore <backup-dir> — never returns
  local src=$1 manifest name release finished outcome bundled pinned v f broker_volume pg_state
  manifest="$src/manifest.json"

  # 1. The backup.
  for f in "$DIR" "$src" "$restore_key"; do
    [[ "$f" != *,* ]] || die "$f: Docker cannot mount a path with a comma in it; rename it. Nothing was changed."
  done
  [[ -d "$src" ]] || die "$src is not a directory: --restore takes one backup's directory," \
                         "kenlens-<time>-<release>. Nothing was changed."
  [[ -f "$manifest" ]] || die "$src holds no manifest.json, so it is not a scheduled backup" \
                              "(kenlens-<time>-<release>/). Nothing was changed."
  outcome=$(manifest_get "$manifest" outcome)
  name=$(manifest_get "$manifest" name)
  release=$(manifest_get "$manifest" release)
  finished=$(manifest_get "$manifest" finished_utc)
  [[ "$outcome" == succeeded ]] \
    || die "$manifest records a backup that did not finish (outcome: ${outcome:-none}); restore another one." \
           "Nothing was changed."
  [[ "$release" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "$manifest names no release (vX.Y.Z). Nothing was changed."

  # 2. The release: this bundle's, and the one .env pins when the directory is set up.
  [[ -f .env.example ]] || die ".env.example is missing from $DIR — is this a KenLens deploy bundle? Nothing was changed."
  bundled=$(sed -n 's/^KENLENS_VERSION=//p' .env.example | head -n 1)
  pinned=$(env_get KENLENS_VERSION)
  for v in "$bundled" ${pinned:+"$pinned"}; do
    [[ "$v" == "$release" ]] \
      || die "This backup was taken by $release; this directory holds ${v:-an unknown release}." \
             "Unpack the $release bundle into a directory of its own and run --restore there. Nothing was changed."
  done

  # 3. The key file.
  [[ -f "$restore_key" && -r "$restore_key" ]] \
    || die "the key file $restore_key does not exist or cannot be read. Nothing was changed."

  # 4. The database volume, by the name compose gives it. Compose requires KENLENS_VERSION, which a
  # directory never set up has no .env for; it is the backup's release either way.
  export KENLENS_VERSION=$release
  docker info >/dev/null 2>&1 || die "Docker is not running here (docker info failed). Nothing was changed."
  restore_pg_volume=$(compose_volume kenlens-postgres-data)
  broker_volume=$(compose_volume kenlens-mosquitto-data)
  [[ -n "$restore_pg_volume" && -n "$broker_volume" ]] \
    || die "docker compose config names no database or broker volume here (run it to see why). Nothing was changed."
  # The volumes are the compose project's, and compose names the project after the directory: an
  # installation in another directory of the same name shares them, and `docker compose down` here would
  # stop its containers. Refused even with --force. -ef compares inodes, so a path through a symlink is
  # still this directory. A docker ps that fails refuses, as the probe below does.
  local project listed cid cdir other=""
  project=$(compose_project)
  [[ -n "$project" ]] || die "docker compose config names no project here (run it to see why). Nothing was changed."
  listed=$(docker ps -a --filter "label=com.docker.compose.project=$project" \
             --format '{{.ID}} {{.Label "com.docker.compose.project.working_dir"}}') \
    || die "could not list the containers of compose project $project (docker ps failed; see above)." \
           "Nothing was changed."
  while read -r cid cdir; do
    [[ -n "$cid" ]] || continue
    if [[ -z "$cdir" || ! "$cdir" -ef "$DIR" ]]; then other=${cdir:-"a directory it does not record"}; break; fi
  done <<<"$listed"
  [[ -z "$other" ]] \
    || die "another installation, in $other, has containers in compose project $project, which is this" \
           "directory's: --restore here would stop them and replace that installation's database. Run" \
           "--restore in a directory of another name. Nothing was changed."
  ensure_images "$MOSQUITTO_IMAGE" \
    || die "could not pull $failed_image: pull it while this machine has a connection. Nothing was changed."
  # A plain container, not `docker compose run postgres`: in a directory never set up, compose would
  # create every missing bind-mount source (config/tls/postgres.key …) as a root-owned directory.
  # Three answers, so that a probe that fails for another reason refuses rather than reads as empty.
  pg_state=absent
  if docker volume inspect "$restore_pg_volume" >/dev/null 2>&1; then
    pg_state=$(root_sh --mount "type=volume,src=$restore_pg_volume,dst=/v,readonly" "$MOSQUITTO_IMAGE" \
                 -c 'if [ -e /v/PG_VERSION ]; then echo holds; else echo empty; fi') || pg_state=""
  fi
  case "$pg_state" in
    absent|empty) ;;
    holds)
      $force || die "The database volume $restore_pg_volume already holds a database. --restore replaces it" \
                    "and keeps nothing of it: run again with --force. The volume is compose project" \
                    "$project's, and an installation in another directory named $project whose containers" \
                    "were removed (docker compose down) would share it. Nothing was changed."
      say "--force: the database in $restore_pg_volume will be replaced" ;;
    *) die "could not look inside the database volume $restore_pg_volume (docker run failed; see above)." \
           "Nothing was changed." ;;
  esac

  # 5. Space. One container sees this directory and the volume, so a filesystem that holds both is
  # counted once, with both needs added. A volume not there yet is measured where it will be, on an
  # anonymous volume: one created here, outside compose, would not be compose's, and `down -v` would
  # leave it behind. Not read-only, which Docker Engine 27 refuses for an anonymous volume (#449); it is
  # empty and goes with the container. Sizes are the encrypted parts', a little more than the plaintext.
  local db_bytes files_bytes need_here need_volume df_out fs_here free_here fs_volume free_volume
  local volume_mount="type=volume,dst=/v"
  if docker volume inspect "$restore_pg_volume" >/dev/null 2>&1; then
    volume_mount="type=volume,src=$restore_pg_volume,dst=/v,readonly"
  fi
  db_bytes=$(manifest_part_bytes "$manifest" db.tar.kbk)
  files_bytes=$(manifest_part_bytes "$manifest" files.tar.kbk)
  [[ "$db_bytes" =~ ^[0-9]+$ && "$files_bytes" =~ ^[0-9]+$ ]] \
    || die "$manifest does not list db.tar.kbk and files.tar.kbk with their sizes. Nothing was changed."
  # KiB, rounded up. Here: both parts decrypted, and the files extracted. In the volume: the database.
  need_here=$(( (db_bytes + 2 * files_bytes + 1023) / 1024 ))
  need_volume=$(( (db_bytes + 1023) / 1024 ))
  df_out=$(root_sh --mount "type=bind,src=$DIR,dst=/i,readonly" --mount "$volume_mount" \
                   "$MOSQUITTO_IMAGE" -c 'df -Pk /i /v | tail -n 2') \
    || die "could not measure the free space in $DIR and in $restore_pg_volume. Nothing was changed."
  read -r fs_here _ _ free_here _ <<<"$(sed -n 1p <<<"$df_out")"
  read -r fs_volume _ _ free_volume _ <<<"$(sed -n 2p <<<"$df_out")"
  [[ "$free_here" =~ ^[0-9]+$ && "$free_volume" =~ ^[0-9]+$ ]] \
    || die "could not read the free space in $DIR and in $restore_pg_volume (df said: $df_out). Nothing was changed."
  if [[ "$fs_here" == "$fs_volume" ]]; then
    need_here=$(( need_here + need_volume ))
    need_volume=0
  fi
  (( free_here > need_here )) \
    || die "the restore needs up to $(( need_here / 1024 )) MiB free in $DIR, which has $(( free_here / 1024 )) MiB." \
           "Free some space. Nothing was changed."
  (( need_volume == 0 || free_volume > need_volume )) \
    || die "the database needs up to $(( need_volume / 1024 )) MiB free where Docker keeps its volumes," \
           "which has $(( free_volume / 1024 )) MiB. Free some space. Nothing was changed."

  # 6. Decrypt with this release's own image, then read what will be restored before using any of it.
  local image out stamp restored_env backup_dest dest_path restored_volume
  local -a images=()
  image=$(docker compose config --images 2>/dev/null | grep -m 1 '/kenlens-server:' || true)
  [[ -n "$image" ]] || die "docker compose config names no kenlens-server image here. Nothing was changed."
  ensure_images "$image" \
    || die "could not pull $failed_image: pull it while this machine has a connection. Nothing was changed."
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  restore_work="$DIR/.restore-$stamp"
  trap restore_cleanup EXIT
  mkdir -m 0700 "$restore_work" || die "could not create $restore_work. Nothing was changed."
  say "decrypting $name (no network)"
  if ! out=$(docker run --rm --network none --user 0 --entrypoint dotnet \
               --mount "type=bind,src=$src,dst=/in,readonly" \
               --mount "type=bind,src=$restore_key,dst=/key/private.pem,readonly" \
               --mount "type=bind,src=$restore_work,dst=/out" \
               "$image" /app/backup/kenlens-backup.dll decrypt --key /key/private.pem --in /in --out /out/parts 2>&1); then
    sed 's/^/  /' <<<"$out" >&2
    die "$name did not decrypt (above). Nothing was changed."
  fi
  sed -n 's/^ok /  ok /p' <<<"$out"
  # A backup is trusted as the bundle is (docs/SECURITY.md): nobody signs it, and whoever can write to
  # the share can make one. So files.tar is unpacked, as root to keep every owner and mode, into
  # .restore-<time>/files/ by a container that sees nothing else, and checked there: step 10 moves only
  # .env, config/ and data/ into this directory, whose kenlens-setup.sh step 12 runs. A link inside them
  # is the backup's own (the backup service writes link entries); one that leads out is refused, and so
  # is config or data as a link, anything that is not a file, directory or link (a device, a FIFO), and a
  # setuid or setgid file. The container gets files.tar as one read-only file and files/ as the only
  # place it writes: busybox tar does not clean a hard link's target, so with parts/ in the same mount
  # a crafted entry hard-linked to ../parts/db.tar would become a second name for the decrypted database,
  # which step 10 would move into this directory and the cleanup would not remove. With nothing but
  # files/ on that mount the link fails (EXDEV, or no such file), and tar's exit status refuses.
  local verdict env_owner
  local link_check='for l; do
      t=$(readlink "$l")
      case "$t" in /*|..|../*|*/..|*/../*) printf "%s, a link to \"%s\"\n" "${l#./}" "$t" ;; esac
    done'
  mkdir -m 0700 "$restore_work/files" || die "could not create $restore_work/files. Nothing was changed."
  verdict=$(root_sh --mount "type=bind,src=$restore_work/parts/files.tar,dst=/files.tar,readonly" \
                    --mount "type=bind,src=$restore_work/files,dst=/f" "$MOSQUITTO_IMAGE" -c \
    'tar --numeric-owner -xpf /files.tar -C /f && cd /f || exit 1
     for e in * .*; do
       case "$e" in .|..|.env|config|data) continue ;; esac
       if [ -e "$e" ] || [ -L "$e" ]; then echo "refuse $e, which is not .env, config/ or data/"; exit 0; fi
     done
     if [ -L .env ]; then echo "refuse .env, which is a link"; exit 0; fi
     if [ ! -e .env ]; then echo "refuse no .env file"; exit 0; fi
     if [ ! -f .env ]; then echo "refuse .env, which is not a regular file"; exit 0; fi
     for d in config data; do
       if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then echo "refuse $d, which is not a directory"; exit 0; fi
     done
     out=$(find . ! -type f ! -type d ! -type l) || exit 1
     if [ -n "$out" ]; then echo "refuse $(printf "%s\n" "$out" | sed -n "1s|^\./||p"), which is not a file, directory or link"; exit 0; fi
     out=$(find . ! -type d \( -perm -4000 -o -perm -2000 \)) || exit 1
     if [ -n "$out" ]; then echo "refuse $(printf "%s\n" "$out" | sed -n "1s|^\./||p"), which is setuid or setgid"; exit 0; fi
     out=$(find . -type l -exec sh -c "$1" sh {} +) || exit 1
     if [ -n "$out" ]; then echo "refuse $(printf "%s\n" "$out" | sed -n 1p)"; exit 0; fi
     owner=$(stat -c %u .env) || exit 1
     echo "ok $owner"' sh "$link_check") \
    || die "could not unpack the backup's files.tar (above). Nothing was changed."
  case "$verdict" in
    "ok "[0-9]*) env_owner=${verdict#ok } ;;
    "refuse "*)  die "the backup's files.tar holds ${verdict#refuse }. --restore writes only .env, config/ and" \
                     "data/ from a backup, and no link that leads out of them. Nothing was changed." ;;
    *)           die "could not check the backup's files.tar (it said: ${verdict:-nothing}). Nothing was changed." ;;
  esac
  # Root's .env means the installation that took the backup ran as root; its files are root's, and step
  # 12's setup, run as this user, could not read them.
  [[ "$env_owner" != 0 || "$(id -u)" == 0 ]] \
    || die "the backup's .env belongs to root: the installation that took it ran as root. Run --restore" \
           "with sudo. Nothing was changed."
  restored_env="$restore_work/restored.env"
  { root_sh --mount "type=bind,src=$restore_work,dst=/r,readonly" "$MOSQUITTO_IMAGE" \
      -c 'cat /r/files/.env' > "$restored_env" 2>/dev/null && [[ -s "$restored_env" ]]; } \
    || die "the backup's .env is empty or cannot be read. Nothing was changed."
  # A share the restored .env writes backups to must be mounted: Docker would put an empty root-owned
  # directory in its place. ./backups, the default, is created below by this release's setup.
  backup_dest=$(sed -n 's/^KENLENS_BACKUP_DIR=//p' "$restored_env" | tail -n 1)
  case "$backup_dest" in
    ""|./backups|./backups/) dest_path="" ;;
    /*)                      dest_path=$backup_dest ;;
    ./*)                     dest_path="$DIR/${backup_dest#./}" ;;
    *)                       dest_path="" ;;   # a bare name is a Docker volume
  esac
  [[ -z "$dest_path" || -d "$dest_path" ]] \
    || die "the restored .env writes backups to $backup_dest, which does not exist here: Docker would create" \
           "an empty directory there, as root. Mount the share there, or create the directory owned by you," \
           "then run --restore again. Nothing was changed."
  restored_volume=$(compose_volume kenlens-postgres-data "$restored_env")
  [[ -n "$restored_volume" ]] || die "docker compose could not read the restored .env. Nothing was changed."
  [[ "$restored_volume" == "$restore_pg_volume" ]] \
    || die "the restored .env gives this installation another compose project (database volume" \
           "$restored_volume, not $restore_pg_volume): run --restore in a directory named" \
           "${restored_volume%_kenlens-postgres-data}. Nothing was changed."
  mapfile -t images < <(docker compose --env-file "$restored_env" config --images 2>/dev/null | sort -u)
  (( ${#images[@]} > 0 )) || die "docker compose could not read the restored .env. Nothing was changed."
  ensure_images "${images[@]}" \
    || die "could not pull $failed_image, which the restored installation runs: pull it while this machine has" \
           "a connection, then run --restore again. Nothing was changed."

  # 7. Stop. From here the directory changes, and restore_failed says what it then holds.
  say "restoring $name into $DIR"
  docker compose down || restore_failed "docker compose down failed (above)."
  restore_stopped=true

  # 8. The broker's users. Its plugin admin's password is the one the restored config/ replaces:
  # kept, the broker fails its own healthcheck. KenLens re-creates every broker user at start.
  if docker volume inspect "$broker_volume" >/dev/null 2>&1; then
    docker volume rm "$broker_volume" >/dev/null || restore_failed "could not remove the broker's volume $broker_volume."
  fi

  # 9. This directory's own files are moved aside, never deleted. Through a root container: config/
  # holds files of the containers' users, and data/ can be root's.
  local uid gid
  local -a items=()
  uid=$(id -u)
  gid=$(id -g)
  for f in .env config data; do
    if [[ -e "$f" || -L "$f" ]]; then items+=("$f"); fi
  done
  if (( ${#items[@]} > 0 )); then
    restore_aside="before-restore-$stamp"
    root_sh --mount "type=bind,src=$DIR,dst=/w" "$MOSQUITTO_IMAGE" -c \
      'a=$1; owner=$2; shift 2
       mkdir "/w/$a" && chown "$owner" "/w/$a" && chmod 0700 "/w/$a" || exit 1
       for f; do mv "/w/$f" "/w/$a/" || exit 1; done' sh "$restore_aside" "$uid:$gid" "${items[@]}" \
      || restore_failed "could not move ${items[*]} aside into $restore_aside/."
    say "moved this directory's ${items[*]} aside into $restore_aside/"
  fi

  # 10. The backup's .env, config/ and data/, as step 6 unpacked and checked them, renamed into this
  # directory on one mount, so each file keeps its owner and mode: postgres.key stays uid 70,
  # mqtt-broker.key uid 1883. None is moved onto a path that is there: mv would put it inside. The old
  # operator's files (whoever owned .env) then become this user's, unless this user is root; a .env of
  # root's was refused at step 6 unless this run is root's too.
  root_sh --mount "type=bind,src=$DIR,dst=/w" "$MOSQUITTO_IMAGE" -c \
    's=/w/$1/files; shift
     for f in .env config data; do
       [ -e "$s/$f" ] || [ -L "$s/$f" ] || continue
       if [ -e "/w/$f" ] || [ -L "/w/$f" ]; then echo "kenlens-setup: $f is in the way; nothing replaces it" >&2; exit 1; fi
       mv "$s/$f" "/w/$f" || exit 1
     done
     old=$(stat -c %u /w/.env) || exit 1
     if [ "$1" = 0 ] || [ "$old" = 0 ] || [ "$old" = "$1" ]; then exit 0; fi
     for p in /w/.env /w/config /w/data; do
       [ ! -e "$p" ] || find "$p" -xdev -user "$old" -exec chown -h "$1:$2" {} \; || exit 1
     done' sh ".restore-$stamp" "$uid" "$gid" \
    || restore_failed "could not put the backup's files back into $DIR."

  # 11. The database, into the emptied volume. Compose creates the volume when it is missing (the
  # files it binds are in place now), so it is compose's and `down -v` removes it with the rest.
  docker compose create postgres >/dev/null \
    || restore_failed "docker compose could not create the database volume (docker compose create postgres)."
  restore_db_emptied=true
  root_sh --mount "type=volume,src=$restore_pg_volume,dst=/v" \
          --mount "type=bind,src=$restore_work,dst=/r,readonly" "$MOSQUITTO_IMAGE" \
    -c 'rm -rf /v/* /v/.[!.]* && tar --numeric-owner -xpf /r/parts/db.tar -C /v' \
    || restore_failed "could not put the database back into $restore_pg_volume."

  # 12. The plaintext is no longer needed. This release's setup then adds what a backup does not hold
  # (backups/, owned by this user) and replaces nothing that is there, as it does after --update.
  restore_cleanup
  say "preparing $DIR with this release's setup"
  "$DIR/kenlens-setup.sh" --non-interactive </dev/null 2>&1 | sed 's/^/  /' \
    || restore_failed "this release's setup failed (above)."

  # 13-14. Start it, then check that it works. Every check runs; the ones that fail are listed together.
  local -a failed=()
  local ready=false audit="" audit_rows="" holds i
  say "starting KenLens"
  if ! docker compose up -d --wait --remove-orphans; then
    failed+=("services: docker compose up -d --wait failed; docker compose ps and docker compose logs say which service and why")
  else
    # Asked inside the server container, as its healthcheck asks /health/live: on a new machine the
    # installation's names still point at the old one, and an uploaded organisation certificate would
    # not chain to the KenLens CA.
    for (( i = 0; i < RESTORE_READY_SECONDS; i += 2 )); do
      if docker compose exec -T kenlens-server curl -fsSk https://localhost:8443/health/ready >/dev/null 2>&1; then
        ready=true
        break
      fi
      sleep 2
    done
    $ready || failed+=("ready: /health/ready did not answer ready within ${RESTORE_READY_SECONDS}s (docker compose logs kenlens-server says why). Most often the restored MQTT settings name a broker this machine cannot reach: sign in and change them on Configuration → MQTT broker.")
    audit=$(docker compose exec -T kenlens-server dotnet /app/audit-verify/kenlens-audit-verify.dll verify 2>&1) || true
    audit_rows=$(sed -n 's/^OK: audit chain valid (\([0-9]*\) rows.*/\1/p' <<<"$audit")
    [[ -n "$audit_rows" ]] || failed+=("audit chain: $(grep -m1 -E '^(FAIL|verify):|Exception' <<<"$audit" || tail -n 1 <<<"${audit:-the verifier printed nothing}")")
  fi
  for f in web mqtt-broker; do
    openssl verify -CAfile config/ca/kenlens-ca.crt "config/tls/$f.crt" >/dev/null 2>&1 \
      || failed+=("certificates: config/tls/$f.crt does not chain to the restored config/ca/kenlens-ca.crt")
  done

  # 15. What it holds, for the operator to recognise; nothing is compared.
  holds=$(docker compose exec -T postgres psql -U kenlens -d kenlens -tAc \
    "SELECT (SELECT count(*) FROM users) || ' users, ' || (SELECT count(*) FROM anchors) || ' anchors, '
       || (SELECT count(*) FROM floors) || ' floors, '
       || (SELECT count(*) FROM zones WHERE archived_at IS NULL) || ' zones; newest position '
       || coalesce(to_char((SELECT max(ts) FROM position_history) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'none')" \
    2>/dev/null) && [[ -n "$holds" ]] || holds="(could not be read)"

  if (( ${#failed[@]} > 0 )); then
    for f in "${failed[@]}"; do echo "kenlens-setup: FAILED $f" >&2; done
    echo "kenlens-setup: $name is restored into $DIR, but the checks above failed. Fix their cause, then" \
         "docker compose up -d --wait. It holds: $holds" >&2
    [[ -z "$restore_aside" ]] \
      || echo "kenlens-setup: this directory's own files from before are in $restore_aside/." >&2
    exit 1
  fi
  say "restored $name, taken by $release, finished $finished"
  say "verified: services healthy; ready; certificates chain to the restored CA; audit chain valid ($audit_rows rows)"
  say "holds: $holds"
  say "next: sign in with a user of the restored installation (a fresh install's Admin is gone)"
  say "      delete the key file from this machine: $restore_key"
  say "      point the installation's names at this machine if it replaces another"
  if [[ -n "$restore_aside" ]]; then
    say "      once KenLens works: docker run --rm -v \"$DIR:/w\" $MOSQUITTO_IMAGE rm -rf /w/$restore_aside"
  fi
  say "KenLens may raise Backup failed (no backup in 36 hours) until its next backup; Run backup now" \
      "on Configuration → System clears it"
  exit 0
}

if [[ -n "$update_tag" ]]; then
  [[ ${#hosts[@]} -eq 0 && ${#domains[@]} -eq 0 && $no_domain == false && -z "$tag_height" \
     && -z "$version" && -z "$https_port" && ${#rotate[@]} -eq 0 \
     && -z "$restore_src" && -z "$restore_key" && $force == false ]] \
    || die "--update takes no other option but --backup-dir and --no-backup"
  if ! $backup && [[ -n "$backup_dir" ]]; then die "--backup-dir and --no-backup contradict each other"; fi
  update "$update_tag"
fi
if [[ -n "$restore_src" ]]; then
  [[ ${#hosts[@]} -eq 0 && ${#domains[@]} -eq 0 && $no_domain == false && -z "$tag_height" \
     && -z "$version" && -z "$https_port" && ${#rotate[@]} -eq 0 && $backup == true && -z "$backup_dir" ]] \
    || die "--restore takes no other option but --key and --force"
  [[ -n "$restore_key" ]] || die "--restore needs --key <file>: the private key the backup was encrypted to"
  restore "$restore_src"
fi
[[ -z "$restore_key" && $force == false ]] || die "--key and --force only go with --restore"
[[ $backup == true && -z "$backup_dir" ]] || die "--backup-dir and --no-backup only go with --update"

# ---------------------------------------------------------------------------
# Inputs — every answer is settled before anything is written, so a refused or
# interrupted run leaves the directory as it found it.
# ---------------------------------------------------------------------------

if [[ ! -f .env ]]; then
  [[ -f .env.example ]] || die ".env.example is missing from $DIR — is this a KenLens deploy bundle?"
  [[ -n "$version" ]] || version=$(sed -n 's/^KENLENS_VERSION=//p' .env.example | head -n 1)
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$version' is not vX.Y.Z"
elif [[ -n "$version" && "$version" != "$(env_get KENLENS_VERSION)" ]]; then
  say "warning: .env already pins $(env_get KENLENS_VERSION); --version $version ignored." \
      "To upgrade, run ./kenlens-setup.sh --update $version."
  version=""
fi

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

[[ -z "$https_port" ]] || valid_port "$https_port" || die "HTTPS port '$https_port' is not a port number (1-65535)"
new_https_port=""
port_changed=false
if [[ ! -f .env ]]; then
  if [[ -z "$https_port" ]] && $interactive; then
    https_port=$(ask --https-port "HTTPS port browsers connect to [$DEFAULT_HTTPS_PORT]")
    https_port=${https_port// /}
    [[ -n "$https_port" ]] || https_port=$DEFAULT_HTTPS_PORT
    valid_port "$https_port" || die "HTTPS port '$https_port' is not a port number (1-65535)"
  fi
  new_https_port=${https_port:-$DEFAULT_HTTPS_PORT}
else
  # An install made before the key existed ran on compose's default, so that is what it has.
  stored_port=$(env_get KENLENS_HTTPS_PORT)
  effective_port=${stored_port:-$DEFAULT_HTTPS_PORT}
  if [[ -n "$https_port" && "$https_port" != "$effective_port" ]]; then
    new_https_port=$https_port
    port_changed=true
  elif [[ -z "$stored_port" ]]; then
    new_https_port=$effective_port
  fi
fi

# Optional: with no height the server solves tags in three dimensions (issue #394); a height
# selects the planar fallback.
if [[ -n "$tag_height" ]]; then
  stored_height=$(env_get KENLENS_TAG_HEIGHT_METRES)
  if [[ -n "$stored_height" ]]; then
    [[ "$tag_height" == "$stored_height" ]] \
      || say "warning: .env already sets KENLENS_TAG_HEIGHT_METRES=$stored_height;" \
             "--tag-height $tag_height ignored. Edit .env to change it."
    tag_height=""
  elif ! [[ "$tag_height" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v h="$tag_height" 'BEGIN { exit !(h > 0) }'; then
    die "tag height '$tag_height' is not a positive number of metres"
  fi
fi

ca_new=false
if [[ ! -e "$CA_KEY" || -n "${rotate[ca]:-}" ]]; then
  if [[ -e "$CA_KEY" ]]; then
    say "WARNING: rotating the KenLens CA. Every browser and anchor that trusts the old CA" \
        "will refuse this host until it is given config/ca/kenlens-ca.crt again."
    if $interactive; then
      read -r -p "Type 'rotate' to continue: " confirm
      [[ "$confirm" == rotate ]] || die "CA rotation cancelled; nothing was changed"
    fi
  elif [[ -e "$TLS/mqtt-broker.crt" || -e "$TLS/postgres.crt" || -e "$SECRETS/server-cert.pfx" ]]; then
    die "$CA_KEY is missing but certificates it signed exist. Restore the CA key from backup," \
        "or re-issue everything with --rotate ca."
  fi
  ca_new=true
  # A new CA invalidates every certificate signed by the old one.
  rotate[web]=1; rotate[broker]=1; rotate[postgres]=1; rotate[anchor-ca]=1
fi

# The anchor console CA. The CA signs it, so it needs room for one CA below it: pathlen:1.
# A CA made before anchor console certificates existed says pathlen:0, and an intermediate
# under it would never verify, so none is made until the CA is re-created.
need_anchor_ca=false
ca_too_old=false
if wants anchor-ca "$ANCHOR_CA_CRT"; then
  if ! $ca_new && ! openssl x509 -in "$CA_CRT" -noout -ext basicConstraints 2>/dev/null \
       | grep -qE 'pathlen:[1-9]'; then
    ca_too_old=true
  else
    need_anchor_ca=true
  fi
fi

valid_domain() { # a DNS domain, lowercase, at least two labels, not under .local
  [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
    && [[ "$1" != local && "$1" != *.local ]]
}

detect_domain() { # the site domain DHCP gave this host, from resolv.conf; nothing when there is none
  local conf=${KENLENS_RESOLV_CONF:-/etc/resolv.conf} d
  [[ -r "$conf" ]] || return 0
  for d in $(awk '$1 == "domain" { print $2 } $1 == "search" { for (i = 2; i <= NF; i++) print $i }' "$conf"); do
    d=$(printf '%s' "${d%.}" | tr 'A-Z' 'a-z')
    if valid_domain "$d"; then printf '%s' "$d"; return 0; fi
  done
}

if $no_domain && [[ ${#domains[@]} -gt 0 ]]; then die "--domain and --no-domain contradict each other"; fi

new_domains=""
domains_set=false
if $need_anchor_ca; then
  if $no_domain; then
    domains=()
  elif [[ ${#domains[@]} -eq 0 ]] && grep -qE '^KENLENS_ANCHOR_DOMAINS=' .env 2>/dev/null; then
    IFS=, read -r -a domains <<< "$(env_get KENLENS_ANCHOR_DOMAINS)"
  elif [[ ${#domains[@]} -eq 0 ]]; then
    detected=$(detect_domain)
    if $interactive; then
      answer=$(ask --domain "Site DNS domain(s) anchors are also reached under, comma-separated${detected:+ [$detected]} (- for .local only)")
      answer=${answer// /}
      [[ -n "$answer" ]] || answer=$detected
      [[ "$answer" != - ]] || answer=""
      IFS=, read -r -a domains <<< "$answer"
    elif [[ -n "$detected" ]]; then
      domains=("$detected")
      say "anchor console certificates will also name <anchor>.$detected (this host's DHCP domain);" \
          "--domain or --no-domain overrides it."
    fi
  fi
  for i in "${!domains[@]}"; do
    domains[i]=$(printf '%s' "${domains[i]}" | tr 'A-Z' 'a-z')
    domains[i]=${domains[i]#.}
    valid_domain "${domains[i]}" || die "'${domains[i]}' is not a DNS domain (e.g. asgard.qc.ca)"
  done
  new_domains=$(IFS=,; printf '%s' "${domains[*]}")
  domains_set=true
elif [[ ${#domains[@]} -gt 0 && "$(IFS=,; printf '%s' "${domains[*]}")" != "$(env_get KENLENS_ANCHOR_DOMAINS)" ]]; then
  say "warning: the anchor console CA already permits '$(env_get KENLENS_ANCHOR_DOMAINS)'; --domain" \
      "changed nothing. Re-issue it with --rotate anchor-ca."
fi

if [[ -e "$KEY_RING.crt" && ! -e "$KEY_RING.key" ]]; then
  die "$KEY_RING.key is missing but its certificate exists. Restore it from backup;" \
      "without it the server cannot open data/keys."
fi

need_web=false; need_broker=false
wants web "$SECRETS/server-cert.pfx" && need_web=true
wants broker "$TLS/mqtt-broker.crt" && need_broker=true

stored_hosts=$(env_get KENLENS_HOST)
new_hosts=""
if $need_web || $need_broker; then
  if [[ ${#hosts[@]} -eq 0 && -n "$stored_hosts" ]]; then
    IFS=, read -r -a hosts <<< "$stored_hosts"
  fi
  if [[ ${#hosts[@]} -eq 0 ]]; then
    answer=$(ask --host "Host name(s) and/or IP(s) of this machine, comma-separated")
    IFS=, read -r -a hosts <<< "${answer// /}"
  fi
  [[ ${#hosts[@]} -gt 0 && -n "${hosts[0]}" ]] || die "at least one --host is required"
  for h in "${hosts[@]}"; do
    [[ "$h" =~ ^[A-Za-z0-9.:-]+$ ]] || die "'$h' is not a host name or IP address"
  done
  new_hosts=$(IFS=,; printf '%s' "${hosts[*]}")
elif [[ ${#hosts[@]} -gt 0 && "$(IFS=,; printf '%s' "${hosts[*]}")" != "$stored_hosts" ]]; then
  say "warning: the certificates already name '$stored_hosts'; --host changed nothing." \
      "Re-issue them with --rotate web --rotate broker."
fi

# ---------------------------------------------------------------------------
# .env — created once from .env.example, afterwards only added to.
# ---------------------------------------------------------------------------

new_env=false
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 0600 .env
  env_set KENLENS_VERSION "$version"
  new_env=true
fi
[[ -z "$tag_height" ]] || env_set KENLENS_TAG_HEIGHT_METRES "$tag_height"
[[ -z "$new_https_port" ]] || env_set KENLENS_HTTPS_PORT "$new_https_port"
[[ -z "$new_hosts" ]]  || env_set KENLENS_HOST "$new_hosts"
! $domains_set         || env_set KENLENS_ANCHOR_DOMAINS "$new_domains"

# The memory timescaledb-tune sizes PostgreSQL for on first start. Left to
# itself the image reads it from the memory cgroup, and on a host without that controller —
# a Raspberry Pi, by default — it passes 0 MB and aborts the database's first start.
if [[ -z "$(env_get KENLENS_DB_TUNE_MEMORY)" ]]; then
  mem_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null || true)
  if [[ "$mem_kb" =~ ^[0-9]+$ ]]; then
    env_set KENLENS_DB_TUNE_MEMORY "$((mem_kb / 1024))MB"
  else
    say "warning: could not read MemTotal from /proc/meminfo; KENLENS_DB_TUNE_MEMORY not set."
  fi
fi

# ---------------------------------------------------------------------------
# Ownership — collected here, applied once at the end.
# ---------------------------------------------------------------------------

chown_postgres=()
chown_mosquitto=()

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

mkdir -p config/ca config/anchor-ca "$SECRETS" "$TLS" config/dataprotection
created=()
kept=()

write_secret() { # write_secret <file> <length-in-bytes> — hex, no trailing newline
  rm -f "$1"
  printf '%s' "$(openssl rand -hex "$2")" > "$1"
  chmod 0400 "$1"
}

if wants db-password "$SECRETS/db-password"; then
  write_secret "$SECRETS/db-password" 24; chown_postgres+=("$SECRETS/db-password"); created+=(db-password)
else kept+=(db-password); fi

if wants jwt-key "$SECRETS/jwt-key"; then
  write_secret "$SECRETS/jwt-key" 32; created+=(jwt-key)
else kept+=(jwt-key); fi

# The broker plugin's admin, which the server uses to manage broker users. The broker
# creates it from this file on its data volume's first start and never reads it again,
# so it is created once and never rotated. Created here on an upgrade too.
if [[ ! -e "$SECRETS/mqtt-admin-password" ]]; then
  write_secret "$SECRETS/mqtt-admin-password" 24; created+=(mqtt-admin-password)
else kept+=(mqtt-admin-password); fi

# ---------------------------------------------------------------------------
# Certificates — ECDSA P-256 throughout; one CA signs web, broker and Postgres.
# ---------------------------------------------------------------------------

if $ca_new; then
  rm -f "$CA_KEY" "$CA_CRT"
  openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$CA_KEY" -out "$CA_CRT" -days "$CA_DAYS" -subj "/CN=KenLens CA/O=KenLens" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:1" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" 2>/dev/null
  chmod 0400 "$CA_KEY"
  chmod 0444 "$CA_CRT"
  created+=(ca)
else kept+=(ca); fi

if $ca_new || [[ ! -e "$SECRETS/db-ca.crt" ]]; then
  rm -f "$SECRETS/db-ca.crt"
  cp "$CA_CRT" "$SECRETS/db-ca.crt"
  chmod 0400 "$SECRETS/db-ca.crt"
fi

san_for() { # san_for <extra-dns...> — subjectAltName built from the extras plus $hosts
  local entries=() h
  for h in "$@"; do entries+=("DNS:$h"); done
  for h in "${hosts[@]}"; do
    if [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ || "$h" == *:* ]]; then entries+=("IP:$h"); else entries+=("DNS:$h"); fi
  done
  local IFS=,
  printf '%s' "${entries[*]}"
}

issue() { # issue <key-out> <crt-out> <common-name> <subjectAltName>
  local key=$1 crt=$2 cn=$3 san=$4 csr ext
  csr=$(mktemp config/.csr.XXXXXX)
  ext=$(mktemp config/.ext.XXXXXX)
  rm -f "$key" "$crt"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$key" -out "$csr" -subj "/CN=$cn/O=KenLens" 2>/dev/null
  cat > "$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=$san
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
  openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$LEAF_DAYS" -extfile "$ext" \
    -out "$crt" 2>/dev/null
  rm -f "$csr" "$ext"
  chmod 0600 "$key"
  chmod 0444 "$crt"
}

if $need_web; then
  issue "$TLS/web.key" "$TLS/web.crt" "${hosts[0]}" "$(san_for)"
  write_secret "$SECRETS/cert-password" 24
  rm -f "$SECRETS/server-cert.pfx"
  openssl pkcs12 -export -inkey "$TLS/web.key" -in "$TLS/web.crt" -certfile "$CA_CRT" \
    -name kenlens-web -passout "file:$SECRETS/cert-password" -out "$SECRETS/server-cert.pfx"
  rm -f "$TLS/web.key"   # the PFX holds it
  chmod 0400 "$SECRETS/server-cert.pfx"
  created+=(web)
else kept+=(web); fi

if $need_broker; then
  issue "$TLS/mqtt-broker.key" "$TLS/mqtt-broker.crt" mqtt-broker "$(san_for mqtt-broker)"
  chown_mosquitto+=("$TLS/mqtt-broker.key")
  created+=(broker)
else kept+=(broker); fi

if wants postgres "$TLS/postgres.crt"; then
  issue "$TLS/postgres.key" "$TLS/postgres.crt" postgres "DNS:postgres"
  chown_postgres+=("$TLS/postgres.key")
  created+=(postgres)
else kept+=(postgres); fi

# ---------------------------------------------------------------------------
# Anchor console CA — the intermediate the server signs anchor console certificates with,
# unattended, so its key is mounted into the server; the CA's own key never is.
#
# Name-constrained: a stolen server key can mint certificates for anchor names under .local
# and the site's --domain values, and no IP address at all — never for another site. The
# constraint is NON-critical on purpose: the anchor's TLS stack (mbedTLS) refuses any
# certificate with a critical extension it cannot parse, nameConstraints included, and the
# anchor serves this certificate in its chain (uwbfirmware-anchor#84). OpenSSL and browsers
# enforce it either way.
# ---------------------------------------------------------------------------

if $need_anchor_ca; then
  constraints="permitted;DNS:.local"
  for d in "${domains[@]}"; do constraints+=",permitted;DNS:.$d"; done
  constraints+=",excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:::/::"
  csr=$(mktemp config/.csr.XXXXXX)
  ext=$(mktemp config/.ext.XXXXXX)
  rm -f "$ANCHOR_CA_KEY" "$ANCHOR_CA_CRT"
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$ANCHOR_CA_KEY" -out "$csr" -subj "/CN=KenLens Anchor Console CA/O=KenLens" 2>/dev/null
  cat > "$ext" <<EOF
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
nameConstraints=$constraints
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
  openssl x509 -req -in "$csr" -CA "$CA_CRT" -CAkey "$CA_KEY" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$ANCHOR_CA_DAYS" -extfile "$ext" \
    -out "$ANCHOR_CA_CRT" 2>/dev/null
  rm -f "$csr" "$ext"
  chmod 0400 "$ANCHOR_CA_KEY"
  chmod 0444 "$ANCHOR_CA_CRT"
  created+=(anchor-ca)
elif ! $ca_too_old; then kept+=(anchor-ca); fi

# ---------------------------------------------------------------------------
# Key-ring certificate — encrypts the server's Data Protection keys (data/keys) at rest,
# and those keys encrypt the stored MQTT password.
#
# RSA, unlike everything above: the server encrypts its key ring with XML encryption,
# which only accepts RSA. Self-signed, because nothing validates a chain for it.
# Deliberately not rotatable: every key it encrypted — and so the stored MQTT password —
# would become unreadable. Created here on an upgrade too; an existing one is never touched.
# ---------------------------------------------------------------------------

if [[ ! -e "$KEY_RING.crt" ]]; then
  rm -f "$KEY_RING.key"
  openssl req -x509 -new -newkey rsa:3072 -nodes \
    -keyout "$KEY_RING.key" -out "$KEY_RING.crt" -days "$KEY_RING_DAYS" \
    -subj "/CN=KenLens key ring/O=KenLens" 2>/dev/null
  chmod 0400 "$KEY_RING.key"
  chmod 0444 "$KEY_RING.crt"
  created+=(key-ring)
else kept+=(key-ring); fi

# The key ring itself. The server writes it; creating it here keeps it private (a missing
# bind-mount source is created by Docker as root, mode 0755).
#
# An install made before the key ring has exactly that: Docker created data/ as root when it
# filled in the missing ./data/floor-plans mount, so data/keys is created through a root
# container there. Root owning it is fine — the server runs as root.
if [[ ! -d data/keys ]]; then
  if [[ ! -e data || -w data ]]; then
    mkdir -p data/keys
    chmod 0700 data/keys
  else
    docker run --rm --user 0 --entrypoint /bin/sh -v "$DIR/data:/d" "$MOSQUITTO_IMAGE" \
      -c 'mkdir /d/keys && chmod 0700 /d/keys' \
      || die "could not create data/keys in the root-owned data/ through $MOSQUITTO_IMAGE"
  fi
fi

# Issue #244 — the uploaded web certificate. The server writes it; creating it here keeps it private
# (a missing bind-mount source is created by Docker as root, mode 0755).
if [[ ! -d data/web-tls ]]; then
  if [[ ! -e data || -w data ]]; then
    mkdir -p data/web-tls
    chmod 0700 data/web-tls
  else
    docker run --rm --user 0 --entrypoint /bin/sh -v "$DIR/data:/d" "$MOSQUITTO_IMAGE" \
      -c 'mkdir /d/web-tls && chmod 0700 /d/web-tls' \
      || die "could not create data/web-tls in the root-owned data/ through $MOSQUITTO_IMAGE"
  fi
fi

# Story 6.7 — the scheduled backups' directory, written by the backup service. Created here, by the
# operator, so Docker does not create it as root (a root-owned backups/ makes the next --update fail
# to chmod it). KENLENS_BACKUP_DIR names it when it is not ./backups; a custom one is the operator's.
sched_dir=$(env_get KENLENS_BACKUP_DIR)
if [[ -n "$sched_dir" ]]; then   # an explicit ./backups is the default, written out
  [[ "$sched_dir" == /* ]] && sched_dir=$(realpath -m -s -- "$sched_dir") || sched_dir=$(realpath -m -s -- "$DIR/$sched_dir")
fi
if [[ ( -z "$sched_dir" || "$sched_dir" == "$DIR/backups" ) && ! -d backups ]]; then
  mkdir -p backups
  chmod 0700 backups
fi

# Site time servers for the ntp service. Readable by chrony's user, which re-reads it on
# `chronyc reload sources`; created here so that Docker does not create it as root.
if [[ ! -d config/ntp ]]; then
  mkdir -p config/ntp
  chmod 0755 config/ntp
fi

# ---------------------------------------------------------------------------
# Ownership
# ---------------------------------------------------------------------------

in_mosquitto() { # in_mosquitto <sh-script> — runs with this directory's config/ at /c
  docker run --rm --user 0 --entrypoint /bin/sh -v "$DIR/config:/c" "$MOSQUITTO_IMAGE" -c "$1"
}

if [[ ${#chown_postgres[@]} -gt 0 || ${#chown_mosquitto[@]} -gt 0 ]]; then
  if [[ $EUID -eq 0 ]]; then
    [[ ${#chown_postgres[@]} -eq 0 ]]  || chown "$POSTGRES_UID:$POSTGRES_UID" "${chown_postgres[@]}"
    [[ ${#chown_mosquitto[@]} -eq 0 ]] || chown "$MOSQUITTO_UID:$MOSQUITTO_UID" "${chown_mosquitto[@]}"
  else
    script=":"
    for f in "${chown_postgres[@]}";  do script+=" && chown $POSTGRES_UID:$POSTGRES_UID /c/${f#config/}"; done
    for f in "${chown_mosquitto[@]}"; do script+=" && chown $MOSQUITTO_UID:$MOSQUITTO_UID /c/${f#config/}"; done
    in_mosquitto "$script" || die "could not set file owners through $MOSQUITTO_IMAGE"
  fi
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

$new_env && say "created .env (KENLENS_VERSION=$(env_get KENLENS_VERSION))"
[[ ${#created[@]} -eq 0 ]] || say "created: ${created[*]}"
[[ ${#kept[@]} -eq 0 ]]    || say "kept unchanged: ${kept[*]}"

if [[ -n "${rotate[db-password]:-}" ]]; then
  cat <<'EOF'

db-password was rotated. PostgreSQL reads that file only when its data volume is first
created, so an existing database still expects the OLD password. Apply the new one:

  docker compose up -d --force-recreate --wait postgres
  docker compose exec postgres sh -c \
    'psql -U kenlens -d kenlens -c "ALTER USER kenlens PASSWORD '\''$(cat /run/secrets/db-password)'\''"'
  docker compose up -d --force-recreate --wait kenlens-server
EOF
fi

if [[ -e "$OLD_PASSWD" ]]; then
  echo
  say "$OLD_PASSWD is no longer used: the server creates the broker's users itself." \
      "It can be deleted."
fi

if [[ -e "$OLD_MQTT_PASSWORD" ]]; then
  echo
  say "$OLD_MQTT_PASSWORD is no longer used: the server keeps its broker password with its" \
      "MQTT settings. It can be deleted."
fi

# The ntp service publishes UDP 123, which an NTP server already on the host holds. Ours, once
# started, holds it too, so only a stack that is not running is worth warning about.
if command -v ss >/dev/null && [[ -n "$(ss -Hlun 'sport = :123' 2>/dev/null)" ]] \
   && [[ -z "$(docker compose ps -q --status running ntp 2>/dev/null)" ]]; then
  echo
  say "something on this host already listens on UDP 123 (an NTP server such as chronyd or ntpd)," \
      "so the ntp service cannot start. Stop that server, or anchors will not set their clocks" \
      "from this host."
fi

if $ca_too_old; then
  echo
  say "no anchor console CA: config/ca/kenlens-ca.crt was made before anchor console" \
      "certificates and cannot sign one (it says pathlen:0). Anchors keep their self-signed" \
      "console certificates. To have KenLens issue them, re-create the CA with --rotate ca;" \
      "every browser and anchor then has to be given the new config/ca/kenlens-ca.crt."
fi

if [[ $rotations_requested -gt 0 ]]; then
  echo
  say "rotated files are picked up only by recreated containers: docker compose up -d --force-recreate"
fi
if $ca_new; then
  echo
  say "the KenLens CA is config/ca/kenlens-ca.crt — install it in browsers and give it to anchors." \
      "Back up config/ca/kenlens-ca.key: losing it means re-trusting a new CA everywhere."
fi

if $port_changed; then
  echo
  say "the HTTPS port is now $new_https_port; docker compose up -d applies it."
fi

first_host=$(env_get KENLENS_HOST)
first_host=${first_host%%,*}
[[ -n "$first_host" ]] && first_host=$(url_host "$first_host") || first_host="<host>"
echo
say "KenLens is at https://$first_host:$(env_get KENLENS_HTTPS_PORT)"
