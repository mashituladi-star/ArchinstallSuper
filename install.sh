#!/usr/bin/env bash
#
# ArchinstallSuper — выбор режима установки поверх официального Arch ISO.
# Скрипт не размечает и не форматирует диски: это остаётся в archinstall.
#
set -Eeuo pipefail
umask 077

readonly VERSION="0.2.0"
readonly CHECK_URL="https://archlinux.org/"
readonly CONFIG_PATH="/tmp/archinstallsuper-config.json"
readonly RESET="\033[0m"
readonly BOLD="\033[1m"
readonly CYAN="\033[36m"
readonly YELLOW="\033[33m"
readonly RED="\033[31m"
readonly GREEN="\033[32m"

INSTALL_MODE=""
PROFILE_DESKTOP=""
PACKAGE_LIST=()

say()     { printf '%b\n' "$*"; }
info()    { say "${CYAN}[INFO]${RESET} $*"; }
warn()    { say "${YELLOW}[ВНИМАНИЕ]${RESET} $*" >&2; }
error()   { say "${RED}[ОШИБКА]${RESET} $*" >&2; }
success() { say "${GREEN}[OK]${RESET} $*"; }

die() {
    error "$*"
    exit 1
}

on_error() {
    local status="$1"
    error "Команда завершилась с кодом ${status}, строка ${BASH_LINENO[0]:-?}."
    error "Проверь сообщения выше. Установщик не будет автоматически перезагружать компьютер."
    exit "$status"
}
trap 'on_error "$?"' ERR

print_header() {
    say ""
    say "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    say "${BOLD}${CYAN}║              ArchinstallSuper                ║${RESET}"
    say "${BOLD}${CYAN}║        режимы установки Arch Linux           ║${RESET}"
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
            д|да|y|yes) pacman -Syu --needed archinstall ;;
            *) die "Без archinstall продолжить нельзя. Установи пакет и запусти скрипт снова." ;;
        esac
    else
        info "Найден установленный archinstall: $(pacman -Q archinstall 2>/dev/null || printf 'версия неизвестна')."
        read -r -p "Обновить систему и archinstall сейчас через pacman -Syu? [д/Н] " answer || answer="н"
        case "${answer,,}" in
            д|да|y|yes) pacman -Syu --needed archinstall ;;
            *) info "Оставляю текущую версию archinstall." ;;
        esac
    fi

    command -v archinstall >/dev/null 2>&1 || die "Команда archinstall всё ещё недоступна после проверки пакета."
    command -v python >/dev/null 2>&1 || die "В live-системе не найден Python, необходимый archinstall для конфигурации."
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local answer

    if [[ "$default" == "yes" ]]; then
        read -r -p "$prompt [Д/н] " answer || answer=""
        case "${answer,,}" in
            н|нет|n|no) return 1 ;;
            *) return 0 ;;
        esac
    fi

    read -r -p "$prompt [д/Н] " answer || answer=""
    case "${answer,,}" in
        д|да|y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

select_custom_options() {
    local desktop_choice
    local package_line
    local package
    local -a custom_packages=()

    say ""
    say "${BOLD}Кастомная установка — рабочее окружение${RESET}"
    say "  1) GNOME (выбрано по умолчанию)"
    say "  2) KDE Plasma"
    say "  3) XFCE"
    say "  4) Cinnamon"
    say "  0) Без графики — только консоль"
    read -r -p "Выбери окружение [1]: " desktop_choice || desktop_choice="1"

    case "${desktop_choice:-1}" in
        1) PROFILE_DESKTOP="GNOME" ;;
        2) PROFILE_DESKTOP="KDE Plasma" ;;
        3) PROFILE_DESKTOP="Xfce4" ;;
        4) PROFILE_DESKTOP="Cinnamon" ;;
        0) PROFILE_DESKTOP="" ;;
        *) die "Неизвестный вариант рабочего окружения." ;;
    esac

    PACKAGE_LIST=()
    if ask_yes_no "Добавить набор системных утилит (nano, vim, fastfetch, btop, htop, curl, wget и архиваторы)?" no; then
        PACKAGE_LIST+=(nano vim fastfetch btop htop curl wget zip unzip)
    fi
    if ask_yes_no "Добавить инструменты разработчика (git, base-devel, Python, Node.js и npm)?" no; then
        PACKAGE_LIST+=(git base-devel python python-pip nodejs npm)
    fi
    if ask_yes_no "Добавить программы для повседневной работы (Firefox, VLC, GIMP, LibreOffice)?" no; then
        PACKAGE_LIST+=(firefox vlc gimp libreoffice-fresh)
    fi

    say ""
    read -r -p "Дополнительные пакеты через пробел или запятую (можно оставить пустым): " package_line || package_line=""
    package_line="${package_line//,/ }"
    if [[ -n "$package_line" ]]; then
        read -r -a custom_packages <<< "$package_line"
        for package in "${custom_packages[@]}"; do
            [[ "$package" =~ ^[[:alnum:]@._+-]+$ ]] || die "Недопустимое имя пакета: $package"
            PACKAGE_LIST+=("$package")
        done
    fi
}

select_install_mode() {
    local choice

    say "${BOLD}Выбери режим установки:${RESET}"
    say ""
    say "  1) Минимальная"
    say "     Консольная Arch Linux без рабочего стола. Только основа системы"
    say "     и NetworkManager для подключения к сети после установки."
    say ""
    say "  2) Базовая"
    say "     GNOME, PipeWire, Firefox и несколько необходимых утилит."
    say ""
    say "  3) Полная"
    say "     GNOME, мультимедиа, офисные и графические программы,"
    say "     инструменты разработчика и системные утилиты."
    say ""
    say "  4) Кастомная"
    say "     Самостоятельный выбор рабочего окружения и дополнительных пакетов."
    say ""

    while true; do
        read -r -p "Режим [1-4]: " choice || die "Выбор режима отменён."
        case "$choice" in
            1)
                INSTALL_MODE="minimal"
                PROFILE_DESKTOP=""
                PACKAGE_LIST=()
                break
                ;;
            2)
                INSTALL_MODE="basic"
                PROFILE_DESKTOP="GNOME"
                PACKAGE_LIST=(firefox nano git fastfetch)
                break
                ;;
            3)
                INSTALL_MODE="full"
                PROFILE_DESKTOP="GNOME"
                PACKAGE_LIST=(firefox libreoffice-fresh vlc gimp gnome-tweaks flatpak git base-devel fastfetch btop htop curl wget zip unzip python python-pip)
                break
                ;;
            4)
                INSTALL_MODE="custom"
                select_custom_options
                break
                ;;
            *)
                warn "Введи число от 1 до 4."
                ;;
        esac
    done

    success "Выбран режим: $INSTALL_MODE"
}

generate_archinstall_config() {
    python - "$CONFIG_PATH" "$PROFILE_DESKTOP" "${PACKAGE_LIST[@]}" <<'PY'
import json
import sys

config_path, desktop, *packages = sys.argv[1:]

# Сохраняем порядок и убираем дубликаты, не меняя введённые имена пакетов.
packages = list(dict.fromkeys(packages))

config = {
    # NetworkManager будет настроен в установленной системе.
    "network_config": {"type": "nm"},
    "packages": packages,
    # Без профиля Desktop Archinstall установит систему без графической оболочки.
    "profile_config": None,
}

if desktop:
    config["profile_config"] = {
        "profile": {
            "main": "Desktop",
            "details": [desktop],
        },
        "gfx_driver": "All open-source (default)",
    }
    config["audio_config"] = {"audio": "pipewire"}

with open(config_path, "w", encoding="utf-8") as handle:
    json.dump(config, handle, ensure_ascii=False, indent=2)
    handle.write("\n")
PY

    python -m json.tool "$CONFIG_PATH" >/dev/null || die "Не удалось проверить JSON-конфигурацию archinstall."
}

show_install_summary() {
    say ""
    say "${BOLD}Сводка выбранной установки${RESET}"
    say "  Режим: $INSTALL_MODE"
    if [[ -n "$PROFILE_DESKTOP" ]]; then
        say "  Рабочее окружение: $PROFILE_DESKTOP"
        say "  Звук: PipeWire"
    else
        say "  Рабочее окружение: отсутствует (после загрузки будет консоль)"
    fi
    if (("${#PACKAGE_LIST[@]}" > 0)); then
        say "  Дополнительные пакеты: ${PACKAGE_LIST[*]}"
    else
        say "  Дополнительные пакеты: нет"
    fi
    say "  Сеть в установленной системе: NetworkManager"
    say ""
    info "Проверенная конфигурация archinstall: $CONFIG_PATH"
    cat "$CONFIG_PATH"
    say ""
}

show_disk_warning() {
    say ""
    warn "Перед запуском проверь список дисков. Пока ничего не будет стираться."
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -o NAME,SIZE,MODEL,TYPE,FSTYPE,MOUNTPOINTS || true
    fi
    say ""
    say "Archinstall оставлен интерактивным: диск, разметку, форматирование,"
    say "загрузчик, пользователя и пароли ты выберешь и подтвердишь сам."
    say "Не выбирай стирание диска, если на нём есть нужные данные."
    say ""
}

run_installer() {
    local answer
    local status=0

    read -r -p "Запустить официальный интерактивный установщик archinstall с выбранным режимом? [Д/н] " answer || answer="н"
    case "${answer,,}" in
        ""|д|да|y|yes)
            info "Передаю выбранный профиль официальному archinstall..."
            archinstall --config "$CONFIG_PATH" || status=$?

            if [[ "$status" -eq 0 ]]; then
                success "archinstall завершил работу."
                say "Проверь итоговое сообщение установщика и журнал: /var/log/archinstall/install.log"
                say "Перезагрузка не выполняется автоматически. Когда убедишься, что установка завершена, выполни: reboot"
            else
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
    select_install_mode
    generate_archinstall_config
    show_install_summary
    show_disk_warning
    run_installer
}

main "$@"
