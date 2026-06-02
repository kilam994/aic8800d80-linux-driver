# AIC8800D80 Wi-Fi 6 USB Adapter — Linux Driver

A self-contained, **DKMS-based** Linux driver package for USB Wi-Fi adapters built on the
**AICSemi AIC8800D80** chipset. Ships the kernel driver source **and** the matching
firmware as one set, so the radio actually works (not just enumerates).

DKMS means the driver **automatically rebuilds after every kernel update** — install once,
forget about it.

### Tested working

| Adapter | USB ID (Wi-Fi mode) | Notes |
|---|---|---|
| **UGREEN AX900 (CM770)** | `368b:8d88` | Verified on kernel `7.0.0` / Ubuntu |
| Tenda U11 / AX913B | `368b:8d8X` | Upstream-tested |
| AIC8800D80 "Pandora" clones | `1111:1111` → `a69c:8d80` | Handled via `usb_modeswitch` |

---

## Quick install

```bash
git clone <this-repo-url> aic8800d80-linux-driver
cd aic8800d80-linux-driver
sudo ./install.sh
```

Then plug in the adapter (or reboot if it was already plugged in) and connect:

```bash
nmcli device wifi list
nmcli device wifi connect "Your-SSID" password "your-password"
```

That's it. For a fully automated/unattended run use `sudo ./install.sh --yes`.

---

## What the installer does

1. **Removes conflicting installs.** Vendor `.deb` drivers (e.g. the bundled
   `ax900-wifi-adapter-linux-driver`), stale `/usr/src/AIC8800`, old non-DKMS modules, and
   any previous DKMS registration. *This is the single most important step* — see
   [Troubleshooting](#troubleshooting).
2. **Installs build dependencies** — `dkms`, kernel headers, build tools, `usb-modeswitch`.
3. **Installs the matched firmware** to `/lib/firmware/aic8800*` plus the `udev` rules and
   `usb_modeswitch` config that flip the adapter out of its "virtual CD" mode into Wi-Fi mode.
4. **Builds & installs the module via DKMS** (`aic8800/1.0.0`).
5. **Loads the module and verifies** the interface comes up and can scan.

A full log is written to `/tmp/aic8800d80_install.log`.

---

## Requirements

- A Debian/Ubuntu, Fedora/RHEL, Arch, or openSUSE system (the installer auto-detects the
  package manager).
- Matching **kernel headers** installed (the installer pulls them automatically).
- **Secure Boot disabled**, *or* a MOK signing key enrolled — unsigned DKMS modules are
  refused by the kernel otherwise. The installer detects Secure Boot and warns you.

---

## Set your Wi-Fi country (recommended)

Without a regulatory domain the radio may be limited (no 5 GHz, restricted scanning).
Set and persist your country (replace `SA` with your ISO country code):

```bash
sudo iw reg set SA
echo 'options cfg80211 ieee80211_regdom=SA' | sudo tee /etc/modprobe.d/cfg80211.conf
```

---

## Uninstall

```bash
sudo ./uninstall.sh
```

Removes the module, DKMS registration, source tree, firmware, and rules. Build
dependencies (`dkms`, headers) are left in place.

---

## Troubleshooting

### Adapter is detected and the driver loads, but it sees **no networks** (deaf radio)
This is almost always a **driver/firmware mismatch** — a different driver build is loading
firmware blobs it wasn't paired with. Symptoms: `nmcli device wifi list` is empty even
though networks are nearby, and `iw dev <iface> scan` returns nothing.

**Fix:** make sure no other AIC8800 driver is present, then reinstall from this repo:

```bash
# remove any vendor .deb driver first
sudo dpkg --purge --force-all ax900-wifi-adapter-linux-driver 2>/dev/null
sudo rm -rf /lib/firmware/aic8800*        # the installer also does this
sudo ./install.sh
```

The driver and firmware in this repo are a **matched set** — don't mix them with firmware
from another package.

### Interface doesn't appear after install
The chip downloads firmware on a cold USB enumeration. After installing, the cleanest reset
is to **physically unplug/replug the adapter**, or reboot. Check progress with:

```bash
lsusb | grep -i aic        # 368b:8d88 = Wi-Fi mode;  a69c:5724 = still in CD/storage mode
ip link show               # look for a wl* interface
sudo dmesg | grep -i aic   # firmware upload + interface creation
```

### Adapter shows up as a USB CD-ROM / mass storage device
It hasn't switched into Wi-Fi mode. The `udev` rule ejects the virtual CD and the
`usb_modeswitch` config handles the `1111:1111` clones — both are installed by the script.
Replug the adapter; if it still won't switch, ensure `usb-modeswitch` is installed.

### DKMS build fails
Usually missing/mismatched kernel headers. Confirm they match your running kernel:

```bash
uname -r
ls /lib/modules/$(uname -r)/build
```

Install the matching `linux-headers-$(uname -r)` and re-run. Build details are in
`/var/lib/dkms/aic8800/1.0.0/build/make.log`.

### Secure Boot
If Secure Boot is enabled, either disable it in BIOS/UEFI or sign the module with a MOK key.
Verify with `mokutil --sb-state`.

---

## Repository layout

```
.
├── install.sh            # DKMS installer (run this)
├── uninstall.sh          # clean removal
├── diagnostic_build.sh   # optional: diagnose build failures
├── dkms.conf             # DKMS module definition
├── aic.rules             # udev rules (eject virtual CD, mode switch)
├── usb_modeswitch/       # usb_modeswitch config for 1111:1111 clones
├── drivers/aic8800/      # kernel driver source (aic8800_fdrv + aic_load_fw)
└── fw/                   # firmware for all AIC8800 variants (D80, D80N, DC, ...)
```

---

## Credits & license

This packaging is built around the **AIC8800D80 Linux driver** maintained by
[**shenmintao/aic8800d80**](https://github.com/shenmintao/aic8800d80), which in turn derives
from AICSemi's reference / Tenda U11 driver source. All driver and firmware code belongs to
its respective authors and is redistributed under their original terms.

This repository adds an audited, conflict-aware installer, an uninstaller, and consolidated
documentation. It is provided as-is, with no warranty.
