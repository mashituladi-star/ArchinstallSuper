#!/usr/bin/env bash
# shellcheck shell=bash
# Installation engine: package refresh, pacstrap, log preservation and final
# verification. This module deliberately contains no partitioning logic.

[[ -n ${AS_INSTALL_LOADED:-} ]] && return 0
AS_INSTALL_LOADED=1

install_refresh_packages() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="package-database"
    info "Обновляю базу пакетов live-системы."
    if ! core_retry 3 3 pacman -Sy --noconfirm >/dev/null 2>&1; then
        die "Не удалось обновить базу пакетов. Проверь зеркала и интернет."
    fi
    # On an older ISO the host keyring may be too old for current packages.
    if ! pacman -S --needed --noconfirm archlinux-keyring >/dev/null 2>&1; then
        warn "Не удалось обновить archlinux-keyring в live-системе; pacstrap -K попробует инициализировать keyring."
    fi
}

install_pacstrap() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="pacstrap"
    ((${#PACKAGES[@]} > 0)) || die "Список пакетов пуст."
    info "Устанавливаю пакеты: ${PACKAGES[*]}"
    if ! ui_run_logged "Установка пакетов" pacstrap -K "$TARGET" "${PACKAGES[@]}"; then
        die "pacstrap завершился с ошибкой. Система не установлена."
    fi
    [[ -x $TARGET/bin/bash ]] || die "После pacstrap в целевой системе нет /bin/bash."
}

install_copy_log() {
    if [[ -f $LOG_FILE ]]; then
        mkdir -p "$TARGET/var/log" || true
        if install -Dm600 "$LOG_FILE" "$TARGET/var/log/archinstallsuper-install.log" 2>/dev/null; then
            info "Журнал установки сохранён в /var/log/archinstallsuper-install.log."
        else
            warn "Не удалось скопировать журнал в целевую систему."
        fi
    fi
}

install_verify() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="verification"
    info "Проверяю результат установки."
    validate_install_result
    if ! arch-chroot "$TARGET" bootctl --esp-path=/boot status >/dev/null 2>&1; then
        warn "bootctl status сообщил о замечании; проверь загрузочные записи вручную."
    fi
    findmnt --verify --tab-file "$TARGET/etc/fstab" >/dev/null 2>&1 ||
        warn "findmnt --verify нашёл замечания к fstab."
    sync
}

install_success_text() {
    cat <<EOF
Установка Arch Linux завершена.

Диск:        $DISK
Файловая система: $FS_TYPE
Ядро:        $KERNEL
Шифрование:  $(if [[ ${ENCRYPT:-0} == 1 ]]; then echo "LUKS2"; else echo "нет"; fi)
Пользователь: $USERNAME
Hostname:    $HOSTNAME

Журнал: $LOG_FILE
Журнал также сохранён в /var/log/archinstallsuper-install.log.

Система размонтирована. Можно извлечь установочный носитель и перезагрузиться.
EOF
}
