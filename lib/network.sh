#!/usr/bin/env bash
# shellcheck shell=bash
# Network manager for the live environment.
#
# The installed system is configured separately (NetworkManager). Here we only
# ensure that the live ISO has working connectivity before packages are fetched.

[[ -n ${AS_NETWORK_LOADED:-} ]] && return 0
AS_NETWORK_LOADED=1

network_online() {
    curl -fsSI --connect-timeout 5 --max-time 12 https://archlinux.org/ >/dev/null 2>&1
}

network_dns_ok() {
    getent hosts archlinux.org >/dev/null 2>&1
}

network_interfaces() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v '^lo$' || true
}

network_wifi_devices() {
    if command -v iw >/dev/null 2>&1; then
        iw dev 2>/dev/null | awk '$1 == "Interface" {print $2}' || true
        return 0
    fi
    network_interfaces | grep -E '^wl' || true
}

network_status_text() {
    cat <<EOF
Интернет:      $(if network_online; then echo доступен; else echo недоступен; fi)
DNS:           $(if network_dns_ok; then echo работает; else echo не работает; fi)

Интерфейсы:
$(network_interfaces | sed 's/^/  - /')

Wi-Fi:
$(network_wifi_devices | sed 's/^/  - /')

Маршрут по умолчанию:
$(ip route show default 2>/dev/null || echo '  нет')

DNS-серверы:
$(awk '/^nameserver/ {print "  " $0}' /etc/resolv.conf 2>/dev/null || echo '  нет')
EOF
}

network_show_status() {
    local file="$TEMP_DIR/network-status.txt"
    network_status_text >"$file"
    ui_show_text "Сеть" "$file"
}

network_scan_wifi() {
    local device=$1
    local file="$TEMP_DIR/wifi-networks.txt"
    command -v iwctl >/dev/null 2>&1 || {
        ui_error "iwctl не найден. Подключи Wi-Fi вручную и повтори проверку."
        return 1
    }
    info "Сканирую Wi-Fi на $device."
    iwctl station "$device" scan >/dev/null 2>&1 || true
    sleep 2
    {
        printf 'Устройство: %s\n\n' "$device"
        iwctl station "$device" get-networks 2>&1 || true
    } >"$file"
    ui_show_text "Доступные Wi-Fi сети" "$file"
}

network_connect_wifi() {
    local -a devices=()
    local device
    while IFS= read -r device; do
        [[ -n $device ]] && devices+=("$device")
    done < <(network_wifi_devices)
    ((${#devices[@]} > 0)) || {
        ui_error "Wi-Fi-адаптер не найден."
        return 1
    }

    if ((${#devices[@]} == 1)); then
        device=${devices[0]}
    else
        local -a menu=()
        for device in "${devices[@]}"; do
            menu+=("$device" "Wi-Fi интерфейс")
        done
        device=$(ui_menu "Wi-Fi" "Выбери интерфейс." "${menu[@]}") || return 1
    fi

    network_scan_wifi "$device" || true
    local ssid
    ssid=$(ui_input "Wi-Fi" "Имя сети (SSID):") || return 1
    [[ -n $ssid ]] || return 1
    local password=
    password=$(ui_password "Wi-Fi" "Пароль сети (оставь пустым для открытой сети):") || return 1

    command -v iwctl >/dev/null 2>&1 || {
        ui_error "iwctl не найден."
        return 1
    }
    info "Подключаюсь к Wi-Fi $ssid."
    # iwctl reads the passphrase from stdin; it is not exposed in argv.
    if ! printf '%s\n' "$password" | iwctl station "$device" connect "$ssid" >/dev/null 2>&1; then
        unset password
        ui_error "Не удалось подключиться к $ssid. Проверь имя сети и пароль."
        return 1
    fi
    unset password
    sleep 3
    if network_online; then
        return 0
    fi
    ui_error "Подключение установлено, но интернет недоступен. Проверь DHCP/DNS."
    return 1
}

network_wait() {
    local attempts=${1:-3}
    local attempt
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if network_online; then
            timedatectl set-ntp true >/dev/null 2>&1 || true
            return 0
        fi
        ((attempt < attempts)) && sleep 2
    done
    return 1
}

network_ensure() {
    if network_wait 2; then
        info "Интернет доступен."
        return 0
    fi

    warn "Интернет недоступен."
    local choice
    while true; do
        choice=$(ui_menu "Нет интернета" \
            "Для установки нужны пакеты из репозиториев Arch. Подключи сеть." \
            "retry" "Повторить проверку" \
            "wifi" "Подключить Wi-Fi" \
            "status" "Показать состояние сети" \
            "abort" "Прервать установку") || die "Отменено пользователем."
        case $choice in
            retry)
                network_wait 3 && { info "Интернет доступен."; return 0; }
                ui_error "Интернет всё ещё недоступен."
                ;;
            wifi)
                network_connect_wifi || true
                ;;
            status)
                network_show_status
                ;;
            abort)
                die "Установка прервана: нет доступа в интернет."
                ;;
        esac
    done
}

network_check() {
    local failed=0
    if network_online; then
        info "Интернет: доступен."
    else
        error "Интернет: недоступен."
        failed=1
    fi
    if network_dns_ok; then
        info "DNS: работает."
    else
        error "DNS: не работает."
        failed=1
    fi
    return "$failed"
}
