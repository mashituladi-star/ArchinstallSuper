#!/usr/bin/env bash
# Boot the official Arch Linux ISO in a UEFI virtual machine with a blank
# virtio disk attached. This is an interactive harness: it proves that the
# installer runs in a real UEFI environment, but the installation itself is
# driven inside the VM (the installer is intentionally interactive).
#
# Requirements:
#   * qemu-system-x86_64
#   * OVMF/edk2 UEFI firmware (Arch: edk2-ovmf, Debian/Ubuntu: ovmf)
#   * an official Arch Linux ISO (set ARCH_ISO=/path/to/file.iso)
#
# Nothing here runs in the unit-test suite: it needs KVM/OVMF and a real ISO.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"

ISO=${ARCH_ISO:-}
WORKDIR=${WORKDIR:-}
DISK_SIZE=${DISK_SIZE:-30G}
MEMORY=${MEMORY:-4096}
CPUS=${CPUS:-2}
KEEP=0
FORCE=0
DISPLAY_MODE=${DISPLAY_MODE:-auto}
VNC=${VNC:-}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: bash tests/integration/qemu-uefi.sh [options]

Options:
  --iso PATH         Official Arch Linux ISO (or set ARCH_ISO).
  --workdir DIR      Keep disk image and UEFI variables in DIR.
  --disk-size SIZE   Virtual disk size (default: 30G).
  --memory MiB       Guest RAM (default: 4096).
  --cpus N           Guest vCPUs (default: 2).
  --display MODE     auto, gtk, sdl, none or vnc (default: auto).
  --vnc DISPLAY      VNC endpoint when --display vnc (for example :1).
  --keep             Do not delete the disk image on exit.
  --force            Reuse an existing disk image (destroys its contents).
  -h, --help         Show this help.

Environment overrides: ARCH_ISO, WORKDIR, DISK_SIZE, MEMORY, CPUS,
DISPLAY_MODE, VNC, OVMF_CODE, OVMF_VARS.
EOF
}

while (($#)); do
    case $1 in
        --iso) ISO=${2:-}; shift 2 ;;
        --workdir) WORKDIR=${2:-}; shift 2 ;;
        --disk-size) DISK_SIZE=${2:-}; shift 2 ;;
        --memory) MEMORY=${2:-}; shift 2 ;;
        --cpus) CPUS=${2:-}; shift 2 ;;
        --display) DISPLAY_MODE=${2:-}; shift 2 ;;
        --vnc) VNC=${2:-}; shift 2 ;;
        --keep) KEEP=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[[ -n $ISO ]] || die "set ARCH_ISO or pass --iso /path/to/archlinux.iso"
[[ -f $ISO ]] || die "ISO not found: $ISO"
command -v qemu-system-x86_64 >/dev/null 2>&1 ||
    die "qemu-system-x86_64 is not installed (Arch: qemu-full, Debian: qemu-system-x86)."
[[ $MEMORY =~ ^[0-9]+$ ]] || die "invalid --memory value: $MEMORY"
[[ $CPUS =~ ^[0-9]+$ ]] || die "invalid --cpus value: $CPUS"

detect_ovmf() {
    [[ -n ${OVMF_CODE:-} && -n ${OVMF_VARS:-} ]] && return 0
    local code vars
    for code in \
        /usr/share/edk2/x64/OVMF_CODE.4m.fd \
        /usr/share/edk2/x64/OVMF_CODE.fd \
        /usr/share/OVMF/OVMF_CODE_4M.fd \
        /usr/share/OVMF/OVMF_CODE.fd \
        /usr/share/qemu/OVMF_CODE.fd; do
        [[ -f $code ]] || continue
        vars=${code/CODE/VARS}
        [[ -f $vars ]] || continue
        OVMF_CODE=$code
        OVMF_VARS=$vars
        return 0
    done
    return 1
}

detect_ovmf ||
    die "OVMF firmware not found. Install edk2-ovmf/ovmf or set OVMF_CODE and OVMF_VARS."

if [[ -n $WORKDIR ]]; then
    mkdir -p "$WORKDIR"
else
    WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/archinstallsuper-qemu.XXXXXX")
fi
DISK_IMG="$WORKDIR/disk.qcow2"
VARS_IMG="$WORKDIR/OVMF_VARS.fd"

cleanup() {
    if ((KEEP == 0)); then
        rm -rf -- "$WORKDIR"
    else
        printf 'Kept virtual machine files in %s\n' "$WORKDIR"
    fi
}
trap cleanup EXIT

if [[ -e $DISK_IMG ]]; then
    if ((FORCE == 0)); then
        die "$DISK_IMG already exists; pass --force to replace it or choose another --workdir."
    fi
    rm -f -- "$DISK_IMG"
fi
qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE" >/dev/null ||
    die "failed to create $DISK_IMG"
cp -- "$OVMF_VARS" "$VARS_IMG"

ACCEL=tcg
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
    ACCEL=kvm
else
    printf 'WARNING: /dev/kvm is not available; using slow TCG emulation.\n' >&2
fi

case $DISPLAY_MODE in
    auto)
        if [[ -n ${WAYLAND_DISPLAY:-} || -n ${DISPLAY:-} ]]; then
            DISPLAY_MODE=gtk
        else
            DISPLAY_MODE=none
        fi
        ;;
esac

DISPLAY_ARGS=(-display "$DISPLAY_MODE")
SERIAL_ARGS=(-serial mon:stdio)
case $DISPLAY_MODE in
    none)
        DISPLAY_ARGS=(-display none)
        ;;
    vnc)
        [[ -n $VNC ]] || VNC=:1
        DISPLAY_ARGS=(-display none -vnc "$VNC")
        ;;
esac

cat <<EOF
ArchinstallSuper UEFI integration VM
  ISO:        $ISO
  Disk:       $DISK_IMG ($DISK_SIZE)
  Firmware:   $OVMF_CODE
  Variables:  $VARS_IMG
  Accelerator:$ACCEL
  Display:    $DISPLAY_MODE${VNC:+ (VNC $VNC)}

Inside the live ISO:
  1. Verify UEFI:            ls /sys/firmware/efi
  2. Connect the network:    iwctl (Wi-Fi) or DHCP on the virtio NIC
  3. Get the installer:      pacman -Sy --needed git
                             git clone https://github.com/mashituladi-star/ArchinstallSuper.git
                             cd ArchinstallSuper
  4. Preflight:              bash install.sh --check
  5. Install:                bash install.sh
  6. Choose the virtio disk (usually /dev/vda) and finish the wizard.
  7. Power off, then boot the same VM again to verify systemd-boot.

The VM uses a blank disk: the installer will ask for two explicit
confirmations before writing anything.
EOF

if [[ $DISPLAY_MODE == none && -z $VNC ]]; then
    cat <<'EOF'

NOTE: no graphical display is available. For a usable console either:
  * run with a desktop session (DISPLAY/WAYLAND_DISPLAY set), or
  * use --display vnc --vnc :1 and connect a VNC client, or
  * edit the ISO boot entry and add console=ttyS0 for serial output.
EOF
fi

exec qemu-system-x86_64 \
    -machine "q35,accel=$ACCEL" \
    -cpu max \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
    -drive "if=pflash,format=raw,file=$VARS_IMG" \
    -drive "file=$ISO,media=cdrom,readonly=on" \
    -drive "file=$DISK_IMG,if=virtio,format=qcow2" \
    -boot order=d,menu=on \
    -nic user,model=virtio-net-pci \
    -device virtio-rng-pci \
    "${DISPLAY_ARGS[@]}" \
    "${SERIAL_ARGS[@]}"
