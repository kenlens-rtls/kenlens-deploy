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
- [Flash and configure the UWB board](#flash-and-configure-the-uwb-board)
- [Raspberry Pi preparation (recommended)](#raspberry-pi-preparation-recommended)
- [Install](#install)
- [Ports](#ports)
- [Uninstall](#uninstall)

## Requirements

**Host.** One of these:

- a **Raspberry Pi 3 or 4**, the recommended host: [Raspberry Pi preparation](#raspberry-pi-preparation-recommended)
  takes it from a blank SD card to a host ready for the bridge. The bridge needs well under 1 GB
  of RAM. On a Pi 5 the header's UART is not `/dev/serial0`, so use a board on USB there;
- any other 64-bit Linux host that runs Docker, `amd64` or `arm64`, with its boards on USB.

**Boards.** Each anchor is one UWB board running KenLens's UWB firmware as an anchor:
[Flash and configure the UWB board](#flash-and-configure-the-uwb-board).

| Board | Connection | Shown in the manager as |
|---|---|---|
| DWM1001-DEV | Seated on the Pi's 26-pin header | `/dev/serial0` |
| DWM1001-DEV | USB | `/dev/serial/by-id/usb-SEGGER_J-Link_…` |
| DWM3001CDK | USB | `/dev/serial/by-id/usb-SEGGER_J-Link_…` |

**Bluetooth (optional).** An anchor can use one Bluetooth adapter on the host, and an adapter
serves only one anchor. With an adapter, the anchor reports the tags it hears, and KenLens can
configure and update devices through it. Without one, it still reports positions, but it reports
no sightings and cannot reach devices. The adapter can be the Pi's onboard Bluetooth, or an
nRF52840 dongle (PCA10059), which the manager flashes for you. The host needs `bluetoothd`
running, as Raspberry Pi OS has.

**Software, on a host other than a Pi.** Docker Engine with the Compose v2 plugin
(`docker compose version` must work), from
[Docker's instructions](https://docs.docker.com/engine/install/), and `bash`, `curl` and `tar`.
Run everything below as a user in the `docker` group (`sudo usermod -aG docker "$USER"`, then sign
in again). On a Pi, the preparation below installs all of it.

**Network.** The host needs:

- internet access while installing and upgrading, because the image is pulled from `ghcr.io`;
- a fixed IP address (a DHCP reservation is enough), because KenLens reaches each anchor's
  console on it;
- a route to the KenLens host's MQTT broker.

## Flash and configure the UWB board

The board gets KenLens's UWB firmware once over USB, from a computer, before it goes on the host;
it gets its role later, over Bluetooth, once its anchor is onboarded.
[UWB boards](../uwb-boards/) has the full procedure, the Programmer app as an alternative to the
command line, and what to do when something goes wrong.

**Tools**, on the computer the board is plugged into:

- [SEGGER J-Link Software](https://www.segger.com/downloads/jlink/), which talks to the board's
  built-in J-Link debugger;
- [nrfutil](https://www.nordicsemi.com/Products/Development-tools/nRF-Util), Nordic's command-line
  tool. Download it for your system, put it on the `PATH`, then add its `device` command:

  ```bash
  nrfutil install device
  ```

**Flash it.** From the [release](https://github.com/kenlens-rtls/kenlens-deploy/releases) the
KenLens server runs, download `SHA256SUMS` and the `-full.hex` for your board (`<board>` is
`dwm1001dev` or `dwm3001cdk`), connect the board's J-Link USB connector, then:

```bash
sha256sum --check --ignore-missing SHA256SUMS   # the .hex must say OK
nrfutil device list                             # the board's serial number
nrfutil device recover                          # erases the whole chip, and unlocks a locked one
nrfutil device program --firmware uwbfirmware-<version>-<board>-full.hex \
  --options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE
nrfutil device reset
```

Add `--serial-number <n>` to each `nrfutil device` command when more than one board is connected.
A newer DWM3001CDK locks its debug port again at each power-on: see the guide's known issue.

The board then starts with no configuration, in its diagnostic mode, announcing itself over
Bluetooth. It goes on the Pi at the end of the
[preparation](#raspberry-pi-preparation-recommended), or into another host's USB.

**Configure it.** Its role is not set with `nrfutil`: KenLens writes it over Bluetooth, once the
bridge is installed and the board's anchor created with a Bluetooth adapter and
[onboarded](https://github.com/kenlens-rtls/kenlens-deploy/wiki/Onboard-a-bridged-anchor). The
anchor hears its own board, so no other anchor is needed:

1. In KenLens, open **Configuration → UWB network**, and open the board, listed by its part ID.
2. Set **Application mode** to **MN anchor** (or **TDoA anchor**, on a site whose network runs
   TDoA), and a **Node ID** no other device uses.
3. **Save configuration**, then **Write configuration**. The board restarts as an anchor and
   KenLens reads its configuration back.

## Raspberry Pi preparation (recommended)

From a blank SD card to a Pi with Docker and the anchor bridge downloaded. You need a Raspberry Pi
3 or 4, its power supply, an SD card, and a computer with
[Raspberry Pi Imager](https://www.raspberrypi.com/software/).

1. **Download Raspberry Pi Imager** and open it, with the SD card in the computer.
2. **Device:** your model, *Raspberry Pi 3* or *Raspberry Pi 4*.
3. **Operating system:** *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**, the
   recommended one. It must be the 64-bit one: there is no 32-bit image of the bridge. Lite has no
   desktop, which the bridge does not need.
4. **Storage:** the SD card. Imager erases what you pick.
5. **Customisation.** Say yes when Imager offers it, and set:

   | Setting | Value |
   |---|---|
   | Hostname | A name for the Pi, such as `kenlens-anchor-pi-01` |
   | Localisation | Your time zone and keyboard layout |
   | Username and password | Your own; there is no default user |
   | Wi-Fi | Your network, only if the Pi will not be on Ethernet |
   | SSH | **On.** Password authentication, or paste your public key |

   Then **Write**, and wait for Imager to verify the card.
6. **Boot the Pi.** Put the card in the Pi, connect Ethernet if you use it, and power it on. The
   first start takes a minute or two. Give the Pi its fixed address on the router now.
7. **Log in** from your computer, with the hostname and the user you chose:
   `ssh <user>@kenlens-anchor-pi-01.local` (or the Pi's address, if `.local` names do not resolve).
8. **Download and run KenLens's Pi script:**

   ```bash
   curl -fsSLO https://raw.githubusercontent.com/kenlens-rtls/kenlens-deploy/main/raspberry-pi/kenlens-pi-setup.sh
   bash kenlens-pi-setup.sh --prepare-only
   ```

   It brings Raspberry Pi OS up to date, installs Docker from Docker's own packages, adds you to
   the `docker` group, and downloads the anchor bridge of the latest release into
   `/opt/kenlens-anchor-bridge` (`--version vX.Y.Z` for another release, `--dir` for another
   place). It ends with the command that installs the bridge.
9. **Log out and back in**, so the `docker` group applies.
10. **Seat the board on the header**, with the Pi powered off (`sudo poweroff`), flashed as
    [above](#flash-and-configure-the-uwb-board). Power the Pi on again, and go on to
    [Install](#install).

### The serial port on the header

The DWM1001-DEV's 26-pin connector mates with pins 1–26 of the Pi's 40-pin header, so no wires
are needed. Its UART reaches the Pi on pins 8 (Pi TX) and 10 (Pi RX), at 115 200 baud. Raspberry
Pi OS turns that UART off by default, so `anchor-bridge-setup.sh`, when it finds it is on a
Raspberry Pi, offers:

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

It asks before it changes anything, and backs each file up first as `config.txt.pre-anchor-bridge`
and `cmdline.txt.pre-anchor-bridge`, in `/boot/firmware`. The settings take effect only after a
reboot, which the script offers as its very last step, once the bridge is installed and started;
the bridge starts again by itself when the Pi is back. If you prefer to make the changes by hand,
decline and edit the two files as above. `ls -l /dev/serial0` must then show a link to `ttyS0` or
`ttyAMA0`.

Once the port is set up, the script no longer asks. To change the Bluetooth choice later, run
`./anchor-bridge-setup.sh --pi-serial disable-bt` (or `default`, `miniuart-bt`) and reboot.

## Install

On a [prepared Raspberry Pi](#raspberry-pi-preparation-recommended), the bridge is already in
`/opt/kenlens-anchor-bridge`: go on to [set it up](#set-up-and-start-it). On another host, install
it into a directory you will keep. The examples use `/opt/kenlens-anchor-bridge`.

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

### Set up and start it

```bash
cd /opt/kenlens-anchor-bridge
./anchor-bridge-setup.sh
```

It writes `.env`, with the release and the group that owns the serial ports. On a Pi it offers
the [serial port settings](#the-serial-port-on-the-header). It then pulls the image, starts the
container and prints two things:

```text
anchor-bridge-setup: manager: https://192.168.1.107:8440
anchor-bridge-setup: setup token: 3f9c…  — enter it there to choose the manager password
```

When the serial settings need a reboot, it asks for it last, after the bridge has started. It then
prints the command that shows the setup token instead of the token: the bridge draws a new token
each time it starts, so read it once the Pi is back.

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
takes it from there. Then [give its board its role](#flash-and-configure-the-uwb-board).

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
