#!/usr/bin/env bash
# shellcheck shell=bash
# Hardware discovery. Read-only: no package installation happens here.

[[ -n ${AS_HARDWARE_LOADED:-} ]] && return 0
AS_HARDWARE_LOADED=1

: "${HW_CPU_VENDOR:=}"
: "${HW_CPU_MODEL:=}"
: "${HW_CPU_CORES:=}"
: "${HW_MEMORY_MIB:=0}"
: "${HW_BOARD_VENDOR:=}"
: "${HW_BOARD_NAME:=}"
: "${HW_FIRMWARE:=}"
: "${HW_GPUS:=}"
: "${HW_NETWORK:=}"
: "${HW_SECURE_BOOT:=unknown}"

hw_read_first_line() {
    local file=$1
    [[ -r $file ]] || return 1
    head -n 1 -- "$file" 2>/dev/null | tr -d '\r\n'
}

hw_detect_cpu() {
    HW_CPU_VENDOR=$(awk -F': ' '/^vendor_id[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    if command -v lscpu >/dev/null 2>&1; then
        HW_CPU_MODEL=$(lscpu 2>/dev/null | awk -F': +' '/^Model name:/ {print $2; exit}')
        HW_CPU_CORES=$(lscpu 2>/dev/null | awk -F': +' '/^CPU\(s\):/ {print $2; exit}')
    fi
    if [[ -z $HW_CPU_MODEL ]]; then
        HW_CPU_MODEL=$(awk -F': ' '/^model name[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
    fi
    if [[ -z $HW_CPU_CORES ]]; then
        HW_CPU_CORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || true)
    fi
}

hw_detect_memory() {
    local mem_kib
    mem_kib=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
    core_is_uint "$mem_kib" || mem_kib=0
    HW_MEMORY_MIB=$((mem_kib / 1024))
}

hw_detect_board() {
    HW_BOARD_VENDOR=$(hw_read_first_line /sys/class/dmi/id/sys_vendor || true)
    HW_BOARD_NAME=$(hw_read_first_line /sys/class/dmi/id/product_name || true)
    local board
    board=$(hw_read_first_line /sys/class/dmi/id/board_name || true)
    if [[ -n $board && $board != "$HW_BOARD_NAME" ]]; then
        HW_BOARD_NAME+=" / $board"
    fi
}

hw_detect_firmware() {
    if core_is_uefi; then
        HW_FIRMWARE="UEFI"
        local bios_version bios_date
        bios_version=$(hw_read_first_line /sys/class/dmi/id/bios_version || true)
        bios_date=$(hw_read_first_line /sys/class/dmi/id/bios_date || true)
        [[ -n $bios_version ]] && HW_FIRMWARE+=" ($bios_version"
        [[ -n $bios_date ]] && HW_FIRMWARE+=", $bios_date"
        [[ $HW_FIRMWARE == *'('* ]] && HW_FIRMWARE+=')'
    else
        HW_FIRMWARE="Legacy BIOS (не поддерживается)"
    fi
}

hw_detect_gpus() {
    if command -v lspci >/dev/null 2>&1; then
        HW_GPUS=$(lspci -nn 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
    fi
    if [[ -z $HW_GPUS ]]; then
        HW_GPUS="Не удалось определить (lspci недоступен или GPU не найден)"
    fi
}

hw_detect_network() {
    if command -v ip >/dev/null 2>&1; then
        HW_NETWORK=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' | paste -sd ', ' - || true)
    fi
    [[ -n $HW_NETWORK ]] || HW_NETWORK="Не обнаружены сетевые интерфейсы"
    if command -v iw >/dev/null 2>&1; then
        local wifi
        wifi=$(iw dev 2>/dev/null | awk '$1 == "Interface" {print $2}' | paste -sd ', ' - || true)
        [[ -n $wifi ]] && HW_NETWORK+=" (Wi-Fi: $wifi)"
    fi
}

hw_detect_secure_boot() {
    if command -v mokutil >/dev/null 2>&1; then
        HW_SECURE_BOOT=$(mokutil --sb-state 2>/dev/null | head -n 1 || true)
        [[ -n $HW_SECURE_BOOT ]] && return 0
    fi
    local efivar
    efivar=$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n 1 || true)
    if [[ -n $efivar && -r $efivar ]]; then
        local value
        value=$(od -An -t u1 -j 4 -N 1 -- "$efivar" 2>/dev/null | tr -d ' \n' || true)
        case $value in
            1) HW_SECURE_BOOT="включён" ;;
            0) HW_SECURE_BOOT="выключен" ;;
            *) HW_SECURE_BOOT="неизвестно" ;;
        esac
    fi
}

hw_detect() {
    hw_detect_cpu
    hw_detect_memory
    hw_detect_board
    hw_detect_firmware
    hw_detect_gpus
    hw_detect_network
    hw_detect_secure_boot
}

hw_microcode_package() {
    case ${HW_CPU_VENDOR:-} in
        GenuineIntel) printf 'intel-ucode' ;;
        AuthenticAMD) printf 'amd-ucode' ;;
        *) printf '' ;;
    esac
}

hw_is_laptop() {
    compgen -G '/sys/class/power_supply/BAT*' >/dev/null 2>&1
}

hw_recommended_ram_mib() {
    local desktop=${1:-0}
    if ((desktop)); then
        printf '4096'
    else
        printf '2048'
    fi
}

hw_check_memory() {
    local desktop=${1:-0}
    local recommended
    recommended=$(hw_recommended_ram_mib "$desktop")
    if ((HW_MEMORY_MIB < recommended)); then
        warn "Обнаружено ${HW_MEMORY_MIB} MiB RAM; рекомендуется минимум ${recommended} MiB."
    fi
}

hw_add_packages() {
    local desktop=${1:-0}
    local ucode
    ucode=$(hw_microcode_package)
    [[ -n $ucode ]] && core_array_append_unique PACKAGES "$ucode"
    if ((desktop)); then
        # Mesa provides the OpenGL/Vulkan userspace stack for Intel and AMD.
        # Proprietary NVIDIA drivers are deliberately not installed automatically.
        core_array_append_unique PACKAGES mesa
    fi
}

hw_report() {
    cat <<EOF
Процессор:      $(core_value_or "$HW_CPU_MODEL") (${HW_CPU_CORES:-?} потоков)
Производитель:  $(core_value_or "$HW_CPU_VENDOR")
Архитектура:    $(uname -m)
Память:         ${HW_MEMORY_MIB} MiB
Материнская плата: $(core_value_or "$HW_BOARD_VENDOR") $(core_value_or "$HW_BOARD_NAME" '')
Прошивка:       $(core_value_or "$HW_FIRMWARE")
Secure Boot:    $(core_value_or "$HW_SECURE_BOOT")
Микрокод:       $(core_value_or "$(hw_microcode_package)" 'не требуется/неизвестен')
Ноутбук:        $(if hw_is_laptop; then echo да; else echo нет; fi)

Видеокарты:
$HW_GPUS

Сеть:
$HW_NETWORK
EOF
}

hw_show_screen() {
    local report="$TEMP_DIR/hardware.txt"
    hw_report >"$report"
    ui_show_text "Оборудование" "$report"
}
