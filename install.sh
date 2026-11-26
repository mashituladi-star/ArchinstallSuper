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
ArchinstallSuper v$VERSION — самостоятельный UEFI-установщик Arch Linux

Использование:
  bash install.sh              Запустить интерактивную установку
  bash install.sh --check      Проверить UEFI, live-среду и интернет
  bash install.sh --dry-run    Собрать настройки и показать план без изменений
  bash install.sh --plain      Не использовать dialog, только текстовый режим
  bash install.sh --debug      Подробный отладочный вывод
  bash install.sh --log FILE   Писать журнал в указанный файл
  bash install.sh --version
  bash install.sh --help

ВАЖНО:
  * Поддерживается только x86_64 UEFI; Legacy/CSM не поддерживается.
  * Обычный запуск полностью стирает выбранный диск после подтверждения.
  * Проект не использует archinstall; применяются pacstrap, pacman,
    systemd-boot, mkinitcpio, sgdisk, mkfs и другие штатные инструменты.
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
                    error "--log требует путь к файлу."
                    exit 2
                }
                LOG_FILE=$1
                ;;
            *)
                usage >&2
                error "Неизвестный аргумент: $1"
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
        printf 'Не удалось запустить полноэкранный интерфейс. Запусти: bash install.sh --plain\n' >&4
        exit 1
    fi
    if [[ $splash_choice != install ]]; then
        info "Выход по выбору пользователя."
        return 0
    fi

    validate_environment
    recovery_lock

    ui_step_set 0
    network_ensure
    ui_step_set 1
    if ! ui_run_logged "Подготовка пакетов" install_refresh_packages; then
        die "Не удалось подготовить базу пакетов live-среды."
    fi
    hw_detect
    hw_show_screen
    plugin_load_all

    workflow_collect
    workflow_show_summary

    if ((DRY_RUN)); then
        ui_msg "Dry-run завершён: диск не изменялся.\n\nВыбранные параметры показаны на предыдущем экране." \
            "Dry-run"
        return 0
    fi

    workflow_final_confirm
    workflow_execute
    workflow_after_success
}

main "$@"
