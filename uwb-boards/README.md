# UWB boards: flash and configure

Each KenLens release ships the UWB firmware for two development boards, the **DWM1001-DEV** and the
**DWM3001CDK**: as tags, and as the daughter board of an anchor, such as one behind the
[anchor bridge](../anchor-bridge/). This guide writes the firmware to a new board from a computer,
then gives the board its role from KenLens.

- [What you need](#what-you-need)
- [1. Download the firmware](#1-download-the-firmware)
- [2. Flash the board](#2-flash-the-board)
- [3. Give the board its role](#3-give-the-board-its-role)
- [Updating a board later](#updating-a-board-later)
- [When something goes wrong](#when-something-goes-wrong)

**Read this first.**

- The firmware is built and signed by KenLens's firmware project; each KenLens release names the
  version it carries in its release notes.
- **These are bench builds, signed with development keys.** A board accepts updates signed with
  the key of the firmware first written to it, so a later move to production keys means flashing
  every board over USB once more.
- **The firmware in this release has not yet been validated on hardware.** Try one board before a
  fleet.

## What you need

- The board, and a **USB cable** to the connector of its built-in **J-Link debugger**. Both boards
  have one; the board's documentation marks which connector it is. No separate programmer is
  needed.
- A Windows, macOS or Linux computer with:
  - [SEGGER J-Link Software](https://www.segger.com/downloads/jlink/), which talks to the debugger;
  - one of Nordic's programming tools: **nRF Connect for Desktop** with its **Programmer** app,
    from [nordicsemi.com](https://www.nordicsemi.com/Products/Development-tools/nRF-Connect-for-Desktop),
    if you prefer a window, or [**nrfutil**](https://www.nordicsemi.com/Products/Development-tools/nRF-Util)
    with its `device` command (`nrfutil install device`) for the command line.
- To give the board its role: KenLens running, with at least one **anchor that has Bluetooth** within
  a few metres of the board — a networked anchor, or a bridged anchor created with a Bluetooth
  adapter.

## 1. Download the firmware

Open the [release](https://github.com/kenlens-rtls/kenlens-deploy/releases) of the KenLens version
you run and download, for your board, the files whose names end in:

| File | What it is |
|---|---|
| `-<board>-full.hex` | The bootloader and the signed firmware, in one file. Written once, at the first flash |
| `-<board>-ota.bin` | The same firmware for updates over Bluetooth. KenLens already has it: see [Updating a board later](#updating-a-board-later) |
| `SHA256SUMS` | The checksum of every file |

`<board>` is `dwm1001dev` or `dwm3001cdk`. A file for the other board does not start on yours.
Check the downloads where you saved them:

```bash
sha256sum --check --ignore-missing SHA256SUMS
```

Every file you downloaded must say `OK`. On Windows, `Get-FileHash <file>` in PowerShell prints a
checksum to compare with the file's line in `SHA256SUMS`.

## 2. Flash the board

One file goes on the board: the `-full.hex`, which holds **the bootloader and the signed firmware**
together. Connect the board's J-Link connector to the computer.

### With the Programmer app

1. Open **nRF Connect for Desktop**, then **Programmer**.
2. **Select device**: the board appears as a J-Link with its serial number.
3. **Add file**: the `-full.hex`. The memory map shows the bootloader and the firmware.
4. **Erase & write**. When it finishes, the board restarts with the new firmware.

### With nrfutil

```bash
nrfutil device list                       # the board's serial number, if several are connected
nrfutil device recover                    # erases the whole chip, and unlocks a locked one
nrfutil device program --firmware uwbfirmware-<version>-<board>-full.hex \
  --options chip_erase_mode=ERASE_RANGES_TOUCHED_BY_FIRMWARE
nrfutil device reset
```

Add `--serial-number <n>` to each command when more than one board is connected.

**Erasing the whole chip also erases the board's configuration.** That is right for a new board.
To reflash a board that is already configured, skip `recover`: the configuration survives, unless
the board is locked and `recover` is the only way in.

A freshly flashed board has no configuration. It starts in its diagnostic mode, waiting to be told
what it is, and announces itself over Bluetooth so that an anchor can hear it.

### Known issue: newer DWM3001CDK chips lock their debug port

Newer revisions of the DWM3001CDK's Nordic chip (nRF52833, build code Bxx or later) protect their
debug port by default, and this firmware does not open it. Such a board may arrive locked and refuse
programming the first time: `nrfutil device recover`, or **Erase all** in the Programmer, opens it.
Once flashed, it programs and starts normally but is expected to **lock again at its next power-on or
reset**.

- **What still works:** everything the board does in service. Its configuration and its updates go
  over Bluetooth, so giving it its role and rolling out new firmware from KenLens are unaffected.
- **What is lost:** flashing it over USB again, and its debug console.
- **To flash it over USB again:** run `nrfutil device recover`, or **Erase all** in the Programmer,
  then flash it as above. That erases the whole chip, configuration included, so give the board its
  role again afterwards.

The boards tested so far carry older chips that never lock. Source: uwbfirmware `docs/kb/ota.md` at
v0.28.0 (`9d6c47c7`).

## 3. Give the board its role

KenLens configures a board over Bluetooth, through any anchor that hears it.

1. Put the board within a few metres of an anchor that has Bluetooth. For the first anchor behind an
   anchor bridge, that anchor is the bridge itself, through the Bluetooth adapter you chose for it.
2. In KenLens, open **Configuration → UWB network**. The board appears in the list, by its part ID,
   once the anchor has heard it. Open it.
3. Set its **Application mode**, and its **Node ID** — a number no other device uses:

   | The board will be | Application mode |
   |---|---|
   | A tag, in a multi-node network | MN tag |
   | An anchor's daughter board — such as one behind the anchor bridge — in a multi-node network | MN anchor |
   | A tag or an anchor in a TDoA network | TDoA tag / TDoA anchor |

   Use the mode your network runs: every device of a site is on the same one. **Configuration → UWB
   network** shows which.
4. **Save configuration**, then **Write configuration**. KenLens writes it the next time the board
   is reachable, the board restarts, and KenLens reads the configuration back to confirm it.

A board for the anchor bridge can then be connected to the bridge host and created as an anchor, as
the [anchor bridge guide](../anchor-bridge/) describes, then
[onboarded](https://github.com/kenlens-rtls/kenlens-deploy/wiki/Onboard-a-bridged-anchor).

Anyone holding the **config:write** permission can change a board's configuration this way. The
boards accept a configuration from any Bluetooth device that asks, so keep that permission to the
people who manage the UWB network.

## Updating a board later

No cable is needed after the first flash. Every KenLens release carries the `-ota.bin` firmware for
both boards and puts it into **Configuration → Firmware** by itself when it starts, uploaded by
**KenLens vX.Y.Z**. Create a rollout there to update tags or anchors' daughter boards over
Bluetooth. Nothing is updated until you start one.

## When something goes wrong

| Symptom | Fix |
|---|---|
| The Programmer or `nrfutil` finds no device | Install the SEGGER J-Link Software, and use the board's J-Link USB connector — not its other USB port, if it has one |
| Writing is refused, or the board reports it is protected | The chip is locked. `nrfutil device recover` erases and unlocks it, or **Erase all** in the Programmer, then flash again. A newer DWM3001CDK locks again at each power-on: see [the known issue](#known-issue-newer-dwm3001cdk-chips-lock-their-debug-port) |
| The board does not start after flashing | Another file than the `-full.hex` was written. Flash the `-full.hex` |
| The board never appears in **UWB network** | No anchor with Bluetooth hears it. Move it closer to one, and check the anchor's Bluetooth: a bridged anchor created without an adapter hears nothing |
| A write is refused because the board is for another board type | The firmware for the other board was written. Flash the files for yours |
| A rollout's item fails at the board | The image was signed with a different key than the board's bootloader. Flash the board over USB with this release's files |
