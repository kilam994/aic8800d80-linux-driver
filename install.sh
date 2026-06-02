#!/usr/bin/env bash
#############################################################################
# AIC8800D80 Wi-Fi 6 USB Adapter — Linux Driver Installer (DKMS)
#
# Works with adapters built on the AICSemi AIC8800D80 chipset, including:
#   UGREEN AX900 (CM770), Tenda U11 / AX913B, and 368b:8d88 clones.
#
# What it does:
#   1. Removes conflicting old drivers/firmware (the usual cause of a
#      "driver loads but sees no networks" deaf radio).
#   2. Installs build dependencies (dkms, headers, build tools).
#   3. Installs the matched firmware set + udev / usb_modeswitch rules.
#   4. Builds & installs the kernel module via DKMS so it auto-rebuilds
#      on every kernel update.
#   5. Loads the module and verifies the radio can scan.
#
# Usage:
#   sudo ./install.sh            # interactive
#   sudo ./install.sh --yes      # non-interactive (assume yes to prompts)
#############################################################################

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
readonly DRV_NAME="aic8800"
readonly DRV_VERSION="1.0.0"
readonly SRC_DIR="/usr/src/${DRV_NAME}-${DRV_VERSION}"
readonly MODULE_NAME="aic8800_fdrv"
readonly LOG_FILE="/tmp/aic8800d80_install.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Packages known to conflict with this driver (vendor .deb installs etc.)
readonly CONFLICT_PACKAGES=(
    "ax900-wifi-adapter-linux-driver"
    "aic8800-dkms"
    "tenda-u11-dkms"
)

ASSUME_YES=false
[[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && ASSUME_YES=true
# Treat a non-interactive shell (piped/cron) as --yes so prompts never hang.
[[ -t 0 ]] || ASSUME_YES=true

# ----------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; NC=""
fi

log()      { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE" 2>/dev/null || true; }
info()     { echo "${BLUE}[INFO]${NC} $1";    log "INFO: $1"; }
ok()       { echo "${GREEN}[ OK ]${NC} $1";   log "OK: $1"; }
warn()     { echo "${YELLOW}[WARN]${NC} $1";  log "WARN: $1"; }
err()      { echo "${RED}[FAIL]${NC} $1" >&2; log "FAIL: $1"; }
step()     { echo; echo "${CYAN}==>${NC} $1"; log "STEP: $1"; }

confirm() {
    # confirm "question" -> returns 0 for yes
    $ASSUME_YES && return 0
    local reply
    read -r -p "$1 [y/N]: " reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

on_error() {
    err "Installation failed on line ${BASH_LINENO[0]}. See $LOG_FILE for details."
    exit 1
}
trap on_error ERR

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        err "This script must be run as root:  sudo ./install.sh"
        exit 1
    fi
}

check_sources() {
    step "Checking repository layout..."
    local missing=0
    for p in "drivers/aic8800" "fw" "dkms.conf"; do
        if [[ ! -e "${SCRIPT_DIR}/${p}" ]]; then
            err "Missing '${p}'. Run this script from the repository root."
            missing=1
        fi
    done
    [[ $missing -eq 0 ]] || exit 1
    ok "Repository layout looks good."
}

check_secure_boot() {
    step "Checking Secure Boot status..."
    local enabled=false
    if command -v mokutil &>/dev/null && mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
        enabled=true
    elif [[ -d /sys/firmware/efi/efivars ]]; then
        local f=(/sys/firmware/efi/efivars/SecureBoot-*)
        if [[ -f "${f[0]}" ]] && [[ "$(od -An -t u1 "${f[0]}" 2>/dev/null | awk '{print $NF}')" == "1" ]]; then
            enabled=true
        fi
    fi

    if $enabled; then
        warn "Secure Boot is ENABLED."
        echo "    Unsigned DKMS modules will be refused by the kernel until you either"
        echo "    disable Secure Boot in BIOS/UEFI or enroll a signing key (MOK)."
        if ! confirm "Continue anyway?"; then
            info "Aborted by user."
            exit 0
        fi
    else
        ok "Secure Boot is disabled or not present."
    fi
}

# ----------------------------------------------------------------------------
# Remove conflicting prior installs  (the key fix vs. the original script)
# ----------------------------------------------------------------------------
remove_conflicts() {
    step "Removing conflicting previous installs..."

    # 1. Vendor .deb packages that ship their own (often mismatched) driver.
    if command -v dpkg &>/dev/null; then
        for pkg in "${CONFLICT_PACKAGES[@]}"; do
            if dpkg -l "$pkg" 2>/dev/null | grep -qE '^[a-z]{2}'; then
                warn "Found conflicting package: $pkg — purging."
                modprobe -r "$MODULE_NAME" aic_load_fw 2>/dev/null || true
                dpkg --purge --force-all "$pkg" >>"$LOG_FILE" 2>&1 || \
                    apt-get purge -y "$pkg" >>"$LOG_FILE" 2>&1 || \
                    warn "Could not fully purge $pkg (continuing)."
            fi
        done
    fi

    # 2. Stale non-DKMS source tree from the vendor .deb.
    if [[ -d /usr/src/AIC8800 ]]; then
        info "Removing stale /usr/src/AIC8800 ..."
        rm -rf /usr/src/AIC8800
    fi

    # 3. Stale module files installed directly under kernel/drivers (non-DKMS).
    local stale
    stale="/lib/modules/$(uname -r)/kernel/drivers/net/wireless/aic8800"
    if [[ -d "$stale" ]]; then
        info "Removing stale modules in $stale ..."
        rm -rf "$stale"
    fi

    # 4. Old DKMS registration of this driver (any version).
    if command -v dkms &>/dev/null; then
        while read -r ver; do
            [[ -n "$ver" ]] || continue
            info "Removing old DKMS registration ${DRV_NAME}/${ver} ..."
            dkms remove "${DRV_NAME}/${ver}" --all >>"$LOG_FILE" 2>&1 || true
        done < <(dkms status 2>/dev/null | sed -n "s|^${DRV_NAME}/\([^,]*\),.*|\1|p" | sort -u)
    fi

    ok "Conflict cleanup complete."
}

# ----------------------------------------------------------------------------
# Dependencies
# ----------------------------------------------------------------------------
install_dependencies() {
    step "Installing build dependencies..."
    local kver; kver="$(uname -r)"

    if command -v apt-get &>/dev/null; then
        info "Detected apt (Debian/Ubuntu)."
        # update is best-effort: a stale mirror should not abort the install.
        apt-get update -qq >>"$LOG_FILE" 2>&1 || warn "apt-get update failed (continuing)."
        apt-get install -y dkms build-essential "linux-headers-${kver}" usb-modeswitch mokutil \
            >>"$LOG_FILE" 2>&1
    elif command -v dnf &>/dev/null; then
        info "Detected dnf (Fedora/RHEL)."
        dnf install -y dkms make gcc kernel-devel kernel-headers usb_modeswitch mokutil \
            >>"$LOG_FILE" 2>&1
    elif command -v pacman &>/dev/null; then
        info "Detected pacman (Arch)."
        pacman -Sy --noconfirm dkms base-devel linux-headers usb_modeswitch mokutil \
            >>"$LOG_FILE" 2>&1
    elif command -v zypper &>/dev/null; then
        info "Detected zypper (openSUSE)."
        zypper install -y dkms make gcc kernel-devel usb_modeswitch mokutil \
            >>"$LOG_FILE" 2>&1
    else
        err "No supported package manager found. Install manually: dkms, gcc, make, kernel headers."
        exit 1
    fi

    if [[ ! -d "/lib/modules/${kver}/build" ]]; then
        err "Kernel headers for ${kver} not found at /lib/modules/${kver}/build."
        err "Install the matching linux-headers package and re-run."
        exit 1
    fi
    ok "Dependencies installed."
}

# ----------------------------------------------------------------------------
# Firmware + udev + usb_modeswitch
# ----------------------------------------------------------------------------
install_firmware() {
    step "Installing firmware..."

    # Removing ALL old aic8800 firmware is mandatory: a mismatched firmware
    # version makes the radio load but see no networks (and can hang older kernels).
    if compgen -G "/lib/firmware/aic8800*" >/dev/null; then
        info "Removing existing /lib/firmware/aic8800* ..."
        rm -rf /lib/firmware/aic8800*
    fi

    info "Installing matched firmware for all chip variants..."
    cp -r "${SCRIPT_DIR}/fw/aic8800"* /lib/firmware/

    # udev rules: eject the virtual install CD so the adapter switches to Wi-Fi mode.
    if [[ -f "${SCRIPT_DIR}/aic.rules" ]]; then
        info "Installing udev rules -> /usr/lib/udev/rules.d/aic.rules"
        cp "${SCRIPT_DIR}/aic.rules" /usr/lib/udev/rules.d/aic.rules
        udevadm control --reload-rules >>"$LOG_FILE" 2>&1 || true
        udevadm trigger >>"$LOG_FILE" 2>&1 || true
    fi

    # usb_modeswitch config for the 1111:1111 "Pandora" clone variant.
    if [[ -f "${SCRIPT_DIR}/usb_modeswitch/1111_1111" ]]; then
        info "Installing usb_modeswitch config -> /etc/usb_modeswitch.d/1111:1111"
        mkdir -p /etc/usb_modeswitch.d
        cp "${SCRIPT_DIR}/usb_modeswitch/1111_1111" "/etc/usb_modeswitch.d/1111:1111"
    fi

    ok "Firmware and rules installed."
}

# ----------------------------------------------------------------------------
# DKMS build + install
# ----------------------------------------------------------------------------
install_via_dkms() {
    step "Building and installing the driver via DKMS..."

    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    cp -r "${SCRIPT_DIR}/drivers" "${SCRIPT_DIR}/dkms.conf" "$SRC_DIR/"

    info "Registering with DKMS..."
    dkms add -m "$DRV_NAME" -v "$DRV_VERSION" >>"$LOG_FILE" 2>&1

    info "Compiling (this can take a couple of minutes)..."
    if ! dkms build -m "$DRV_NAME" -v "$DRV_VERSION" >>"$LOG_FILE" 2>&1; then
        err "DKMS build failed. Last lines of the build log:"
        tail -n 25 "/var/lib/dkms/${DRV_NAME}/${DRV_VERSION}/build/make.log" 2>/dev/null || \
            tail -n 25 "$LOG_FILE"
        exit 1
    fi

    info "Installing the built module..."
    dkms install -m "$DRV_NAME" -v "$DRV_VERSION" >>"$LOG_FILE" 2>&1
    ok "Driver installed via DKMS (auto-rebuilds on kernel updates)."
}

# ----------------------------------------------------------------------------
# Load module
# ----------------------------------------------------------------------------
load_module() {
    step "Loading the kernel module..."
    depmod -a >>"$LOG_FILE" 2>&1
    modprobe -r "$MODULE_NAME" aic_load_fw 2>/dev/null || true
    if modprobe "$MODULE_NAME" >>"$LOG_FILE" 2>&1; then
        ok "Module loaded."
    else
        warn "Module installed but did not load now. A reboot usually resolves this."
    fi
}

# ----------------------------------------------------------------------------
# Verify
# ----------------------------------------------------------------------------
verify_installation() {
    step "Verifying installation..."

    local dkms_status
    dkms_status="$(dkms status "${DRV_NAME}/${DRV_VERSION}" 2>/dev/null || true)"
    if grep -q "installed" <<<"$dkms_status"; then
        ok "DKMS: $dkms_status"
    else
        warn "DKMS status unclear: ${dkms_status:-none}"
    fi

    if lsmod | grep -q "$MODULE_NAME"; then
        ok "Kernel module is loaded."
    else
        warn "Module not currently loaded (reboot or replug the adapter)."
    fi

    # Count installed firmware variants (assignment form avoids the set -e
    # pitfall of (( x++ )) returning status 1 when x starts at 0).
    local fw_count=0 d
    for d in /lib/firmware/aic8800*; do
        [[ -d "$d" ]] && fw_count=$((fw_count + 1))
    done
    if [[ $fw_count -gt 0 ]]; then
        ok "Firmware installed for ${fw_count} chip variant(s)."
    else
        warn "No firmware found under /lib/firmware/."
    fi

    # Best-effort: report the wireless interface and a quick scan if present.
    local iface="" d
    for d in /sys/class/net/wl*; do
        [[ -e "$d" ]] && { iface="$(basename "$d")"; break; }
    done
    if [[ -n "$iface" ]]; then
        ok "Wireless interface detected: $iface"
        if command -v nmcli &>/dev/null; then
            nmcli device wifi rescan >>"$LOG_FILE" 2>&1 || true
            sleep 3
            local n; n="$(nmcli -t -f SSID device wifi list 2>/dev/null | grep -vc '^$' || echo 0)"
            info "Visible networks right now: ${n}"
        fi
    else
        info "No wireless interface yet — plug in the adapter (or reboot) and check 'ip link'."
    fi
}

final_message() {
    echo
    echo "${GREEN}============================================================${NC}"
    echo "${GREEN}  Installation complete.${NC}"
    echo "${GREEN}============================================================${NC}"
    echo
    echo "Next steps:"
    echo "  1. Plug in the adapter (or reboot if it was already in)."
    echo "  2. List networks:    ${BLUE}nmcli device wifi list${NC}"
    echo "  3. Connect:          ${BLUE}nmcli device wifi connect \"SSID\" password \"PASS\"${NC}"
    echo
    echo "Set your Wi-Fi country for full channel/regulatory support, e.g.:"
    echo "  ${BLUE}sudo iw reg set SA${NC}   (and persist via /etc/modprobe.d/cfg80211.conf)"
    echo
    echo "Full log: $LOG_FILE"
    echo "Uninstall: ${BLUE}sudo ./uninstall.sh${NC}"
    echo
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
main() {
    : > "$LOG_FILE" 2>/dev/null || true
    echo "${CYAN}AIC8800D80 Wi-Fi 6 Driver — DKMS Installer${NC}"
    log "=== install start: kernel $(uname -r) ==="

    require_root
    check_sources
    check_secure_boot
    remove_conflicts
    install_dependencies
    install_firmware
    install_via_dkms
    load_module
    verify_installation
    final_message
    log "=== install end ==="
}

main "$@"
