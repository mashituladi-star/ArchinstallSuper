#!/usr/bin/env bash
# shellcheck shell=bash
# Terminal UI layer.
#
# Three backends are supported:
#   tui    — the modern full-screen Python/curses interface in lib/tui.py;
#   dialog — the classic dialog(1) interface, kept as a fallback;
#   plain  — line-oriented output for --plain, --check and non-interactive use.
#
# The UI never writes return values to the log. Interactive drawing goes to
# fd 4 (the original stderr), while values returned to the caller are written
# to stdout and captured by command substitution. This is why the TUI helper
# writes its result to fd 3 and draws on fd 1 redirected to the terminal.

[[ -n ${AS_UI_LOADED:-} ]] && return 0
AS_UI_LOADED=1

AS_UI_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

: "${AS_PLAIN:=0}"
: "${UI_MODE:=plain}"
: "${UI_BACKTITLE:=ARCHINSTALLSUPER  |  UEFI INSTALLER}"
: "${UI_HEIGHT:=22}"
: "${UI_WIDTH:=78}"
: "${UI_LIST_HEIGHT:=12}"
: "${AS_UI_VERSION:=${VERSION:-0.11.0}}"

UI_STEPS=()
UI_STEP_INDEX=-1
AS_UI_STEPS=
AS_UI_STEP_INDEX=-1

if [[ -t 4 ]]; then
    UI_C_RESET=$'\033[0m'
    UI_C_BOLD=$'\033[1m'
    UI_C_DIM=$'\033[2m'
    UI_C_RED=$'\033[31m'
    UI_C_GREEN=$'\033[32m'
    UI_C_YELLOW=$'\033[33m'
    UI_C_BLUE=$'\033[34m'
    UI_C_CYAN=$'\033[36m'
else
    UI_C_RESET=''
    UI_C_BOLD=''
    UI_C_DIM=''
    UI_C_RED=''
    UI_C_GREEN=''
    UI_C_YELLOW=''
    UI_C_BLUE=''
    UI_C_CYAN=''
fi

ui_plain_header() {
    local title=$1
    printf '\n%s+%s+%s\n' "$UI_C_BLUE" "$(printf '%*s' 74 '' | tr ' ' '-')" "$UI_C_RESET" >&4
    printf '%s| %s%-72s%s |%s\n' "$UI_C_BLUE" "$UI_C_BOLD" "$title" "$UI_C_RESET$UI_C_BLUE" "$UI_C_RESET" >&4
    printf '%s+%s+%s\n' "$UI_C_BLUE" "$(printf '%*s' 74 '' | tr ' ' '-')" "$UI_C_RESET" >&4
}

ui_plain_confirm() {
    local prompt=$1
    local default=${2:-no}
    local hint='[y/N]'
    [[ $default == yes ]] && hint='[Y/n]'
    printf '%s %s%s%s ' "$prompt" "$UI_C_YELLOW" "$hint" "$UI_C_RESET" >&4
    local answer=
    if ! IFS= read -r answer; then
        return 1
    fi
    case ${answer,,} in
        y|yes|д|да) return 0 ;;
        n|no|н|нет) return 1 ;;
        '') [[ $default == yes ]] ;;
        *) return 1 ;;
    esac
}

ui_init() {
    UI_MODE=plain
    if [[ $AS_PLAIN == 1 ]]; then
        return 0
    fi

    # Prefer the modern TUI: it needs no extra packages beyond python3 and its
    # standard curses module, both present on the official Arch ISO.
    if [[ -t 0 && -t 4 ]] && command -v python3 >/dev/null 2>&1 &&
        python3 -c 'import curses' >/dev/null 2>&1; then
        UI_MODE=tui
        core_silence_console
        return 0
    fi

    if command -v dialog >/dev/null 2>&1 && [[ -t 0 && -t 4 ]]; then
        UI_MODE=dialog
        core_silence_console
        return 0
    fi

    if command -v dialog >/dev/null 2>&1; then
        # A dialog binary without a usable terminal is not useful.
        UI_MODE=plain
        return 0
    fi

    if [[ -t 0 && -t 4 ]] && command -v pacman >/dev/null 2>&1; then
        if ui_plain_confirm "dialog не установлен. Установить его для полноэкранного интерфейса?" yes; then
            if pacman -S --needed --noconfirm dialog >&4 2>&4; then
                UI_MODE=dialog
                core_silence_console
                return 0
            fi
            warn "Не удалось установить dialog; используется текстовый интерфейс."
        fi
    fi
    UI_MODE=plain
}

ui_is_tui() {
    [[ $UI_MODE == tui ]]
}

ui_is_dialog() {
    [[ $UI_MODE == dialog ]]
}

ui_is_fullscreen() {
    ui_is_tui || ui_is_dialog
}

ui_tui() {
    local rc=0
    python3 "$AS_UI_DIR/tui.py" "$@" 3>&1 1>&4 2>>"${LOG_FILE:-/dev/null}" || rc=$?
    return "$rc"
}

ui_steps_init() {
    UI_STEPS=(
        "Сеть"
        "Железо"
        "Профиль"
        "Ядро"
        "Файлы"
        "Диск"
        "Система"
        "Шифрование"
        "Пакеты"
        "Итог"
        "Установка"
    )
    UI_STEP_INDEX=-1
    AS_UI_STEPS=$(IFS='|'; printf '%s' "${UI_STEPS[*]}")
    AS_UI_STEP_INDEX=$UI_STEP_INDEX
    AS_UI_VERSION=${VERSION:-0.11.0}
    export AS_UI_STEPS AS_UI_STEP_INDEX AS_UI_VERSION
}

ui_step_set() {
    UI_STEP_INDEX=${1:--1}
    AS_UI_STEP_INDEX=$UI_STEP_INDEX
    export AS_UI_STEP_INDEX
}

ui_splash() {
    local choice
    if ui_is_tui; then
        choice=$(ui_tui splash --app-version "$AS_UI_VERSION" \
            --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --item "install|Начать установку|Настроить и установить Arch Linux" \
            --item "exit|Выход|Закрыть установщик") || return 1
        printf '%s' "$choice"
        return 0
    fi
    if ui_is_dialog; then
        choice=$(dialog --stdout --clear --backtitle "$UI_BACKTITLE" \
            --title "ArchinstallSuper $AS_UI_VERSION" \
            --menu "Архитектура: UEFI x86_64\nУстановщик не использует archinstall.\n\nВыберите действие:" \
            18 76 2 \
            "install" "Начать установку" \
            "exit" "Выход" 2>&4) || return 1
        printf '%s' "$choice"
        return 0
    fi
    ui_plain_header "ArchinstallSuper $AS_UI_VERSION"
    printf '  UEFI x86_64 · установщик без archinstall\n\n' >&4
    printf '  1) Начать установку\n  2) Выход\n\nВыбор [1]: ' >&4
    local answer=
    IFS= read -r answer || return 1
    case ${answer:-1} in
        1|i|install) printf 'install' ;;
        2|q|exit) printf 'exit' ;;
        *) printf 'exit' ;;
    esac
}

# ui_menu TITLE PROMPT TAG DESCRIPTION [TAG DESCRIPTION ...]
# Prints the selected tag on stdout. Returns 1 when the user cancels.
ui_menu() {
    local title=$1
    local prompt=$2
    shift 2
    (($# % 2 == 0)) || die "ui_menu: нечётное число аргументов."
    (($# > 0)) || die "ui_menu: пустое меню."

    local -a tags=()
    local -a descriptions=()
    local -a pairs=()
    while (($#)); do
        tags+=("$1")
        descriptions+=("$2")
        pairs+=("$1" "$2")
        shift 2
    done

    if ui_is_tui; then
        local -a args=(menu --title "$title" --prompt "$prompt"
            --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX"
            --app-version "$AS_UI_VERSION")
        local index
        for index in "${!tags[@]}"; do
            args+=(--item "${tags[$index]}|${descriptions[$index]}")
        done
        local value
        value=$(ui_tui "${args[@]}") || return 1
        printf '%s' "$value"
        return 0
    fi

    if ui_is_dialog; then
        local choice
        if choice=$(dialog --stdout --clear --backtitle "$UI_BACKTITLE" \
            --title "$title" --menu "$prompt" "$UI_HEIGHT" "$UI_WIDTH" \
            "$UI_LIST_HEIGHT" "${pairs[@]}" 2>&4); then
            printf '%s' "$choice"
            return 0
        fi
        return 1
    fi

    local answer index
    while true; do
        ui_plain_header "$title"
        printf '%s\n\n' "$prompt" >&4
        for index in "${!tags[@]}"; do
            printf '  %2d) %-14s %s\n' "$((index + 1))" "${tags[$index]}" "${descriptions[$index]}" >&4
        done
        printf '\nВведите номер (q — отмена): ' >&4
        if ! IFS= read -r answer; then
            return 1
        fi
        case ${answer,,} in
            q|quit|exit|'') return 1 ;;
        esac
        if [[ $answer =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= ${#tags[@]})); then
            printf '%s' "${tags[$((answer - 1))]}"
            return 0
        fi
        printf '%sНеверный выбор.%s\n' "$UI_C_RED" "$UI_C_RESET" >&4
    done
}

ui_input() {
    local title=$1
    local prompt=$2
    local initial=${3-}
    if ui_is_tui; then
        local value
        value=$(ui_tui input --title "$title" --prompt "$prompt" --initial "$initial" \
            --label "$title" --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --app-version "$AS_UI_VERSION") || return 1
        printf '%s' "$value"
        return 0
    fi
    if ui_is_dialog; then
        local value
        if value=$(dialog --stdout --clear --backtitle "$UI_BACKTITLE" \
            --title "$title" --inputbox "$prompt" 10 72 "$initial" 2>&4); then
            printf '%s' "$value"
            return 0
        fi
        return 1
    fi
    ui_plain_header "$title"
    printf '%s%s%s' "$UI_C_DIM" "$prompt" "$UI_C_RESET" >&4
    [[ -n $initial ]] && printf ' [%s]' "$initial" >&4
    printf ': ' >&4
    local value=
    if ! IFS= read -r value; then
        return 1
    fi
    printf '%s' "${value:-$initial}"
}

ui_password() {
    local title=$1
    local prompt=$2
    if ui_is_tui; then
        local value
        value=$(ui_tui password --title "$title" --prompt "$prompt" \
            --label "Пароль" --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --app-version "$AS_UI_VERSION") || return 1
        printf '%s' "$value"
        return 0
    fi
    if ui_is_dialog; then
        local value
        if value=$(dialog --stdout --clear --backtitle "$UI_BACKTITLE" \
            --title "$title" --passwordbox "$prompt" 10 72 2>&4); then
            printf '%s' "$value"
            return 0
        fi
        return 1
    fi
    ui_plain_header "$title"
    printf '%s ' "$prompt" >&4
    local value=
    if ! IFS= read -r -s value; then
        return 1
    fi
    printf '\n' >&4
    printf '%s' "$value"
}

ui_confirm() {
    local prompt=$1
    if ui_is_tui; then
        ui_tui confirm --title "Подтверждение" --prompt "$prompt" \
            --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --app-version "$AS_UI_VERSION" || return 1
        return 0
    fi
    if ui_is_dialog; then
        if dialog --clear --backtitle "$UI_BACKTITLE" --title "Подтверждение" \
            --yesno "$prompt" 12 76 2>&4; then
            return 0
        fi
        return 1
    fi
    ui_plain_confirm "$prompt" no
}

ui_msg() {
    local message=$1
    local title=${2:-ArchinstallSuper}
    if ui_is_tui; then
        ui_tui msg --title "$title" --message "$message" \
            --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --app-version "$AS_UI_VERSION" || true
        return 0
    fi
    if ui_is_dialog; then
        dialog --clear --backtitle "$UI_BACKTITLE" --title "$title" \
            --msgbox "$message" 16 76 2>&4 || true
    else
        ui_plain_header "$title"
        printf '%s\n' "$message" >&4
    fi
    return 0
}

ui_error() {
    local message=$1
    local title=${2:-Ошибка}
    if ui_is_tui; then
        ui_tui error --title "$title" --message "$message" --kind error \
            --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --app-version "$AS_UI_VERSION" || true
        return 0
    fi
    if ui_is_dialog; then
        dialog --clear --backtitle "$UI_BACKTITLE" --title "$title" \
            --msgbox "$message" 14 76 2>&4
    else
        ui_plain_header "$title"
        printf '%s%s%s\n' "$UI_C_RED" "$message" "$UI_C_RESET" >&4
    fi
    return 0
}

ui_show_text() {
    local title=$1
    local file=$2
    if [[ ! -f $file ]]; then
        ui_error "Файл для просмотра не найден: $file"
        return 1
    fi
    if ui_is_tui; then
        ui_tui textbox --title "$title" --file "$file" \
            --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
            --app-version "$AS_UI_VERSION" || true
        return 0
    fi
    if ui_is_dialog; then
        dialog --clear --backtitle "$UI_BACKTITLE" --title "$title" \
            --textbox "$file" 24 84 2>&4 || true
    else
        ui_plain_header "$title"
        cat -- "$file" >&4
        printf '\nНажмите Enter для продолжения...' >&4
        IFS= read -r _ || true
    fi
    return 0
}

ui_step() {
    local current=$1
    local total=$2
    local text=$3
    if ui_is_fullscreen; then
        return 0
    fi
    printf '%s[%d/%d]%s %s\n' "$UI_C_CYAN" "$current" "$total" "$UI_C_RESET" "$text" >&4
}

ui_status() {
    if ui_is_fullscreen; then
        return 0
    fi
    printf '%s•%s %s\n' "$UI_C_GREEN" "$UI_C_RESET" "$1" >&4
}

# Run a long command with its output visible in the UI and in the log.
# The command's exit status is preserved thanks to pipefail.
ui_run_logged() {
    local title=$1
    shift
    local rc=0
    set +e
    if ui_is_tui; then
        AS_UI_CHILD=1 "$@" 2>&1 | tee -a "${LOG_FILE:-/dev/null}" |
            python3 "$AS_UI_DIR/tui.py" program --title "$title" \
                --prompt "Выполняется: $*" --fd 5 \
                --steps "$AS_UI_STEPS" --step-index "$AS_UI_STEP_INDEX" \
                --app-version "$AS_UI_VERSION" \
                5<&0 0<&4 3>&1 1>&4 2>>"${LOG_FILE:-/dev/null}"
        rc=${PIPESTATUS[0]}
    elif ui_is_dialog; then
        "$@" 2>&1 | tee -a "$LOG_FILE" |
            dialog --clear --backtitle "$UI_BACKTITLE" --title "$title" \
                --programbox "Выполняется: $*" 22 84 2>&4
        rc=${PIPESTATUS[0]}
    else
        ui_plain_header "$title"
        printf 'Выполняется: %s\n\n' "$*" >&4
        # stdout already goes through the run log; do not tee a second time.
        "$@" 2>&1
        rc=$?
    fi
    set -e
    return "$rc"
}

ui_confirm_word() {
    local title=$1
    local prompt=$2
    local expected=$3
    local answer
    answer=$(ui_input "$title" "$prompt") || return 1
    [[ $answer == "$expected" ]]
}
