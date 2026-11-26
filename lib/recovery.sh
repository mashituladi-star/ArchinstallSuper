#!/usr/bin/env bash
# shellcheck shell=bash
# Recovery manager: single-instance lock, signal handling, safe unmount and
# actionable failure messages.

[[ -n ${AS_RECOVERY_LOADED:-} ]] && return 0
AS_RECOVERY_LOADED=1

: "${LOCK_FD:=9}"

recovery_lock() {
    [[ $AS_TEST == 1 ]] && return 0
    mkdir -p -- "$STATE_DIR" || die "Could not create $STATE_DIR."
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "Another ArchinstallSuper instance is already running (lock: $LOCK_FILE)."
    fi
}

recovery_release() {
    [[ $AS_TEST == 1 ]] && return 0
    exec {LOCK_FD}>&- 2>/dev/null || true
}

recovery_safe_unmount() {
    if ((MOUNTED_BY_US)); then
        storage_unmount_target || warn "The target system is still mounted at $TARGET."
    fi
}

recovery_cleanup() {
    local rc=${1:-0}
    trap - EXIT INT TERM HUP
    if ((rc != 0)); then
        warn "Installation aborted (code $rc)."
        [[ -n ${INSTALL_PHASE:-} ]] && warn "Aborted phase: $INSTALL_PHASE"
        if ((INSTALL_STARTED)); then
            if ((MOUNTED_BY_US)); then
                install_copy_log >/dev/null 2>&1 || true
            fi
            recovery_safe_unmount
            if [[ ${LUKS_OPENED:-0} == 1 ]]; then
                if mountpoint -q "$TARGET" 2>/dev/null; then
                    warn "LUKS container left open: $TARGET is still mounted."
                else
                    security_luks_close || true
                fi
            fi
            warn "Log: $LOG_FILE"
            warn "If the disk was already modified, do not blindly rerun the installer:"
            warn "  1) check lsblk; 2) if needed, close LUKS: cryptsetup close $LUKS_NAME;"
            warn "  3) unmount: umount -R $TARGET; 4) reboot into the live environment and retry."
        else
            warn "The disk was not changed: installation stopped before partitioning."
            warn "Log: $LOG_FILE"
        fi
    else
        recovery_safe_unmount
    fi

    # A pre-install failure has already been shown by die(). If the disk was
    # touched, show a final screen with the recovery steps as well.
    if ((rc != 0 && INSTALL_STARTED)) && [[ ${AS_UI_CHILD:-0} != 1 ]] &&
        declare -F ui_error >/dev/null 2>&1 && [[ ${UI_MODE:-plain} != plain ]]; then
        ui_error "Installation aborted (code $rc).\n\nLog: $LOG_FILE\n\nCheck lsblk. If the disk was already modified, do not blindly rerun the installer: close LUKS (cryptsetup close ${LUKS_NAME:-cryptroot}), unmount $TARGET (umount -R $TARGET) and reboot into the live environment." \
            "Installation aborted"
    fi

    if [[ -n ${TEMP_DIR:-} && -d $TEMP_DIR ]]; then
        rm -rf -- "$TEMP_DIR" 2>/dev/null || true
    fi
    recovery_release
}

recovery_on_exit() {
    local rc=$?
    recovery_cleanup "$rc"
}

recovery_on_signal() {
    local signal=$1
    trap - INT TERM HUP
    warn "Received signal $signal. Stopping the installation."
    exit 130
}

recovery_init() {
    [[ $AS_TEST == 1 ]] && return 0
    trap 'recovery_on_exit' EXIT
    trap 'recovery_on_signal INT' INT
    trap 'recovery_on_signal TERM' TERM
    trap 'recovery_on_signal HUP' HUP
}
