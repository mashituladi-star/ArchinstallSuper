#!/usr/bin/env bash
#
# ArchinstallSuper — запуск официального установщика Arch Linux из live ISO.
# Скрипт намеренно НЕ размечает и НЕ форматирует диски.
#
set -Eeuo pipefail
umask 077

readonly VERSION="0.1.0"
readonly CHECK_URL="https://archlinux.org/"
readonly RESET="\033[0m"
readonly BOLD="\033[1m"
readonly CYAN="\033[36m"
readonly YELLOW="\033[33m"
readonly RED="\033[31m"
readonly GREEN="\033[32m"

say()   { printf '%b\n' "$*"; }
info()  { say "${CYAN}[INFO]${RESET} $*"; }
warn()  { say "${YELLOW}[ВНИМАНИЕ]${RESET} $*" >&2; }
error() { say "${RED}[ОШИБКА]${RESET} $*" >&2; }
success(){ say "${GREEN}[OK]${RESET} $*"; }

die() {
    error "$*"
    exit 1
}

on_error() {
    local status=$?
    error "Команда завершилась с кодом ${status}, строка ${BASH_LINENO[0]:-?}."
    error "Проверь сообщения выше. Установщик не будет автоматически перезагружать компьютер."
    exit "$status"
}
trap on_error ERR

print_header() {
    say ""
    say "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    say "${BOLD}${CYAN}║              ArchinstallSuper                ║${RESET}"
    say "${BOLD}${CYAN}║        безопасный запуск Archinstall         ║${RESET}"
    say "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    say "Версия: ${VERSION}"
    say ""
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "Запусти скрипт от root. В официальном Arch ISO ты уже root."
}

require_archiso() {
    [[ -f /etc/arch-release ]] || die "Эта система не распознана как Arch Linux."
    [[ -d /run/archiso ]] || die "Скрипт нужно запускать из live-среды официального Arch ISO (/run/archiso не найден)."
    [[ "$(uname -m)" == "x86_64" ]] || die "Ожидается архитектура x86_64, обнаружена: $(uname -m)."
    success "Обнаружена live-система Arch Linux x86_64."
}

network_is_ready() {
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --connect-timeout 5 --max-time 12 \
            --output /dev/null "$CHECK_URL" 2>/dev/null
        return $?
    fi

    if command -v ping >/dev/null 2>&1; then
        ping -c 1 -W 4 ping.archlinux.org >/dev/null 2>&1
        return $?
    fi

    return 1
}

connect_network() {
    local answer
    while ! network_is_ready; do
        warn "Не удалось подтвердить доступ к интернету."
        say "Подключи Ethernet или настрой Wi-Fi."
        if command -v iwctl >/dev/null 2>&1; then
            read -r -p "Открыть iwctl для подключения к Wi-Fi? [Д/н] " answer || answer="н"
            case "${answer,,}" in
                ""|д|да|y|yes)
                    command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi || true
                    iwctl
                    ;;
                *)
                    read -r -p "Повторить проверку сети? [Д/н] " answer || answer="н"
                    [[ "${answer,,}" == "" || "${answer,,}" == "д" || "${answer,,}" == "да" || "${answer,,}" == "y" || "${answer,,}" == "yes" ]] || die "Без интернета установка невозможна."
                    ;;
            esac
        else
            read -r -p "После подключения к сети нажми Enter (или Ctrl+C для выхода)... " answer || die "Операция отменена."
        fi
    done
    success "Интернет доступен."
}

sync_clock() {
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true >/dev/null 2>&1 || warn "Не удалось включить синхронизацию времени; проверь дату и время вручную."
        info "Проверка времени:"
        timedatectl status 2>/dev/null | sed -n '1,8p' || true
    fi
}

ensure_archinstall() {
    local answer
    if ! command -v archinstall >/dev/null 2>&1; then
        warn "Пакет archinstall не найден в текущем ISO."
        read -r -p "Обновить систему и установить archinstall через pacman -Syu? [д/Н] " answer || answer="н"
        case "${answer,,}" in
            д|да|y|yes)
                pacman -Syu --needed archinstall
                ;;
            *)
                die "Без archinstall продолжить нельзя. Установи пакет и запусти скрипт снова."
                ;;
        esac
    else
        info "Найден установленный archinstall: $(pacman -Q archinstall 2>/dev/null || printf 'версия неизвестна')."
        read -r -p "Обновить систему и archinstall сейчас через pacman -Syu? [д/Н] " answer || answer="н"
        case "${answer,,}" in
            д|да|y|yes)
                pacman -Syu --needed archinstall
                ;;
            *)
                info "Оставляю текущую версию archinstall."
                ;;
        esac
    fi

    command -v archinstall >/dev/null 2>&1 || die "Команда archinstall всё ещё недоступна после проверки пакета."
}

show_disk_warning() {
    say ""
    warn "Перед запуском проверь список дисков. Пока ничего не будет стираться."
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINTS || true
    fi
    say ""
    say "ВНИМАТЕЛЬНО: операции разметки и форматирования выполняются только"
    say "внутри официального archinstall после твоего выбора и подтверждения."
    say "Не выбирай стирание диска, если на нём есть нужные данные."
    say ""
}

run_installer() {
    local answer
    read -r -p "Запустить официальный интерактивный установщик archinstall? [Д/н] " answer || answer="н"
    case "${answer,,}" in
        ""|д|да|y|yes)
            info "Передаю управление официальному archinstall..."
            if archinstall; then
                success "archinstall завершил работу."
                say "Проверь итоговое сообщение установщика и его журнал: /var/log/archinstall/install.log"
                say "Перезагрузка не выполняется автоматически. Когда убедишься, что установка завершена, выполни: reboot"
            else
                local status=$?
                error "archinstall завершился с кодом ${status}. Система не будет перезагружена."
                say "Журнал для диагностики: /var/log/archinstall/install.log"
                return "$status"
            fi
            ;;
        *)
            info "Запуск отменён. Никакие диски не изменялись."
            ;;
    esac
}

main() {
    print_header
    require_root
    require_archiso
    connect_network
    sync_clock
    ensure_archinstall
    show_disk_warning
    run_installer
}

main "$@"
