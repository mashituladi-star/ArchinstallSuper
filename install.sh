#!/usr/bin/env bash
# ArchinstallSuper — самостоятельный UEFI-установщик Arch Linux.
# Точка входа: разбор аргументов и порядок этапов. Вся логика — в lib/.
set -Eeuo pipefail
umask 077

VERSION=0.11.0
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# Defaults for the interactive workflow. They are intentionally explicit:
# the live ISO's own hostname must not leak into the target system.
HOSTNAME=archlinux
USERNAME=
TIMEZONE=Europe/Prague
LOCALE=en_US.UTF-8
KEYMAP=us
MODE=minimal
DESKTOP=
KERNEL=linux
FS_TYPE=ext4
ENCRYPT=0
ZRAM=0
ROOT_POLICY=password
ROOT_PASSWORD=
USER_PASSWORD=
LUKS_PASSWORD=
CHECK_ONLY=0
DRY_RUN=0

# shellcheck source=lib/core.sh
source "$SCRIPT_DIR/lib/core.sh"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/hardware.sh
source "$SCRIPT_DIR/lib/hardware.sh"
# shellcheck source=lib/validate.sh
source "$SCRIPT_DIR/lib/validate.sh"
# shellcheck source=lib/network.sh
source "$SCRIPT_DIR/lib/network.sh"
# shellcheck source=lib/security.sh
source "$SCRIPT_DIR/lib/security.sh"
# shellcheck source=lib/storage.sh
source "$SCRIPT_DIR/lib/storage.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/boot.sh
source "$SCRIPT_DIR/lib/boot.sh"
# shellcheck source=lib/install.sh
source "$SCRIPT_DIR/lib/install.sh"
# shellcheck source=lib/recovery.sh
source "$SCRIPT_DIR/lib/recovery.sh"
# shellcheck source=lib/plugins.sh
source "$SCRIPT_DIR/lib/plugins.sh"
# shellcheck source=lib/workflow.sh
source "$SCRIPT_DIR/lib/workflow.sh"

usage() {
    cat <<EOF
ArchinstallSuper v$VERSION — standalone UEFI installer for Arch Linux

Usage:
  bash install.sh              Start the interactive installer
  bash install.sh --check      Check UEFI, live environment and network
  bash install.sh --dry-run    Collect settings and show the plan without changes
  bash install.sh --plain      Do not use the full-screen UI; plain text only
  bash install.sh --debug      Verbose debug output
  bash install.sh --log FILE   Write the log to FILE
  bash install.sh --version
  bash install.sh --help

IMPORTANT:
  * Only x86_64 UEFI is supported; Legacy/CSM is not supported.
  * A normal run erases the selected disk completely after confirmation.
  * The installer does not use archinstall; it uses pacstrap, pacman,
    systemd-boot, mkinitcpio, sgdisk, mkfs and other standard tools.
EOF
}

parse_args() {
    while (($#)); do
        case $1 in
            --help|-h)
                usage
                exit 0
                ;;
            --version|-V)
                printf 'ArchinstallSuper %s\n' "$VERSION"
                exit 0
                ;;
            --check)
                CHECK_ONLY=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --plain)
                AS_PLAIN=1
                ;;
            --debug)
                AS_DEBUG=1
                ;;
            --log)
                shift
                [[ $# -gt 0 ]] || {
                    error "--log requires a file path."
                    exit 2
                }
                LOG_FILE=$1
                ;;
            *)
                usage >&2
                error "Unknown argument: $1"
                exit 2
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    # Detect the full-screen path before core_init so the first screen appears
    # without a flash of shell output. The same test is repeated in ui_init.
    if [[ ${AS_PLAIN:-0} != 1 && ${CHECK_ONLY:-0} != 1 && -t 0 && -t 2 ]] &&
        command -v python3 >/dev/null 2>&1 &&
        python3 -c 'import curses' >/dev/null 2>&1; then
        AS_UI_EARLY=1
    else
        AS_UI_EARLY=0
    fi
    export AS_UI_EARLY

    core_init
    recovery_init

    if ((CHECK_ONLY)); then
        workflow_check_only
        return $?
    fi

    # Open the interface before any validation. From this point the terminal
    # shows only the installer window; diagnostics go to the log file.
    ui_init
    ui_steps_init

    local splash_choice
    if ! splash_choice=$(ui_splash); then
        printf 'Could not start the full-screen interface. Run: bash install.sh --plain\n' >&4
        exit 1
    fi
    if [[ $splash_choice != install ]]; then
        info "Exiting at the user's request."
        return 0
    fi

    validate_environment
    recovery_lock

    ui_step_set 0
    network_ensure
    ui_step_set 1
    if ! ui_run_logged "Preparing packages" install_refresh_packages; then
        die "Could not prepare the live package database."
    fi
    hw_detect
    hw_show_screen
    plugin_load_all

    workflow_collect
    workflow_show_summary

    if ((DRY_RUN)); then
        ui_msg "Dry-run complete: the disk was not changed.\n\nThe selected settings are shown on the previous screen." \
            "Dry-run"
        return 0
    fi

    workflow_final_confirm
    workflow_execute
    workflow_after_success
}

main "$@"
