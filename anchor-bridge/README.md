# KenLens anchor bridge

The anchor bridge turns UWB boards plugged into a host into **anchors** that KenLens onboards
exactly as it onboards a networked anchor. The most common host is a Raspberry Pi with a
DWM1001-DEV seated on its header. The bridge reads each board's serial link, and for each board
it publishes the anchor topics on KenLens's MQTT broker and serves an anchor console. Using the
host's Bluetooth, it also reports the tags it hears and runs KenLens's configuration jobs and
firmware updates.

It runs as one container, on any host that can reach KenLens's broker over the network. That
host is usually not the KenLens host. This folder is all you need. Once an anchor is created, the
[onboarding guide](https://github.com/kenlens-rtls/kenlens-deploy/wiki/Onboard-a-bridged-anchor)
takes it into KenLens.

- [Requirements](#requirements)
- [Raspberry Pi preparation](#raspberry-pi-preparation)
- [Install](#install)
- [Ports](#ports)
- [Uninstall](#uninstall)

## Requirements

**Host.** One of these:

- a **Raspberry Pi 3 or 4**, with **64-bit Raspberry Pi OS** (Bookworm or later). `uname -m` must
  print `aarch64`, because there is no 32-bit image. The bridge itself needs well under 1 GB of
  RAM. On a Pi 5 the header's UART is not `/dev/serial0`, so use a board on USB there;
- any other 64-bit Linux host that runs Docker, `amd64` or `arm64`, with its boards on USB.

**Boards.** Each anchor is one UWB board running KenLens's UWB firmware as an anchor. The
firmware comes with each release; [UWB boards](../uwb-boards/) flashes a board and gives it its
role:

| Board | Connection | Shown in the manager as |
|---|---|---|
| DWM1001-DEV | Seated on the Pi's 26-pin header | `/dev/serial0` |
| DWM1001-DEV | USB | `/dev/serial/by-id/usb-SEGGER_J-Link_…` |
| DWM3001CDK | USB | `/dev/serial/by-id/usb-SEGGER_J-Link_…` |

**Wiring on the header.** The DWM1001-DEV's 26-pin connector mates with pins 1–26 of the Pi's
40-pin header, so no wires are needed. Its UART reaches the Pi on pins 8 (Pi TX) and 10 (Pi RX),
at 115 200 baud. Raspberry Pi OS turns that UART off by default: see
[Raspberry Pi preparation](#raspberry-pi-preparation).

**Bluetooth (optional).** An anchor can use one Bluetooth adapter on the host, and an adapter
serves only one anchor. With an adapter, the anchor reports the tags it hears, and KenLens can
configure and update devices through it. Without one, it still reports positions, but it reports
no sightings and cannot reach devices. The adapter can be the Pi's onboard Bluetooth, or an
nRF52840 dongle (PCA10059), which the manager flashes for you. The host needs `bluetoothd`
running, as Raspberry Pi OS has.

**Software.** Docker Engine with the Compose v2 plugin (`docker compose version` must work),
installed from [Docker's own packages](https://docs.docker.com/engine/install/debian/). On
Raspberry Pi OS, follow the Debian instructions. Also needed: `bash`, `curl` and `tar`, which
Raspberry Pi OS already has. Run everything below as a user in the `docker` group
(`sudo usermod -aG docker "$USER"`, then sign in again). The setup script uses `sudo` only to
change the Pi's boot settings.

**Network.** The host needs:

- internet access while installing and upgrading, because the image is pulled from `ghcr.io`;
- a fixed IP address (a DHCP reservation is enough), because KenLens reaches each anchor's
  console on it;
- a route to the KenLens host's MQTT broker.

## Raspberry Pi preparation

Seat the board on the header with the Pi powered off.

The setup script does the rest, and asks before it changes anything. When it finds it is on a
Raspberry Pi, it offers:

1. **The header UART on** (`enable_uart=1` in `config.txt`).
2. **No login console on it.** It removes `console=serial0,115200` from `cmdline.txt`. Otherwise
   the board's sentences go to a login prompt.
3. **On a Pi 3 or 4, how the UART is shared with the onboard Bluetooth.** The Pi has one full
   UART and one simpler "mini-UART", and by default it gives the full UART to Bluetooth:

   | Choice | Header | Onboard Bluetooth |
   |---|---|---|
   | `default` (recommended) | mini-UART (`ttyS0`) | kept, usable by an anchor |
   | `disable-bt` | full UART (`ttyAMA0`) | none; use a dongle, or no Bluetooth |
   | `miniuart-bt` | full UART (`ttyAMA0`) | on the mini-UART |

   All three were measured on a Pi 3 Model B at 115 200 baud, with the onboard Bluetooth scanning
   where it was kept, and none lost a sentence. `miniuart-bt` logged receive errors on the
   Bluetooth link while the controller started, which is why `default` is preferred.
4. **The onboard Bluetooth unblocked**, if Raspberry Pi OS left it soft-blocked (`rfkill`).

The script backs each file up first as `config.txt.pre-anchor-bridge` and
`cmdline.txt.pre-anchor-bridge`, in `/boot/firmware`. It then offers to reboot. The settings take
effect only after a reboot. If you reboot, run `./anchor-bridge-setup.sh` once more afterwards to
start the bridge. If you prefer to make the changes by hand, decline and edit the two files as
above. `ls -l /dev/serial0` must then show a link to `ttyS0` or `ttyAMA0`.

## Install

Install into a directory you will keep. The examples use `/opt/kenlens-anchor-bridge`.

```bash
# The latest release, or set VERSION=vX.Y.Z by hand for another one from the Releases page.
# Use the same release as the KenLens server.
VERSION=$(curl -fsSL https://api.github.com/repos/kenlens-rtls/kenlens-deploy/releases/latest \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
echo "$VERSION"

sudo mkdir -p /opt/kenlens-anchor-bridge && sudo chown "$USER": /opt/kenlens-anchor-bridge
cd /opt/kenlens-anchor-bridge
curl -fsSLO "https://github.com/kenlens-rtls/kenlens-deploy/releases/download/${VERSION}/kenlens-deploy-${VERSION}.tar.gz"
tar -xzf "kenlens-deploy-${VERSION}.tar.gz" --strip-components=2 "kenlens-deploy-${VERSION}/anchor-bridge"
```

**Set up and start it:**

```bash
./anchor-bridge-setup.sh
```

It writes `.env`, with the release and the group that owns the serial ports. On a Pi it offers
the [preparation](#raspberry-pi-preparation) above. It then pulls the image, starts the container
and prints two things:

```text
anchor-bridge-setup: manager: https://192.168.1.107:8440
anchor-bridge-setup: setup token: 3f9c…  — enter it there to choose the manager password
```

`./anchor-bridge-setup.sh --help` lists every option, including how to run it without prompts.

**Create the anchors.** Browse to the manager address and accept its self-signed certificate.
Enter the setup token, then choose the manager password. The token is printed again by
`docker compose logs anchor-bridge | grep "setup token"` until a password is set.

The manager lists the boards on the host, read fresh on every load. For each board:

1. Choose its **daughter board** type.
2. Give it a **console password**.
3. Optionally, choose a **Bluetooth adapter**.
4. Press **Create anchor**.

Each anchor gets a permanent `board_id` and its own console, `https://<host>:8441` and up. The
manager lists each console's address. An anchor publishes nothing until it is onboarded:
[Onboard a bridged anchor](https://github.com/kenlens-rtls/kenlens-deploy/wiki/Onboard-a-bridged-anchor)
takes it from there.

**Upgrade.** One command fetches a release, checks it, replaces this folder's files and restarts
the bridge. `.env` keeps its settings except the version, and the anchors are kept:

```bash
./anchor-bridge-setup.sh --update latest       # or --update vX.Y.Z, from the Releases page
```

## Ports

The host must accept:

| Port | Protocol | Who connects |
|---|---|---|
| 8440 | HTTPS | You, to the manager. `--manager-port` moves it |
| 8441–8456 | HTTPS | You, to each anchor's console, and **the KenLens server**, which sends configuration and firmware updates there. Fixed: each anchor announces its own port |

The container uses the host's own network, because each anchor tells KenLens this host's address.
The ports above are therefore opened on the host itself, and must be free there.

It connects out to KenLens's broker on the port KenLens names when you onboard an anchor (8883
with TLS by default).

## Uninstall

```bash
cd /opt/kenlens-anchor-bridge
docker compose down          # removes the container; keeps the anchors
docker compose down -v       # ...and deletes every anchor's board_id, keys and passwords
sudo rm -rf /opt/kenlens-anchor-bridge
```

`down -v` cannot be undone. Anchors created again get new `board_id`s, so KenLens sees new
anchors and the old ones go stale. To return a Pi's serial port to its original settings, copy
the two `*.pre-anchor-bridge` files in `/boot/firmware` back over the originals and reboot.
