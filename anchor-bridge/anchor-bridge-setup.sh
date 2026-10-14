#!/usr/bin/env bash
# KenLens anchor bridge setup.
#
# Prepares this directory and this host for the anchor bridge, then starts it: writes .env, on a
# Raspberry Pi offers the serial settings the 26-pin header needs, pulls the image, starts the
# container and prints where the manager is with its one-time setup token. Run it from anywhere;
# it always works on the directory it lives in. Running it again changes only what is missing.
#
#   ./anchor-bridge-setup.sh                         # asks before changing anything on the host
#   ./anchor-bridge-setup.sh --pi-serial default --non-interactive    # a scripted Pi install
#   ./anchor-bridge-setup.sh --update latest         # upgrade to a release (or --update vX.Y.Z)
#   ./anchor-bridge-setup.sh --version               # the release installed here
#
# Options:
#   --pi-serial <mode>   On a Raspberry Pi, apply the header serial settings without asking:
#                        the UART on, no login console on it, and how the Pi's one full UART is
#                        shared with its onboard Bluetooth (Pi 3 and 4):
#                          default       Bluetooth keeps the full UART, the header gets the
#                                        mini-UART (/dev/ttyS0). Recommended.
#                          disable-bt    no onboard Bluetooth; the header gets the full UART.
#                          miniuart-bt   Bluetooth on the mini-UART, the header on the full UART.
#                        On other Pi models only `default` is accepted (no Bluetooth choice).
#   --no-pi-serial       Leave the Pi's serial settings alone, and do not ask.
#   --serial-gid <n>     The group owning the serial device nodes, as a number. Found by itself
#                        unless given: the owner of /dev/serial0, else of a /dev/serial/by-id/
#                        link, else the host's dialout (or uucp) group. Kept in .env.
#   --manager-port <n>   The port the manager UI is reached on; 8440 unless given. Kept in .env.
#   --version            Alone, with no value: print the release installed here (the
#                        KENLENS_VERSION .env pins) and exit; nothing else on the line runs.
#   --version <vX.Y.Z>   On a fresh install, the release .env pins. Defaults to the one in
#                        .env.example.
#   --update <tag>       Upgrade (or downgrade) to a release: downloads that release's bundle from
#                        GitHub, checks it, unpacks its anchor-bridge/ folder over this directory
#                        (never touching .env), pins KENLENS_VERSION and runs the new script once,
#                        which pulls and restarts the bridge. <tag> is vX.Y.Z or `latest`. Takes
#                        no other option. The anchors live in the anchor-bridge-data volume,
#                        which an update never touches.
#   --non-interactive    Never prompt. Without --pi-serial the Pi's settings are then left alone,
#                        and the script says what it would have changed.
#   -h, --help           Show this help.
#
# What it changes on a Raspberry Pi, only after asking (or with --pi-serial), each file backed up
# first as <file>.pre-anchor-bridge:
#
#   config.txt     enable_uart=1, and the Bluetooth overlay of the chosen mode, in one marked
#                  block at the end; any other enable_uart or Bluetooth overlay line is removed
#   cmdline.txt    the login console on the serial port (console=serial0,115200) removed
#   rfkill         the onboard Bluetooth unblocked when the chosen mode keeps it and it is
#                  soft-blocked
#
# Both files are in /boot/firmware (or /boot on an older Raspberry Pi OS) and take effect at the
# next reboot, which it offers as its last step, once the bridge is installed and started. Writing them needs root: it uses sudo when not run as root.
#
# Needs bash and docker with the compose plugin; --update also curl and tar.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DIR
readonly DEFAULT_MANAGER_PORT=8440
readonly DEPLOY_REPO="kenlens-rtls/kenlens-deploy"
# Overridable so a test can stand GitHub, the Pi and its boot partition in.
readonly GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
readonly KENLENS_DOWNLOAD_URL="${KENLENS_DOWNLOAD_URL:-https://github.com/$DEPLOY_REPO/releases/download}"
readonly PI_MODEL_FILE="${ANCHOR_BRIDGE_PI_MODEL_FILE:-/proc/device-tree/model}"
readonly SERIAL0="${ANCHOR_BRIDGE_SERIAL0:-/dev/serial0}"
readonly BY_ID_DIR="${ANCHOR_BRIDGE_BY_ID_DIR:-/dev/serial/by-id}"
readonly RFKILL_DIR="${ANCHOR_BRIDGE_RFKILL_DIR:-/sys/class/rfkill}"
readonly PROC_CMDLINE="${ANCHOR_BRIDGE_PROC_CMDLINE:-/proc/cmdline}"
readonly MARK_BEGIN="# >>> anchor-bridge-setup.sh: the serial port on the 26-pin header"
readonly MARK_END="# <<< anchor-bridge-setup.sh"
readonly BACKUP_SUFFIX=".pre-anchor-bridge"
readonly TOKEN_WAIT_SECONDS=60

version=""
update_tag=""
pi_serial=""
no_pi_serial=false
serial_gid=""
manager_port=""
interactive=true

die() { echo "anchor-bridge-setup: $*" >&2; exit 1; }
say() { echo "anchor-bridge-setup: $*"; }

pi_model() { # the board's model string, or nothing when this is not a Raspberry Pi
  [[ -r "$PI_MODEL_FILE" ]] || return 0
  local model
  model=$(tr -d '\0' < "$PI_MODEL_FILE")
  [[ "$model" == "Raspberry Pi"* ]] && printf '%s' "$model"
  return 0
}

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pi-serial)       [[ $# -ge 2 ]] || die "--pi-serial needs a mode: default, disable-bt or miniuart-bt"
                       [[ "$2" =~ ^(default|disable-bt|miniuart-bt)$ ]] \
                         || die "--pi-serial '$2' is not a mode: default, disable-bt or miniuart-bt"
                       pi_serial="$2"; shift 2 ;;
    --no-pi-serial)    no_pi_serial=true; shift ;;
    --serial-gid)      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || die "--serial-gid needs a group number"
                       serial_gid="$2"; shift 2 ;;
    --manager-port)    [[ $# -ge 2 ]] || die "--manager-port needs a value"; manager_port="$2"; shift 2 ;;
    --version)         if [[ $# -lt 2 || "$2" == -* ]]; then show_version; exit 0; fi
                       version="$2"; shift 2 ;;
    --update)          [[ $# -ge 2 && -n "$2" ]] || die "--update needs a release tag (vX.Y.Z) or 'latest'"
                       update_tag="$2"; shift 2 ;;
    --non-interactive) interactive=false; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown option '$1' (see --help)" ;;
  esac
done
[[ -z "$pi_serial" || $no_pi_serial == false ]] || die "--pi-serial and --no-pi-serial contradict each other"

# On a Pi, the KenLens Pi script installs Docker (issue #331); elsewhere, Docker's own instructions.
docker_how() {
  if [[ -n "$(pi_model)" ]]; then
    printf '%s' "on a Raspberry Pi, install it with: curl -fsSLO https://raw.githubusercontent.com/$DEPLOY_REPO/main/raspberry-pi/kenlens-pi-setup.sh && bash kenlens-pi-setup.sh --prepare-only, then sign in again"
  else
    printf '%s' "install Docker Engine (see the README)"
  fi
}
command -v docker >/dev/null || die "docker is required: $(docker_how)"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is required: $(docker_how)"

cd "$DIR"
umask 077

# Prompting needs a terminal; without one, a missing answer is the safe one, not a hang.
[[ -t 0 ]] || interactive=false

confirm() { # confirm <question> — true on y/yes; never asks when non-interactive
  $interactive || return 1
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
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

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

# ---------------------------------------------------------------------------
# --update — fetch a release's bundle, apply its anchor-bridge/ folder here, run it.
#
# It exits the process itself: once the folder is unpacked over this directory THIS FILE has
# been replaced, and bash reads a script as it runs it, so nothing after the call may ever
# execute from the old file. Everything is checked in a temporary directory first.
# ---------------------------------------------------------------------------

update_stage=""
update() { # update <tag|latest> — never returns
  local tag=$1 current asset pinned f src
  [[ -f .env ]] || die "nothing is installed in $DIR (no .env); follow the README first"
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
  if [[ "$tag" == "$current" && "$tag" == "$(sed -n 's/^KENLENS_VERSION=//p' .env.example 2>/dev/null)" ]]; then
    say "already on $tag; nothing to do"
    exit 0
  fi

  umask 022
  update_stage=$(mktemp -d "${TMPDIR:-/tmp}/anchor-bridge-update.XXXXXX")
  trap 'rm -rf "$update_stage"' EXIT
  asset="kenlens-deploy-$tag.tar.gz"
  say "downloading $asset"
  curl -fsSL -o "$update_stage/$asset" "$KENLENS_DOWNLOAD_URL/$tag/$asset" \
    || die "could not download $KENLENS_DOWNLOAD_URL/$tag/$asset; is $tag a published release? Nothing was changed."
  mkdir "$update_stage/bundle"
  tar -xzf "$update_stage/$asset" -C "$update_stage/bundle" --strip-components=1 \
    || die "$asset did not unpack; nothing was changed"
  src="$update_stage/bundle/anchor-bridge"
  [[ -d "$src" ]] || die "$asset has no anchor-bridge/ folder (releases before the anchor bridge" \
                         "bundle have none); nothing was changed"
  for f in anchor-bridge-setup.sh docker-compose.yml .env.example; do
    [[ -f "$src/$f" ]] || die "$asset holds no anchor-bridge/$f; nothing was changed"
  done
  pinned=$(sed -n 's/^KENLENS_VERSION=//p' "$src/.env.example" | head -n 1)
  [[ "$pinned" == "$tag" ]] || die "$asset's anchor-bridge/ is pinned to '$pinned', not $tag; nothing was changed"
  [[ ! -e "$src/.env" ]] || die "$asset carries anchor-bridge/.env, which a bundle never does; nothing was changed"

  # From here this file is gone: see the banner above.
  cp -R "$src/." "$DIR/" \
    || die "copying the $tag bundle into $DIR failed part-way (see above): this directory now holds" \
           "files from two releases and .env still pins $current. Fix the cause, then run --update $tag again."
  env_set KENLENS_VERSION "$tag"
  say "applied the $tag bundle; starting it with its setup script"
  "$DIR/anchor-bridge-setup.sh" --non-interactive </dev/null \
    || die "the $tag setup script failed; the bundle is in place and .env pins $tag"
  exit 0
}

if [[ -n "$update_tag" ]]; then
  [[ -z "$version" && -z "$pi_serial" && $no_pi_serial == false && -z "$serial_gid" && -z "$manager_port" ]] \
    || die "--update takes no other option"
  update "$update_tag"
fi

# ---------------------------------------------------------------------------
# .env — every value settled before the file is written.
# ---------------------------------------------------------------------------

if [[ ! -f .env ]]; then
  [[ -f .env.example ]] || die ".env.example is missing from $DIR — is this the anchor-bridge folder of a KenLens deploy bundle?"
  [[ -n "$version" ]] || version=$(sed -n 's/^KENLENS_VERSION=//p' .env.example | head -n 1)
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version '$version' is not vX.Y.Z"
elif [[ -n "$version" && "$version" != "$(env_get KENLENS_VERSION)" ]]; then
  say "warning: .env already pins $(env_get KENLENS_VERSION); --version $version ignored." \
      "To upgrade, run ./anchor-bridge-setup.sh --update $version."
  version=""
fi

[[ -z "$manager_port" ]] || valid_port "$manager_port" || die "manager port '$manager_port' is not a port number (1-65535)"
if [[ -n "$manager_port" ]] && (( 10#$manager_port >= 8441 && 10#$manager_port <= 8456 )); then
  die "manager port $manager_port is one of the anchors' console ports (8441-8456)"
fi

find_serial_gid() { # the group owning this host's serial device nodes, as a number, or nothing
  local link group
  if [[ -e "$SERIAL0" ]]; then stat -Lc %g "$SERIAL0"; return; fi
  for link in "$BY_ID_DIR"/*; do
    [[ -e "$link" ]] && { stat -Lc %g "$link"; return; }
  done
  for group in dialout uucp; do
    getent group "$group" | cut -d: -f3 | grep . && return
  done
  return 0
}
if [[ -z "$serial_gid" ]]; then
  serial_gid=$(env_get SERIAL_BRIDGE_GID)
  [[ -n "$serial_gid" ]] || serial_gid=$(find_serial_gid)
  [[ "$serial_gid" =~ ^[0-9]+$ ]] \
    || die "could not tell which group owns the serial ports here; give it: --serial-gid <n>" \
           "(\`stat -Lc %g\` of the board's device node)"
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 0600 .env
  env_set KENLENS_VERSION "$version"
  say "wrote .env pinned to $version"
fi
[[ "$(env_get SERIAL_BRIDGE_GID)" == "$serial_gid" ]] || { env_set SERIAL_BRIDGE_GID "$serial_gid"; say "serial ports: group $serial_gid"; }
if [[ -n "$manager_port" && "$(env_get ANCHOR_BRIDGE_MANAGER_PORT)" != "$manager_port" ]]; then
  env_set ANCHOR_BRIDGE_MANAGER_PORT "$manager_port"
  say "manager port: $manager_port"
fi

# ---------------------------------------------------------------------------
# Raspberry Pi — the header's serial port. Nothing is written without a yes or --pi-serial.
# ---------------------------------------------------------------------------

reboot_needed=false

boot_dir() { # where config.txt and cmdline.txt are
  if [[ -n "${ANCHOR_BRIDGE_BOOT_DIR:-}" ]]; then printf '%s' "$ANCHOR_BRIDGE_BOOT_DIR"
  elif [[ -f /boot/firmware/config.txt ]]; then printf '/boot/firmware'
  else printf '/boot'
  fi
}

as_root() { # as_root <path> <command...> — directly when the path is writable, else sudo
  local path=$1; shift
  if [[ -w "$path" ]] || (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

# config.txt as the chosen mode wants it: every enable_uart line and Bluetooth overlay removed,
# a previous block of ours too, then one marked block at the end. [all] opens the block so a
# conditional section above it (e.g. [cm4]) never captures it.
wanted_config() { # wanted_config <config.txt> <mode>
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    skip { if ($0 == e) skip = 0; next }
    /^[[:space:]]*enable_uart=/ { next }
    /^[[:space:]]*dtoverlay=(pi3-)?(disable-bt|miniuart-bt)([[:space:],]|$)/ { next }
    { print }
  ' "$1"
  printf '%s\n[all]\nenable_uart=1\n' "$MARK_BEGIN"
  [[ "$2" == default ]] || printf 'dtoverlay=%s\n' "$2"
  printf '%s\n' "$MARK_END"
}

wanted_cmdline() { # wanted_cmdline <cmdline.txt> — without a console on a serial port
  sed -E 's/(^| )console=(serial0|serial1|ttyS0|ttyAMA0),[0-9]+( |$)/\1/; s/ +$//' "$1"
}

current_mode() { # current_mode <config.txt> — the Bluetooth overlay in effect, as a mode
  local overlay
  overlay=$(sed -nE 's/^[[:space:]]*dtoverlay=(pi3-)?(disable-bt|miniuart-bt)([[:space:],].*)?$/\2/p' "$1" | tail -n 1)
  printf '%s' "${overlay:-default}"
}

# Read from sysfs, not the rfkill command, which Raspberry Pi OS does not always install. Writing
# `soft` is what `rfkill unblock` does, and systemd-rfkill keeps the state across reboots.
blocked_bluetooth() { # the rfkill switches of soft-blocked Bluetooth adapters, one per line
  local switch
  for switch in "$RFKILL_DIR"/rfkill*; do
    [[ -r "$switch/type" && -r "$switch/soft" ]] || continue
    [[ "$(cat "$switch/type")" == bluetooth && "$(cat "$switch/soft")" == 1 ]] && printf '%s\n' "$switch"
  done
  return 0
}

prepare_pi() {
  local model boot config cmdline mode has_bt_choice=false new_config new_cmdline changes=() f
  model=$(pi_model)
  [[ -n "$model" ]] || return 0
  boot=$(boot_dir)
  config="$boot/config.txt"
  cmdline="$boot/cmdline.txt"
  say "this is a $model"
  if $no_pi_serial; then say "--no-pi-serial: leaving its serial settings alone"; return 0; fi
  [[ -f "$config" && -f "$cmdline" ]] \
    || { say "warning: no config.txt and cmdline.txt in $boot; set the serial port up by hand (see the README)"; return 0; }
  [[ "$model" =~ ^Raspberry\ Pi\ [34]\  ]] && has_bt_choice=true

  # Set up already — by an earlier run, or by hand to the same effect — is not asked again: a rerun
  # changes the mode only with --pi-serial (issue #332).
  local set_up=false
  if grep -qxF "$MARK_BEGIN" "$config" && grep -qE '^[[:space:]]*enable_uart=1[[:space:]]*$' "$config" \
     && [[ "$(wanted_cmdline "$cmdline")" == "$(cat "$cmdline")" ]]; then
    set_up=true
  fi

  mode=$pi_serial
  if [[ -z "$mode" ]]; then
    mode=$(current_mode "$config")
    if $has_bt_choice && $interactive && ! $set_up; then
      echo
      echo "The Pi has one full UART, which it gives to its onboard Bluetooth. For the header:"
      echo "  1) default      Bluetooth keeps it; the header gets the mini-UART. Recommended."
      echo "  2) disable-bt   no onboard Bluetooth; the header gets the full UART."
      echo "  3) miniuart-bt  Bluetooth on the mini-UART; the header gets the full UART."
      local answer
      read -r -p "Which one? [${mode}] " answer
      case "$answer" in
        "")                 ;;
        1|default)          mode=default ;;
        2|disable-bt)       mode=disable-bt ;;
        3|miniuart-bt)      mode=miniuart-bt ;;
        *)                  die "'$answer' is not one of the three; nothing was changed" ;;
      esac
    fi
  fi
  $has_bt_choice || [[ "$mode" == default ]] \
    || die "--pi-serial $mode is for a Pi 3 or 4; this $model takes only 'default'"

  new_config=$(mktemp)
  new_cmdline=$(mktemp)
  if ! grep -qxF "$MARK_BEGIN" "$config" || [[ "$(current_mode "$config")" != "$mode" ]] \
     || ! grep -qE '^[[:space:]]*enable_uart=1[[:space:]]*$' "$config"; then
    wanted_config "$config" "$mode" > "$new_config"
    cmp -s "$config" "$new_config" || changes+=("config.txt: the header UART on, Bluetooth mode $mode")
  fi
  wanted_cmdline "$cmdline" > "$new_cmdline"
  cmp -s "$cmdline" "$new_cmdline" || changes+=("cmdline.txt: no login console on the serial port")

  if (( ${#changes[@]} > 0 )); then
    echo
    say "the header's serial port needs, in $boot:"
    printf '  - %s\n' "${changes[@]}"
    if [[ -z "$pi_serial" ]] && ! confirm "Apply these changes (each file is backed up first)?"; then
      say "left the serial settings as they were; /dev/serial0 will not carry the board until they" \
          "are set (run this again, or see the README's Pi preparation)"
    else
      for f in config.txt cmdline.txt; do
        [[ -e "$boot/$f$BACKUP_SUFFIX" ]] || as_root "$boot" cp -p "$boot/$f" "$boot/$f$BACKUP_SUFFIX"
      done
      [[ ! -s "$new_config" ]] || as_root "$boot" cp "$new_config" "$config"
      as_root "$boot" cp "$new_cmdline" "$cmdline"
      say "applied; the originals are kept as *$BACKUP_SUFFIX in $boot"
      reboot_needed=true
    fi
  else
    say "the header's serial port is already set up (Bluetooth mode $mode)"
    if $has_bt_choice && [[ -z "$pi_serial" ]]; then
      say "... to change the mode: ./anchor-bridge-setup.sh --pi-serial default|disable-bt|miniuart-bt"
    fi
    # Set up in the files, but the running kernel still has the old settings: a reboot is pending.
    if [[ ! -e "$SERIAL0" ]] || grep -qE '(^| )console=(serial0|serial1|ttyS0|ttyAMA0),' "$PROC_CMDLINE" 2>/dev/null; then
      say "... but not in effect yet: the Pi has not rebooted since"
      reboot_needed=true
    fi
  fi
  rm -f "$new_config" "$new_cmdline"

  local blocked
  blocked=$(blocked_bluetooth)
  if [[ "$mode" != disable-bt && -n "$blocked" ]]; then
    if [[ -n "$pi_serial" ]] || confirm "The onboard Bluetooth is blocked (rfkill). Unblock it?"; then
      for f in $blocked; do
        echo 0 | as_root "$f/soft" tee "$f/soft" >/dev/null
      done
      say "unblocked the onboard Bluetooth"
    else
      say "the onboard Bluetooth stays blocked; an anchor cannot use it until \`sudo rfkill unblock bluetooth\`"
    fi
  fi
}
prepare_pi

# ---------------------------------------------------------------------------
# Start, and say where the manager is.
# ---------------------------------------------------------------------------

say "pulling the $(env_get KENLENS_VERSION) image"
docker compose pull || die "docker compose pull failed; run it again, then docker compose up -d"
docker compose up -d --wait --remove-orphans || die "the bridge did not start; see docker compose logs"

host=$(hostname -I 2>/dev/null | awk '{ print $1 }') || true
port=$(env_get ANCHOR_BRIDGE_MANAGER_PORT)
url="https://${host:-<this host>}:${port:-$DEFAULT_MANAGER_PORT}"

# The reboot comes last: the bridge is already installed and comes back by itself (restart policy),
# and it sees /dev/serial0 appear through the /dev it mounts. The setup token is not printed then:
# the manager draws a new one on every start, so the one from before the reboot would not work.
if $reboot_needed; then
  say "the anchor bridge $(env_get KENLENS_VERSION) is installed; it starts again by itself after the reboot"
  say "manager: $url"
  say "setup token, after the reboot: cd $DIR && docker compose logs anchor-bridge | grep \"setup token\""
  if confirm "The serial settings take effect at the next reboot. Reboot now?"; then
    say "rebooting"
    as_root / reboot
    exit 0
  fi
  say "reboot before creating an anchor on /dev/serial0: sudo reboot"
  exit 0
fi

token=""
for (( i = 0; i < TOKEN_WAIT_SECONDS; i++ )); do
  token=$(docker compose logs --no-log-prefix anchor-bridge 2>/dev/null \
          | sed -n 's/.*setup token "\{0,1\}\([0-9a-f]\{8,\}\)"\{0,1\}.*/\1/p' | tail -n 1) || true
  [[ -z "$token" ]] || break
  # No token once a password is chosen: the manager says "Listening" instead.
  docker compose logs --no-log-prefix anchor-bridge 2>/dev/null | grep -q 'Now listening' && break
  sleep 1
done
say "the anchor bridge $(env_get KENLENS_VERSION) is running"
say "manager: $url"
if [[ -n "$token" ]]; then
  say "setup token: $token  — enter it there to choose the manager password"
else
  say "sign in there with the manager password"
fi
