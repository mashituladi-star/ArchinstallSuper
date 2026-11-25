#!/usr/bin/env bash
# shellcheck shell=bash
# Core primitives for ArchinstallSuper: configuration, logging and small helpers.
# This module must not perform destructive operations and must stay sourceable
# from tests without side effects.

[[ -n ${AS_CORE_LOADED:-} ]] && return 0
AS_CORE_LOADED=1

: "${AS_TEST:=0}"
: "${AS_VERSION:=0.10.0}"
: "${VERSION:=$AS_VERSION}"
: "${TARGET:=/mnt}"
: "${LOG_FILE:=/var/log/archinstallsuper.log}"
: "${STATE_DIR:=/run/archinstallsuper}"
: "${LOCK_FILE:=$STATE_DIR/installer.lock}"
: "${TEMP_DIR:=}"
: "${AS_LOG_TO_FILE:=1}"
: "${AS_DEBUG:=0}"
: "${UI_TTY_FD:=4}"
: "${INSTALL_PHASE:=}"
: "${INSTALL_STARTED:=0}"
: "${INSTALL_COMPLETE:=0}"
: "${MOUNTED_BY_US:=0}"
: "${LUKS_OPENED:=0}"

# Print a UTC timestamp suitable for log lines.
core_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

_core_log() {
    local level=$1
    shift
    printf '[%s] [%s] %s\n' "$(core_timestamp)" "$level" "$*"
}

info() { _core_log INFO "$*"; }
warn() { _core_log WARN "$*" >&2; }
error() { _core_log ERROR "$*" >&2; }

die() {
    error "$*"
    exit 1
}

debug() {
    if [[ $AS_DEBUG == 1 ]]; then
        _core_log DEBUG "$*" >&2
    fi
}

# Initialise file descriptors and the run log.
#
# fd 3: original stdout, fd 4: original stderr. The UI writes to fd 4 so that
# dialog output is never mixed with values captured through command
# substitution. All normal output is tee'd to LOG_FILE.
core_init() {
    umask 077
    exec 3>&1 4>&2

    if [[ $AS_LOG_TO_FILE == 1 ]]; then
        local log_dir
        log_dir=$(dirname -- "$LOG_FILE")
        mkdir -p -- "$log_dir" || die "Не удалось создать каталог журнала: $log_dir"
        : >"$LOG_FILE" || die "Не удалось открыть журнал: $LOG_FILE"
        chmod 600 -- "$LOG_FILE" 2>/dev/null || true
        exec > >(tee -a "$LOG_FILE") 2>&1
    fi

    mkdir -p -- "$STATE_DIR" || die "Не удалось создать каталог состояния: $STATE_DIR"
    chmod 700 -- "$STATE_DIR" 2>/dev/null || true

    if [[ -z $TEMP_DIR ]]; then
        TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/archinstallsuper.XXXXXX") ||
            die "Не удалось создать временный каталог."
    fi

    info "ArchinstallSuper $VERSION"
    info "Журнал: $LOG_FILE"
    debug "TARGET=$TARGET STATE_DIR=$STATE_DIR"

    # Sensitive paths above were created under umask 077. Restore the normal
    # umask for the rest of the run so files written into the target system
    # (/etc/fstab, loader entries, ...) get their usual world-readable modes.
    umask 022
}

core_need() {
    command -v "$1" >/dev/null 2>&1 || die "Не найдена обязательная команда: $1"
}

core_need_optional() {
    command -v "$1" >/dev/null 2>&1
}

core_require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Установщик нужно запускать от root."
}

core_is_uefi() {
    [[ -d /sys/firmware/efi ]]
}

core_is_live_arch() {
    [[ -f /etc/arch-release && -d /run/archiso ]]
}

core_is_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

core_trim() {
    local value=${1-}
    value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    printf '%s' "$value"
}

core_validate_package_name() {
    [[ ${1:-} =~ ^[A-Za-z0-9@._+-]+$ ]]
}

core_join_by() {
    local separator=$1
    shift
    local result=
    local first=1
    local item
    for item in "$@"; do
        if ((first)); then
            first=0
        else
            result+=$separator
        fi
        result+=$item
    done
    printf '%s' "$result"
}

# Remove duplicates from an array in place while preserving order.
core_dedupe_array() {
    local -n _core_array=$1
    local -A _core_seen=()
    local -a _core_result=()
    local _core_item
    for _core_item in "${_core_array[@]}"; do
        [[ -n ${_core_seen[$_core_item]:-} ]] && continue
        _core_seen[$_core_item]=1
        _core_result+=("$_core_item")
    done
    _core_array=("${_core_result[@]}")
}

core_human_size() {
    local bytes=${1:-0}
    core_is_uint "$bytes" || bytes=0
    local tenths
    if ((bytes >= 1073741824)); then
        tenths=$(((bytes * 10 + 536870912) / 1073741824))
        printf '%d.%d GiB' $((tenths / 10)) $((tenths % 10))
    elif ((bytes >= 1048576)); then
        tenths=$(((bytes * 10 + 524288) / 1048576))
        printf '%d.%d MiB' $((tenths / 10)) $((tenths % 10))
    elif ((bytes >= 1024)); then
        tenths=$(((bytes * 10 + 512) / 1024))
        printf '%d.%d KiB' $((tenths / 10)) $((tenths % 10))
    else
        printf '%d B' "$bytes"
    fi
}

core_bytes_from_size() {
    # Convert values such as "123.4 MiB" or "1.2 GiB" to bytes.
    local value=${1:-}
    local number unit multiplier
    [[ $value =~ ^([0-9]+([.][0-9]+)?)[[:space:]]*([KMGTP]iB|B)$ ]] || return 1
    number=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[3]}
    case $unit in
        B) multiplier=1 ;;
        KiB) multiplier=1024 ;;
        MiB) multiplier=$((1024 ** 2)) ;;
        GiB) multiplier=$((1024 ** 3)) ;;
        TiB) multiplier=$((1024 ** 4)) ;;
        PiB) multiplier=$((1024 ** 5)) ;;
        *) return 1 ;;
    esac
    # Bash arithmetic is integer-only; round to the nearest byte.
    local integer=${number%%.*}
    local fraction=0
    if [[ $number == *.* ]]; then
        fraction=${number#*.}
        fraction=${fraction:0:6}
        while ((${#fraction} < 6)); do fraction+="0"; done
    fi
    printf '%d' $((integer * multiplier + fraction * multiplier / 1000000))
}

core_sleep() {
    local seconds=${1:-1}
    core_is_uint "$seconds" || seconds=1
    sleep "$seconds"
}

core_retry() {
    local attempts=${1:-3}
    local delay=${2:-2}
    shift 2
    local attempt
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if "$@"; then
            return 0
        fi
        if ((attempt < attempts)); then
            warn "Попытка $attempt/$attempts не удалась; повтор через ${delay}s."
            core_sleep "$delay"
        fi
    done
    return 1
}

core_run() {
    debug "Выполняю: $*"
    "$@"
}

core_chroot() {
    debug "arch-chroot $TARGET $*"
    arch-chroot "$TARGET" "$@"
}

core_array_contains() {
    local needle=$1
    shift
    local item
    for item in "$@"; do
        [[ $item == "$needle" ]] && return 0
    done
    return 1
}

core_array_append_unique() {
    local -n _core_target=$1
    local value=$2
    if ! core_array_contains "$value" "${_core_target[@]}"; then
        _core_target+=("$value")
    fi
}

# Print a value or a fallback. Used by hardware/status reports.
core_value_or() {
    local value=${1-}
    local fallback=${2:-неизвестно}
    if [[ -n $value ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$fallback"
    fi
}
