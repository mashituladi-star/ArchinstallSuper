#!/usr/bin/env bash
# shellcheck shell=bash
# Recovery manager: single-instance lock, signal handling, safe unmount and
# actionable failure messages.

[[ -n ${AS_RECOVERY_LOADED:-} ]] && return 0
AS_RECOVERY_LOADED=1

: "${LOCK_FD:=9}"

recovery_lock() {
    [[ $AS_TEST == 1 ]] && return 0
    mkdir -p -- "$STATE_DIR" || die "Не удалось создать $STATE_DIR."
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "Другой экземпляр ArchinstallSuper уже работает (lock: $LOCK_FILE)."
    fi
}

recovery_release() {
    [[ $AS_TEST == 1 ]] && return 0
    exec {LOCK_FD}>&- 2>/dev/null || true
}

recovery_safe_unmount() {
    if ((MOUNTED_BY_US)); then
        storage_unmount_target || warn "Целевая система осталась смонтированной в $TARGET."
    fi
}

recovery_cleanup() {
    local rc=${1:-0}
    trap - EXIT INT TERM HUP
    if ((rc != 0)); then
        warn "Установка прервана (код $rc)."
        [[ -n ${INSTALL_PHASE:-} ]] && warn "Прерванная фаза: $INSTALL_PHASE"
        if ((INSTALL_STARTED)); then
            if ((MOUNTED_BY_US)); then
                install_copy_log >/dev/null 2>&1 || true
            fi
            recovery_safe_unmount
            if [[ ${LUKS_OPENED:-0} == 1 ]]; then
                if mountpoint -q "$TARGET" 2>/dev/null; then
                    warn "LUKS-контейнер оставлен открытым: $TARGET всё ещё смонтирован."
                else
                    security_luks_close || true
                fi
            fi
            warn "Журнал: $LOG_FILE"
            warn "Если диск уже был изменён, не запускай установку повторно вслепую:"
            warn "  1) проверь lsblk; 2) при необходимости закрой LUKS: cryptsetup close $LUKS_NAME;"
            warn "  3) размонтируй: umount -R $TARGET; 4) перезагрузись в live-среду и повтори."
        else
            warn "Диск не изменялся: установка остановлена до этапа разметки."
            warn "Журнал: $LOG_FILE"
        fi
    else
        recovery_safe_unmount
    fi

    # A pre-install failure has already been shown by die(). If the disk was
    # touched, show a final screen with the recovery steps as well.
    if ((rc != 0 && INSTALL_STARTED)) && [[ ${AS_UI_CHILD:-0} != 1 ]] &&
        declare -F ui_error >/dev/null 2>&1 && [[ ${UI_MODE:-plain} != plain ]]; then
        ui_error "Установка прервана (код $rc).\n\nЖурнал: $LOG_FILE\n\nПроверь lsblk. Если диск уже изменён, не запускай установку вслепую: закрой LUKS (cryptsetup close ${LUKS_NAME:-cryptroot}), размонтируй $TARGET (umount -R $TARGET) и перезагрузись в live-среду." \
            "Установка прервана"
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
    warn "Получен сигнал $signal. Останавливаю установку."
    exit 130
}

recovery_init() {
    [[ $AS_TEST == 1 ]] && return 0
    trap 'recovery_on_exit' EXIT
    trap 'recovery_on_signal INT' INT
    trap 'recovery_on_signal TERM' TERM
    trap 'recovery_on_signal HUP' HUP
}
