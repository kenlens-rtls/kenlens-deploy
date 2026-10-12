# KenLens on a Raspberry Pi

From a blank SSD to a signed-in KenLens: Raspberry Pi Imager writes Raspberry Pi OS Lite (64-bit),
and one script, `kenlens-pi-setup.sh`, prepares the Pi, installs Docker and installs KenLens. It
does what the [install guide](../README.md) describes, on a Pi, without the typing.

- [What you need](#what-you-need)
- [1. Write Raspberry Pi OS](#1-write-raspberry-pi-os)
- [2. Start the Pi and log in](#2-start-the-pi-and-log-in)
- [3. Run the script](#3-run-the-script)
- [4. Sign in](#4-sign-in)
- [What the script changes](#what-the-script-changes)
- [When something goes wrong](#when-something-goes-wrong)

## What you need

- A **Raspberry Pi 4 or 5 with at least 4 GB** of RAM; 8 GB is comfortable. The script stops on a
  smaller one before installing KenLens.
- An **SSD**: on a USB 3 adapter (the blue ports), or on an M.2 HAT on a Pi 5. KenLens writes
  position history all the time, and an SD card wears out under that and is slow enough to hold
  the database back. The script asks before installing KenLens on an SD card. A Pi that only
  runs the [anchor bridge](../anchor-bridge/) needs no SSD: see `--prepare-only` in step 3.
- The Pi's own **power supply**. An SSD draws more than an under-powered supply gives, and the Pi
  then drops it.
- An **Ethernet cable** to the network the anchors and the browsers are on, and a **fixed
  address** for the Pi: a DHCP reservation on the router is enough. Make it before step 3.
- A computer with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) and a way to
  connect the SSD to it.

The [Ports](../README.md#ports) table lists what the Pi must accept from the network.

## 1. Write Raspberry Pi OS

Connect the SSD to your computer and open Raspberry Pi Imager.

1. **Device:** your model, *Raspberry Pi 4* or *Raspberry Pi 5*.
2. **Operating system:** *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**. It must be
   the 64-bit one; KenLens has no 32-bit image. Lite has no desktop, which a server does not need.
3. **Storage:** the SSD. Check the size: Imager erases what you pick.
4. **Customisation.** Imager offers to set the system up before the first boot; say yes and set:

   | Setting | Value |
   |---|---|
   | Hostname | A name for the Pi, such as `kenlens`. Browsers can reach it as `kenlens.local` |
   | Localisation | Your time zone and keyboard layout |
   | Username and password | Your own; there is no default user. Write them down |
   | Wi-Fi | **Leave it unconfigured.** The Pi uses Ethernet; see below |
   | SSH | **On.** Password authentication, or paste your public key |
   | Raspberry Pi Connect | Off |

5. **Write**, and wait for Imager to verify the disk.

**Why no Wi-Fi.** The Pi must answer every anchor by the same route the anchor used to reach it.
With Wi-Fi connected beside Ethernet, a router between the two networks sees only half of each MQTT
connection and drops it about a minute after it opens, all day long. The script offers to turn
Wi-Fi off if it finds it on.

## 2. Start the Pi and log in

Move the SSD to the Pi, **without an SD card in the slot**, connect Ethernet, then power it on. The
first start takes a minute or two while the system expands to fill the disk.

**A Pi 4 that does not start from the SSD** has an older bootloader that only knows SD cards.
Update it once: with Imager, write *Misc utility images* → *Bootloader (Pi 4 family)* → *USB Boot* to any SD
card, start the Pi from that card, wait until the green light blinks steadily, power off, remove
the card. A Pi 5 starts from USB and from an M.2 SSD as it comes.

From your computer, log in with the hostname and the user you chose:

```bash
ssh <user>@kenlens.local
```

If `.local` names do not resolve on your network, use the Pi's address from the router.

## 3. Run the script

On the Pi, download the script and run it as your own user, **not** with `sudo` — it asks for
your password when it needs it:

```bash
curl -fsSLO https://raw.githubusercontent.com/kenlens-rtls/kenlens-deploy/main/raspberry-pi/kenlens-pi-setup.sh
bash kenlens-pi-setup.sh
```

It shows each step as it goes. Expect 10 to 20 minutes, most of it downloading:

1. **Checks the Pi:** the model, the 64-bit system, Raspberry Pi OS Bookworm or later, and, when it
   installs KenLens, the memory and whether it runs from an SSD.
2. **Updates Raspberry Pi OS** (`apt-get full-upgrade`).
3. **Installs Docker** from Docker's own packages and adds you to the `docker` group.
4. **Checks the network**, offering to turn Wi-Fi off if it is connected beside Ethernet.
5. **Installs KenLens** in `/opt/kenlens`: downloads the latest release, runs its
   `kenlens-setup.sh`, starts the stack and waits until it answers healthy.

It asks:

- **The name(s) and address(es) browsers will use** to reach the Pi. It offers `<hostname>.local`
  and the Pi's current address; press Enter to take them, or type your own, comma-separated. They
  go into the certificates, and a name that is not in them makes browsers refuse the connection.
- **The HTTPS port**: 8443 unless you want another, such as 443.
- **The site DNS domain** anchors are also reached under, offering the one the router gave the Pi.

It ends with the address to open. To answer the questions up front instead, or to script it:

```bash
bash kenlens-pi-setup.sh --host kenlens.local --host 192.168.1.20 --https-port 443 \
  --wifi-off --non-interactive
```

`--version vX.Y.Z` installs a release other than the latest. `--prepare-only` stops after the
Docker step, for a Pi that will run the [anchor bridge](../anchor-bridge/) or follow the
[install guide](../README.md#install) by hand. It checks neither the memory nor the SSD: only
KenLens needs 4 GB and an SSD, and the anchor bridge runs from the SD card of a Pi 3 or 4 in well
under 1 GB. `bash kenlens-pi-setup.sh --help` lists every option. The script is also in every
release bundle, under `raspberry-pi/`.

Running it again is safe: every step already done is skipped, and an existing installation is
never set up again — the script prints the upgrade command instead.

## 4. Sign in

Browse to the address the script printed, `https://kenlens.local:8443` with the defaults. The
browser warns about the certificate until it trusts the KenLens CA: follow **Your browser warns
about this site? Trust this KenLens** on the page. Then **create the first Admin** — KenLens ships
no default account — sign in with it and follow the first-run wizard.

Log out of the Pi and back in before running `docker` commands yourself: the `docker` group
applies from the next login. From then on, the Pi is run like any KenLens host — upgrading,
backing up, rolling back — as the [operator guide](https://github.com/kenlens-rtls/kenlens-deploy/wiki)
describes, with the installation in `/opt/kenlens`. [Uninstall](../README.md#uninstall) is in the
install guide.

## What the script changes

| What | Change |
|---|---|
| Packages | Everything upgraded; Docker Engine, its Compose and Buildx plugins and containerd installed from `download.docker.com`. The distribution's `docker.io`, `docker-compose`, `podman-docker`, `containerd` and `runc` are removed first if present: they conflict with Docker's packages |
| apt | `/etc/apt/keyrings/docker.asc` and `/etc/apt/sources.list.d/docker.sources`, Docker's repository for your Debian release |
| Services | `docker` enabled at boot |
| Your user | Added to the `docker` group |
| Wi-Fi | Turned off, only after you say yes or with `--wifi-off`. It stays off across reboots; `sudo nmcli radio wifi on` turns it back on |
| `/opt/kenlens` | Created, owned by you, holding the release bundle and what `kenlens-setup.sh` writes: certificates, secrets and `.env`. Back it up as the [operator guide](https://github.com/kenlens-rtls/kenlens-deploy/wiki/Back-up-and-restore) describes |

Nothing else on the Pi is touched: not its network settings, its hostname nor its SSH
configuration.

## When something goes wrong

| The script says | Fix |
|---|---|
| `this is not a Raspberry Pi` | On another host, install Docker and follow the [install guide](../README.md) |
| `the system is armv7l, not aarch64` | The 32-bit Raspberry Pi OS was written. Write **Raspberry Pi OS Lite (64-bit)** again |
| `KenLens needs a Pi with at least 4 GB` | Use a Pi 4 or 5 with 4 GB or more. A Pi for the anchor bridge only: `--prepare-only` |
| `stopped: write Raspberry Pi OS to an SSD` | You answered no to installing on the SD card. Use an SSD, or run again with `--allow-sd-card` for a trial |
| `apt-get update failed` | The Pi has no internet access. Check the cable and the router, then run the script again |
| `could not get the latest release` | No network, or GitHub's limit on unauthenticated requests. Name the release: `--version vX.Y.Z` from the [Releases page](https://github.com/kenlens-rtls/kenlens-deploy/releases) |
| `is not empty and holds no KenLens bundle` | `/opt/kenlens` holds something else. Move it away, or install elsewhere with `--dir` |
| `KenLens is already installed` | Nothing is wrong: it upgrades with `cd /opt/kenlens && ./kenlens-setup.sh --update latest` |
| `did not become healthy` or `did not answer Healthy` | `cd /opt/kenlens && docker compose logs`, and the operator guide's [Troubleshooting](https://github.com/kenlens-rtls/kenlens-deploy/wiki/Troubleshooting) |

When `kenlens-setup.sh` fails part-way, fix what it names and run `bash kenlens-pi-setup.sh`
again: it carries on from the bundle already in `/opt/kenlens`.
