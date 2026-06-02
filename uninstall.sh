#!/usr/bin/env bash
#############################################################################
# AIC8800D80 Wi-Fi 6 USB Adapter — Linux Driver Uninstaller
#
# Removes the DKMS module, source tree, firmware, and udev/usb_modeswitch
# rules installed by install.sh.
#
# Usage:  sudo ./uninstall.sh
#############################################################################

set -Eeuo pipefail

readonly DRV_NAME="aic8800"
readonly DRV_VERSION="1.0.0"
readonly SRC_DIR="/usr/src/${DRV_NAME}-${DRV_VERSION}"
readonly MODULE_NAME="aic8800_fdrv"

if [[ -t 1 ]]; then
    GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[1;33m'; NC=$'\033[0m'
else
    GREEN=""; BLUE=""; YELLOW=""; NC=""
fi
info() { echo "${BLUE}[INFO]${NC} $1"; }
ok()   { echo "${GREEN}[ OK ]${NC} $1"; }
warn() { echo "${YELLOW}[WARN]${NC} $1"; }

[[ ${EUID} -eq 0 ]] || { echo "Run as root: sudo ./uninstall.sh"; exit 1; }

info "Unloading kernel module..."
modprobe -r "$MODULE_NAME" aic_load_fw 2>/dev/null || true

info "Removing DKMS registrations..."
if command -v dkms &>/dev/null; then
    while read -r ver; do
        [[ -n "$ver" ]] || continue
        dkms remove "${DRV_NAME}/${ver}" --all 2>/dev/null || true
    done < <(dkms status 2>/dev/null | sed -n "s|^${DRV_NAME}/\([^,]*\),.*|\1|p" | sort -u)
fi

info "Removing source tree ${SRC_DIR} ..."
rm -rf "$SRC_DIR"

info "Removing firmware /lib/firmware/aic8800* ..."
rm -rf /lib/firmware/aic8800*

info "Removing udev rules and usb_modeswitch config..."
rm -f /usr/lib/udev/rules.d/aic.rules /lib/udev/rules.d/aic.rules
rm -f "/etc/usb_modeswitch.d/1111:1111"
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger 2>/dev/null || true

depmod -a 2>/dev/null || true

ok "Uninstall complete. Reboot or replug the adapter to finish cleanup."
warn "Note: build dependencies (dkms, headers) were left installed."
