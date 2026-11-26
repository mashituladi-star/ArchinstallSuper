#!/usr/bin/env bash
# shellcheck shell=bash
# Installation engine: package refresh, pacstrap, log preservation and final
# verification. This module deliberately contains no partitioning logic.

[[ -n ${AS_INSTALL_LOADED:-} ]] && return 0
AS_INSTALL_LOADED=1

install_refresh_packages() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="package-database"
    info "Refreshing the live package database."
    if ! core_retry 3 3 pacman -Sy --noconfirm >/dev/null 2>&1; then
        die "Could not refresh the package database. Check mirrors and network."
    fi
    # On an older ISO the host keyring may be too old for current packages.
    if ! pacman -S --needed --noconfirm archlinux-keyring >/dev/null 2>&1; then
        warn "Could not update archlinux-keyring in the live environment; pacstrap -K will try to initialize the keyring."
    fi
}

install_pacstrap() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="pacstrap"
    ((${#PACKAGES[@]} > 0)) || die "The package list is empty."
    info "Installing packages: ${PACKAGES[*]}"
    if ! ui_run_logged "Installing packages" pacstrap -K "$TARGET" "${PACKAGES[@]}"; then
        die "pacstrap failed. The system was not installed."
    fi
    [[ -x $TARGET/bin/bash ]] || die "/bin/bash is missing from the target system after pacstrap."
}

install_copy_log() {
    if [[ -f $LOG_FILE ]]; then
        mkdir -p "$TARGET/var/log" || true
        if install -Dm600 "$LOG_FILE" "$TARGET/var/log/archinstallsuper-install.log" 2>/dev/null; then
            info "Installation log saved to /var/log/archinstallsuper-install.log."
        else
            warn "Could not copy the log into the target system."
        fi
    fi
}

install_verify() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="verification"
    info "Verifying the installation."
    validate_install_result
    if ! arch-chroot "$TARGET" bootctl --esp-path=/boot status >/dev/null 2>&1; then
        warn "bootctl status reported a warning; check the boot entries manually."
    fi
    findmnt --verify --tab-file "$TARGET/etc/fstab" >/dev/null 2>&1 ||
        warn "findmnt --verify reported fstab warnings."
    sync
}

install_success_text() {
    cat <<EOF
Arch Linux installation complete.

Disk:        $DISK
Filesystem:  $FS_TYPE
Kernel:      $KERNEL
Encryption:  $(if [[ ${ENCRYPT:-0} == 1 ]]; then echo "LUKS2"; else echo "no"; fi)
User:        $USERNAME
Hostname:    $HOSTNAME

Log: $LOG_FILE
The log is also saved to /var/log/archinstallsuper-install.log.

The system is unmounted. You can remove the installation media and reboot.
EOF
}
