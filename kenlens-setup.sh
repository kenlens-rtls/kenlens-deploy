#!/usr/bin/env bash
# KenLens host setup — Story 10.4 (spec §4, D8).
#
# Prepares this directory for `docker compose up -d`: a private KenLens CA, the three
# certificates it signs, every secret the stack reads, the Mosquitto password file and
# `.env`. Run it once per host, from anywhere; it always works on the directory it lives in.
#
#   ./kenlens-setup.sh                                   # asks for what it needs
#   ./kenlens-setup.sh --host kenlens.lan --host 192.168.1.20 --tag-height 1.2 \
#                      --non-interactive                 # CI, or a scripted install
#   ./kenlens-setup.sh --rotate broker                   # re-issue one item
#
# Options:
#   --host <name|ip>     A name or IPv4/IPv6 address browsers and anchors use to reach this
#                        host. Repeat for several. Goes into the web and broker certificates
#                        and is remembered in .env as KENLENS_HOST.
#   --tag-height <m>     The height tags are carried at, in metres (KENLENS_TAG_HEIGHT_METRES).
#                        No default: a guess makes every position wrong without any error.
#   --version <vX.Y.Z>   The release .env pins. Defaults to the one in .env.example.
#   --rotate <item>      Replace one existing item; repeatable. Items: ca, web, broker,
#                        postgres, db-password, jwt-key, mqtt-password. Rotating `ca`
#                        re-issues all three certificates with it.
#   --non-interactive    Never prompt; fail naming the missing flag instead.
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
#   config/secrets/                db-password, jwt-key, mqtt-password, cert-password,
#                                  server-cert.pfx (web), db-ca.crt (copy of the CA)
#   config/tls/                    postgres.{crt,key}, mqtt-broker.{crt,key}, web.crt
#   config/mosquitto/passwd        user `kenlens`, hashed by the broker image itself
#   .env                           KENLENS_VERSION, KENLENS_HOST, KENLENS_TAG_HEIGHT_METRES,
#                                  KENLENS_DB_TUNE_MEMORY
#
# Owners: postgres.key and db-password belong to uid 70 (the Postgres image's user),
# mqtt-broker.key and passwd to uid 1883 (Mosquitto's). Without root the script sets them
# through the broker image, so it never needs sudo.
#
# Needs bash, openssl and docker. No network access beyond pulling the broker image once.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR
# Keep in step with docker-compose.yml: passwd must be hashed by the broker that reads it.
readonly MOSQUITTO_IMAGE="eclipse-mosquitto:2.0"
readonly POSTGRES_UID=70
readonly MOSQUITTO_UID=1883
readonly MQTT_USER=kenlens
readonly CA_DAYS=3650
readonly LEAF_DAYS=825
readonly ROTATABLE="ca web broker postgres db-password jwt-key mqtt-password"

readonly CA_CRT="config/ca/kenlens-ca.crt"
readonly CA_KEY="config/ca/kenlens-ca.key"
readonly SECRETS="config/secrets"
readonly TLS="config/tls"
readonly PASSWD="config/mosquitto/passwd"

hosts=()
tag_height=""
version=""
interactive=true
declare -A rotate=()

die() { echo "kenlens-setup: $*" >&2; exit 1; }
say() { echo "kenlens-setup: $*"; }

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)            [[ $# -ge 2 ]] || die "--host needs a value"; hosts+=("$2"); shift 2 ;;
    --tag-height)      [[ $# -ge 2 ]] || die "--tag-height needs a value"; tag_height="$2"; shift 2 ;;
    --version)         [[ $# -ge 2 ]] || die "--version needs a value"; version="$2"; shift 2 ;;
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
      "To upgrade, edit KENLENS_VERSION in .env, then docker compose pull && docker compose up -d."
  version=""
fi

if [[ -z "$(env_get KENLENS_TAG_HEIGHT_METRES)" ]]; then
  [[ -n "$tag_height" ]] || tag_height=$(ask --tag-height \
    "Height tags are carried at, in metres (measured, same frame as the anchor survey)")
  if ! [[ "$tag_height" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! awk -v h="$tag_height" 'BEGIN { exit !(h > 0) }'; then
    die "tag height '$tag_height' is not a positive number of metres"
  fi
elif [[ -n "$tag_height" && "$tag_height" != "$(env_get KENLENS_TAG_HEIGHT_METRES)" ]]; then
  say "warning: .env already sets KENLENS_TAG_HEIGHT_METRES=$(env_get KENLENS_TAG_HEIGHT_METRES);" \
      "--tag-height $tag_height ignored. Edit .env to change it."
  tag_height=""
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
  rotate[web]=1; rotate[broker]=1; rotate[postgres]=1
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
[[ -z "$new_hosts" ]]  || env_set KENLENS_HOST "$new_hosts"

# The memory timescaledb-tune sizes PostgreSQL for on first start (issue #229). Left to
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

mkdir -p config/ca "$SECRETS" "$TLS" config/mosquitto
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

mqtt_password_new=false
if wants mqtt-password "$SECRETS/mqtt-password"; then
  write_secret "$SECRETS/mqtt-password" 24; mqtt_password_new=true; created+=(mqtt-password)
else kept+=(mqtt-password); fi

# ---------------------------------------------------------------------------
# Certificates — ECDSA P-256 throughout; one CA signs web, broker and Postgres (D8).
# ---------------------------------------------------------------------------

if $ca_new; then
  rm -f "$CA_KEY" "$CA_CRT"
  openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$CA_KEY" -out "$CA_CRT" -days "$CA_DAYS" -subj "/CN=KenLens CA/O=KenLens" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
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
# Mosquitto password file — hashed by the broker image, then owned by its user.
# ---------------------------------------------------------------------------

in_mosquitto() { # in_mosquitto <sh-script> — runs with this directory's config/ at /c
  docker run --rm --user 0 --entrypoint /bin/sh -v "$DIR/config:/c" "$MOSQUITTO_IMAGE" -c "$1"
}

if $mqtt_password_new || [[ ! -e "$PASSWD" ]]; then
  plain=$(mktemp config/mosquitto/.passwd.XXXXXX)
  printf '%s:%s\n' "$MQTT_USER" "$(cat "$SECRETS/mqtt-password")" > "$plain"
  rel=${plain#config/}
  # -U hashes the file in place, so the password never appears on a command line.
  in_mosquitto "mosquitto_passwd -U /c/$rel 2>/dev/null && chmod 0600 /c/$rel && chown $MOSQUITTO_UID:$MOSQUITTO_UID /c/$rel" \
    || { rm -f "$plain"; die "mosquitto_passwd failed in $MOSQUITTO_IMAGE"; }
  mv -f "$plain" "$PASSWD"
  created+=(mosquitto-passwd)
fi

# ---------------------------------------------------------------------------
# Ownership
# ---------------------------------------------------------------------------

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

if [[ $rotations_requested -gt 0 ]]; then
  echo
  say "rotated files are picked up only by recreated containers: docker compose up -d --force-recreate"
fi
if $ca_new; then
  echo
  say "the KenLens CA is config/ca/kenlens-ca.crt — install it in browsers and give it to anchors." \
      "Back up config/ca/kenlens-ca.key: losing it means re-trusting a new CA everywhere."
fi
