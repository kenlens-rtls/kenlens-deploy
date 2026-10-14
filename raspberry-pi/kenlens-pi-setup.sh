#!/usr/bin/env bash
# KenLens on a Raspberry Pi — from a fresh Raspberry Pi OS Lite (64-bit) to a running KenLens.
#
# Checks the Pi, brings Raspberry Pi OS up to date, installs Docker from Docker's own packages,
# offers to turn Wi-Fi off when Ethernet is the way in, then downloads a KenLens release into
# /opt/kenlens, runs its kenlens-setup.sh and starts the stack. With --prepare-only it downloads
# the anchor bridge into /opt/kenlens-anchor-bridge instead, ready for its anchor-bridge-setup.sh. Run it as the user you created in
# Raspberry Pi Imager, not as root: it uses sudo for the steps that need it. Running it again
# skips every step already done; it never sets up over an existing installation.
#
#   bash kenlens-pi-setup.sh                             # asks for what it needs
#   bash kenlens-pi-setup.sh --prepare-only              # the Pi, Docker and the anchor bridge
#   bash kenlens-pi-setup.sh --host kenlens.lan --https-port 443 --wifi-off --non-interactive
#
# Options:
#   --prepare-only       For a Pi that runs the anchor bridge: prepare the Pi, install Docker and
#                        download the anchor bridge, but no KenLens. Neither the 4 GB of memory
#                        nor the SSD KenLens needs is checked, and Wi-Fi is not warned about.
#   --dir <path>         Where KenLens is installed; /opt/kenlens unless given. Upgrades must run
#                        from the same place: Docker names the database volume after it. With
#                        --prepare-only, where the anchor bridge goes; /opt/kenlens-anchor-bridge.
#   --version <vX.Y.Z>   The release to install; the latest one unless given.
#   --host <name|ip>     A name or address browsers and anchors use to reach this Pi; repeat for
#                        several. Unless given, it offers <hostname>.local and this Pi's address.
#   --domain <dns>       Passed to kenlens-setup.sh; repeatable.
#   --no-domain          Passed to kenlens-setup.sh.
#   --https-port <n>     Passed to kenlens-setup.sh; it asks when this is not given.
#   --wifi-off           Turn Wi-Fi off without asking when Ethernet carries the default route.
#   --keep-wifi          Leave Wi-Fi alone, and do not ask.
#   --allow-sd-card      Install KenLens, without asking, when the system runs from the SD card.
#                        Only KenLens needs an SSD: with --prepare-only an SD card is fine.
#   --non-interactive    Never prompt. A question with no flag to answer it takes the safe
#                        answer: Wi-Fi is left on, an SD card stops the script.
#   -h, --help           Show this help.
#
# What it changes on the Pi:
#
#   packages     apt-get update and full-upgrade; then docker-ce, docker-ce-cli, containerd.io,
#                docker-buildx-plugin and docker-compose-plugin from download.docker.com, after
#                removing the distribution's docker.io, docker-compose, podman-docker, containerd
#                and runc where installed (they conflict with Docker's packages)
#   apt          /etc/apt/keyrings/docker.asc and /etc/apt/sources.list.d/docker.sources
#   docker       the service enabled at boot; this user added to the docker group
#   Wi-Fi        turned off, only after asking or with --wifi-off (NetworkManager's radio switch,
#                which outlasts a reboot; `sudo nmcli radio wifi on` undoes it)
#   <dir>        created and given to this user; the release bundle, or with --prepare-only its
#                anchor-bridge folder, unpacked into it
#
# Needs bash, sudo, curl and tar, which Raspberry Pi OS has.

set -euo pipefail

readonly DEPLOY_REPO="kenlens-rtls/kenlens-deploy"
# Overridable so a test can stand GitHub, Docker's repository and the Pi in.
readonly GITHUB_API_URL="${GITHUB_API_URL:-https://api.github.com}"
readonly KENLENS_DOWNLOAD_URL="${KENLENS_DOWNLOAD_URL:-https://github.com/$DEPLOY_REPO/releases/download}"
readonly DOCKER_APT_URL="${KENLENS_PI_DOCKER_APT_URL:-https://download.docker.com/linux/debian}"
readonly APT_KEYRING="${KENLENS_PI_APT_KEYRING:-/etc/apt/keyrings/docker.asc}"
readonly APT_SOURCE="${KENLENS_PI_APT_SOURCE:-/etc/apt/sources.list.d/docker.sources}"
readonly PI_MODEL_FILE="${KENLENS_PI_MODEL_FILE:-/proc/device-tree/model}"
readonly OS_RELEASE="${KENLENS_PI_OS_RELEASE:-/etc/os-release}"
readonly MEMINFO="${KENLENS_PI_MEMINFO:-/proc/meminfo}"
readonly NET_DIR="${KENLENS_PI_NET_DIR:-/sys/class/net}"
readonly REBOOT_REQUIRED="${KENLENS_PI_REBOOT_REQUIRED:-/var/run/reboot-required}"
# A "4 GB" Pi reports about 3.7 GiB once the firmware has taken its share.
readonly MIN_MEM_KB=3500000
readonly DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly CONFLICTING_PACKAGES=(docker.io docker-doc docker-compose podman-docker containerd runc)
readonly READY_WAIT_SECONDS=120

prepare_only=false
dir=""
version=""
hosts=()
setup_args=()
wifi=""
allow_sd_card=false
interactive=true

die() { echo "kenlens-pi-setup: $*" >&2; exit 1; }
say() { echo "kenlens-pi-setup: $*"; }
step() { echo; echo "── $* ──"; }

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare-only)    prepare_only=true; shift ;;
    --dir)             [[ $# -ge 2 && -n "$2" ]] || die "--dir needs a path"; dir=$(realpath -m -- "$2"); shift 2 ;;
    --version)         [[ $# -ge 2 ]] || die "--version needs a release tag (vX.Y.Z)"
                       [[ "$2" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "'$2' is not a release tag (vX.Y.Z)"
                       version="$2"; shift 2 ;;
    --host)            [[ $# -ge 2 && -n "$2" ]] || die "--host needs a value"; hosts+=("$2"); shift 2 ;;
    --domain)          [[ $# -ge 2 && -n "$2" ]] || die "--domain needs a value"; setup_args+=(--domain "$2"); shift 2 ;;
    --no-domain)       setup_args+=(--no-domain); shift ;;
    --https-port)      [[ $# -ge 2 && -n "$2" ]] || die "--https-port needs a value"; setup_args+=(--https-port "$2"); shift 2 ;;
    --wifi-off)        [[ "$wifi" != keep ]] || die "--wifi-off and --keep-wifi contradict each other"; wifi=off; shift ;;
    --keep-wifi)       [[ "$wifi" != off ]] || die "--wifi-off and --keep-wifi contradict each other"; wifi=keep; shift ;;
    --allow-sd-card)   allow_sd_card=true; shift ;;
    --non-interactive) interactive=false; shift ;;
    -h|--help)         usage; exit 0 ;;
    *)                 die "unknown option '$1' (see --help)" ;;
  esac
done

if [[ -z "$dir" ]]; then
  if $prepare_only; then dir="/opt/kenlens-anchor-bridge"; else dir="/opt/kenlens"; fi
fi

(( EUID != 0 )) || die "run this as the user you log in with, not as root or with sudo: it uses sudo itself" \
                       "where it must, and adds that user to the docker group"
command -v sudo >/dev/null || die "sudo is required"
command -v curl >/dev/null || die "curl is required"
command -v tar  >/dev/null || die "tar is required"

# Prompting needs a terminal; without one, a missing answer is the safe one, not a hang.
[[ -t 0 ]] || interactive=false

confirm() { # confirm <question> — true on y/yes; never asks when non-interactive
  $interactive || return 1
  local answer
  read -r -p "$1 [y/N] " answer
  [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

os_field() { # os_field <KEY> → its value in os-release, unquoted
  sed -n "s/^$1=//p" "$OS_RELEASE" 2>/dev/null | tr -d '"' | head -n 1
}

# ---------------------------------------------------------------------------
step "Checking this Raspberry Pi"
# ---------------------------------------------------------------------------

model=""
[[ -r "$PI_MODEL_FILE" ]] && model=$(tr -d '\0' < "$PI_MODEL_FILE")
[[ "$model" == "Raspberry Pi"* ]] \
  || die "this is not a Raspberry Pi (no Raspberry Pi model in $PI_MODEL_FILE). On another Linux" \
         "host, install Docker and follow the install guide instead."
say "$model"

arch=$(uname -m)
[[ "$arch" == aarch64 ]] \
  || die "the system is $arch, not aarch64: KenLens needs the 64-bit Raspberry Pi OS. Write" \
         "Raspberry Pi OS Lite (64-bit) to the disk again with Raspberry Pi Imager."

os_id=$(os_field ID)
os_version=$(os_field VERSION_ID)
codename=$(os_field VERSION_CODENAME)
[[ "$os_id" == debian && "$os_version" =~ ^[0-9]+$ ]] && (( os_version >= 12 )) && [[ -n "$codename" ]] \
  || die "this is $(os_field PRETTY_NAME || true), not Raspberry Pi OS Bookworm or later" \
         "(Debian 12+). Write a current Raspberry Pi OS Lite (64-bit) with Raspberry Pi Imager."
say "$(os_field PRETTY_NAME), $arch"

mem_kb=$(awk '$1 == "MemTotal:" { print $2 }' "$MEMINFO" 2>/dev/null || true)
[[ "$mem_kb" =~ ^[0-9]+$ ]] || die "could not read MemTotal from $MEMINFO"
# Only KenLens needs 4 GB; the anchor bridge runs in well under 1 GB, on a Pi 3 too.
$prepare_only || (( mem_kb >= MIN_MEM_KB )) \
  || die "this Pi has $(( mem_kb / 1024 )) MiB of memory; KenLens needs a Pi with at least 4 GB"
say "$(( mem_kb / 1024 )) MiB of memory"

root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
# Only KenLens's database needs an SSD; a Pi prepared for the anchor bridge runs fine on its card.
if [[ "$root_source" == /dev/mmcblk* ]] && ! $prepare_only; then
  say "warning: the system runs from the SD card ($root_source). KenLens writes position history"
  say "         all the time: an SD card wears out under that and is slow enough to hold the"
  say "         database back. Use an SSD (see the guide)."
  $allow_sd_card || confirm "Install on the SD card anyway?" \
    || die "stopped: write Raspberry Pi OS to an SSD, or run again with --allow-sd-card"
else
  say "system disk: ${root_source:-unknown}"
fi

# sudo once up front, so its password prompt does not land in the middle of apt's output.
sudo -v || die "sudo did not accept this user; run as the user created in Raspberry Pi Imager"

# ---------------------------------------------------------------------------
step "Updating Raspberry Pi OS"
# ---------------------------------------------------------------------------

apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold "$@"; }

apt_get update || die "apt-get update failed: is this Pi on the network?"
apt_get full-upgrade || die "apt-get full-upgrade failed (see above)"
apt_get install ca-certificates curl openssl tar || die "could not install the basic tools (see above)"

# ---------------------------------------------------------------------------
step "Installing Docker"
# ---------------------------------------------------------------------------

installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }

missing=()
for p in "${DOCKER_PACKAGES[@]}"; do installed "$p" || missing+=("$p"); done
if [[ ${#missing[@]} -eq 0 ]]; then
  say "Docker's packages are already installed"
else
  conflicts=()
  for p in "${CONFLICTING_PACKAGES[@]}"; do installed "$p" && conflicts+=("$p"); done
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    say "removing the distribution's ${conflicts[*]}: Docker's own packages replace them"
    apt_get remove "${conflicts[@]}" || die "could not remove ${conflicts[*]} (see above)"
  fi
  say "adding Docker's repository for Debian $codename"
  sudo install -m 0755 -d "$(dirname "$APT_KEYRING")" "$(dirname "$APT_SOURCE")"
  sudo curl -fsSL -o "$APT_KEYRING" "$DOCKER_APT_URL/gpg" \
    || die "could not download Docker's signing key from $DOCKER_APT_URL/gpg"
  sudo chmod a+r "$APT_KEYRING"
  printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: stable\nArchitectures: arm64\nSigned-By: %s\n' \
    "$DOCKER_APT_URL" "$codename" "$APT_KEYRING" | sudo tee "$APT_SOURCE" >/dev/null
  apt_get update || die "apt-get update failed after adding Docker's repository (see above)"
  apt_get install "${DOCKER_PACKAGES[@]}" || die "could not install Docker (see above)"
fi
sudo systemctl enable --now docker || die "the docker service did not start; see: sudo journalctl -u docker"

if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  say "$USER is in the docker group"
else
  sudo usermod -aG docker "$USER" || die "could not add $USER to the docker group"
  say "added $USER to the docker group; it applies to the next login, this script does not wait for it"
fi

dock() { # dock <args...> — docker, through `sg docker` while this session predates the group
  if id -nG | tr ' ' '\n' | grep -qx docker; then
    docker "$@"
  else
    sg docker -c "$(printf '%q ' docker "$@")"
  fi
}

dock compose version >/dev/null 2>&1 || die "docker compose does not run; see: sudo journalctl -u docker"
say "$(dock --version)"

# ---------------------------------------------------------------------------
step "Checking the network"
# ---------------------------------------------------------------------------

# An interface on the anchors' network beside the one the anchors connect to makes the Pi answer
# them by another route; a stateful router then drops every MQTT session about a minute after it
# opens. Wi-Fi left on beside Ethernet is how that usually happens.
is_wireless() { [[ -d "$NET_DIR/$1/wireless" ]]; }

route_dev=$(ip route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')
wifi_up=()
for path in "$NET_DIR"/*; do
  iface=${path##*/}
  is_wireless "$iface" || continue
  [[ -n "$(ip -4 -o addr show dev "$iface" 2>/dev/null)" ]] && wifi_up+=("$iface")
done

if [[ -z "$route_dev" ]]; then
  say "warning: no default route: this Pi cannot reach the internet to download Docker images"
elif is_wireless "$route_dev"; then
  # Only the KenLens server answers the anchors; a Pi that runs the anchor bridge is fine on Wi-Fi.
  if $prepare_only; then
    say "on Wi-Fi ($route_dev)"
  else
    say "warning: this Pi reaches the network over Wi-Fi ($route_dev). Ethernet is recommended:"
    say "         connect it and run this again to turn Wi-Fi off."
  fi
elif [[ ${#wifi_up[@]} -eq 0 ]]; then
  say "on Ethernet ($route_dev), Wi-Fi off"
else
  say "on Ethernet ($route_dev), and Wi-Fi is also connected (${wifi_up[*]})."
  say "Two ways into one network make the anchors' MQTT connections drop every minute."
  if [[ "$wifi" == off ]] || { [[ "$wifi" != keep ]] && confirm "Turn Wi-Fi off? (sudo nmcli radio wifi on turns it back on)"; }; then
    if command -v nmcli >/dev/null; then
      sudo nmcli radio wifi off || die "could not turn Wi-Fi off"
    else
      sudo rfkill block wifi || die "could not turn Wi-Fi off"
    fi
    say "Wi-Fi is off"
  else
    say "Wi-Fi left on. If the Anchor fleet page's MQTT drops keep climbing, turn it off:"
    say "  sudo nmcli radio wifi off"
  fi
fi

take_dir() { # take_dir — $dir created if missing, and writable by this user
  if [[ ! -d "$dir" ]]; then
    sudo mkdir -p "$dir" || die "could not create $dir"
  fi
  if [[ ! -w "$dir" ]]; then
    sudo chown "$USER:" "$dir" || die "could not give $dir to $USER"
  fi
}

stage=""
trap '[[ -z "$stage" ]] || rm -rf "$stage"' EXIT
fetch_bundle() { # fetch_bundle [folder] — the release bundle, or one folder of it, unpacked into $dir
  local folder=${1:-} asset
  if [[ -z "$version" ]]; then
    version=$(curl -fsSL "$GITHUB_API_URL/repos/$DEPLOY_REPO/releases/latest" \
              | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p') \
      || die "could not get the latest release from $GITHUB_API_URL (no network, or GitHub's rate" \
             "limit for unauthenticated requests); name the release instead: --version vX.Y.Z"
    [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no latest release at $GITHUB_API_URL/repos/$DEPLOY_REPO"
  fi
  asset="kenlens-deploy-$version.tar.gz"
  say "downloading $asset"
  stage=$(mktemp -d "${TMPDIR:-/tmp}/kenlens-pi-setup.XXXXXX")
  curl -fsSL -o "$stage/$asset" "$KENLENS_DOWNLOAD_URL/$version/$asset" \
    || die "could not download $KENLENS_DOWNLOAD_URL/$version/$asset; is $version a published release?"
  # Readable by the containers, whose users are not this one.
  if [[ -n "$folder" ]]; then
    ( umask 022 && tar -xzf "$stage/$asset" -C "$dir" --strip-components=2 "kenlens-deploy-$version/$folder" ) \
      || die "$asset did not unpack its $folder/ into $dir"
  else
    ( umask 022 && tar -xzf "$stage/$asset" -C "$dir" --strip-components=1 ) \
      || die "$asset did not unpack into $dir"
  fi
}

bundle_version() { # bundle_version — the release the bundle in $dir was unpacked from
  sed -n 's/^KENLENS_VERSION=//p' "$dir/.env.example" 2>/dev/null | head -n 1
}

if $prepare_only; then
  # ---------------------------------------------------------------------------
  step "Downloading the anchor bridge"
  # ---------------------------------------------------------------------------

  take_dir
  if [[ -x "$dir/anchor-bridge-setup.sh" ]]; then
    say "the anchor bridge of $(bundle_version) is already in $dir"
    [[ -z "$version" ]] || say "warning: --version $version ignored; the bridge already in $dir is used"
  else
    [[ -z "$(ls -A "$dir")" ]] \
      || die "$dir is not empty and holds no anchor bridge; choose another place with --dir"
    fetch_bundle anchor-bridge
    [[ -x "$dir/anchor-bridge-setup.sh" ]] || die "kenlens-deploy-$version.tar.gz holds no anchor bridge"
    say "unpacked the anchor bridge of $version into $dir"
  fi

  echo
  say "the Pi is ready for KenLens."
  if ! id -nG | tr ' ' '\n' | grep -qx docker; then
    say "Log out and back in first, so the docker group applies. Then:"
  fi
  say "  cd $dir && ./anchor-bridge-setup.sh     to install the anchor bridge,"
  say "or follow the install guide for a full system install."
  if [[ -e "$REBOOT_REQUIRED" ]]; then
    say "The system update asks for a reboot; anchor-bridge-setup.sh offers one at its end."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
step "Installing KenLens"
# ---------------------------------------------------------------------------

if [[ -f "$dir/.env" ]]; then
  say "KenLens is already installed in $dir ($(sed -n 's/^KENLENS_VERSION=//p' "$dir/.env" | tail -n 1))."
  say "To upgrade it:  cd $dir && ./kenlens-setup.sh --update latest"
  exit 0
fi

take_dir
if [[ -x "$dir/kenlens-setup.sh" ]]; then
  # A previous run unpacked the bundle and stopped before kenlens-setup.sh finished.
  say "the bundle of $(bundle_version) is already in $dir"
  [[ -z "$version" ]] || say "warning: --version $version ignored; the bundle already in $dir is used"
else
  [[ -z "$(ls -A "$dir")" ]] \
    || die "$dir is not empty and holds no KenLens bundle; choose another place with --dir"
  fetch_bundle
  [[ -x "$dir/kenlens-setup.sh" ]] || die "kenlens-deploy-$version.tar.gz holds no kenlens-setup.sh: not a KenLens deploy bundle"
  say "unpacked $version into $dir"
fi

if [[ ${#hosts[@]} -eq 0 ]]; then
  address=$(hostname -I 2>/dev/null | awk '{ print $1 }') || true
  suggested="$(hostname).local${address:+,$address}"
  answer=""
  if $interactive; then
    read -r -p "Name(s) and/or address(es) browsers will use to reach this Pi, comma-separated [$suggested]: " answer
  fi
  answer=${answer// /}
  IFS=, read -r -a hosts <<< "${answer:-$suggested}"
  say "KenLens will answer as: ${hosts[*]}"
fi
for h in "${hosts[@]}"; do setup_args+=(--host "$h"); done
$interactive || setup_args+=(--non-interactive)

cd "$dir"
# kenlens-setup.sh runs docker; under sg it inherits this terminal, so it can still ask.
if id -nG | tr ' ' '\n' | grep -qx docker; then
  ./kenlens-setup.sh "${setup_args[@]}" || die "kenlens-setup.sh failed (see above); fix it and run this again"
else
  sg docker -c "$(printf '%q ' ./kenlens-setup.sh "${setup_args[@]}")" \
    || die "kenlens-setup.sh failed (see above); fix it and run this again"
fi

say "starting KenLens: the first start downloads the images and creates the database"
dock compose up -d --wait || die "the stack did not become healthy; see: cd $dir && docker compose logs"

port=$(sed -n 's/^KENLENS_HTTPS_PORT=//p' .env | tail -n 1)
port=${port:-8443}
host=${hosts[0]}
ready=""
for (( i = 0; i < READY_WAIT_SECONDS; i += 2 )); do
  ready=$(curl -fsS --cacert config/ca/kenlens-ca.crt --resolve "$host:$port:127.0.0.1" \
          "https://$host:$port/health/ready" 2>/dev/null) && break
  sleep 2
done
[[ "$ready" == Healthy ]] \
  || die "KenLens started but /health/ready did not answer Healthy; see: cd $dir && docker compose logs server"

echo
say "KenLens $(sed -n 's/^KENLENS_VERSION=//p' .env | tail -n 1) is running in $dir"
say ""
say "  Open  https://$host:$port"
say ""
say "The browser warns about the certificate until it trusts the KenLens CA: follow the link"
say "on the page to trust it, then create the first Admin and follow the first-run wizard."
say "Log out and back in before running docker commands yourself (the docker group applies then)."
if [[ -e "$REBOOT_REQUIRED" ]]; then
  say "The system update asks for a reboot; KenLens starts again by itself: sudo reboot"
fi
