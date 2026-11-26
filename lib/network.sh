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
Internet:      $(if network_online; then echo available; else echo unavailable; fi)
DNS:           $(if network_dns_ok; then echo working; else echo not working; fi)

Interfaces:
$(network_interfaces | sed 's/^/  - /')

Wi-Fi:
$(network_wifi_devices | sed 's/^/  - /')

Default route:
$(ip route show default 2>/dev/null || echo '  none')

DNS servers:
$(awk '/^nameserver/ {print "  " $0}' /etc/resolv.conf 2>/dev/null || echo '  none')
EOF
}

network_show_status() {
    local file="$TEMP_DIR/network-status.txt"
    network_status_text >"$file"
    ui_show_text "Network" "$file"
}

network_scan_wifi() {
    local device=$1
    local file="$TEMP_DIR/wifi-networks.txt"
    command -v iwctl >/dev/null 2>&1 || {
        ui_error "iwctl not found. Connect Wi-Fi manually and retry."
        return 1
    }
    info "Scanning Wi-Fi on $device."
    iwctl station "$device" scan >/dev/null 2>&1 || true
    sleep 2
    {
        printf 'Device: %s\n\n' "$device"
        iwctl station "$device" get-networks 2>&1 || true
    } >"$file"
    ui_show_text "Available Wi-Fi networks" "$file"
}

network_connect_wifi() {
    local -a devices=()
    local device
    while IFS= read -r device; do
        [[ -n $device ]] && devices+=("$device")
    done < <(network_wifi_devices)
    ((${#devices[@]} > 0)) || {
        ui_error "No Wi-Fi adapter found."
        return 1
    }

    if ((${#devices[@]} == 1)); then
        device=${devices[0]}
    else
        local -a menu=()
        for device in "${devices[@]}"; do
            menu+=("$device" "Wi-Fi interface")
        done
        device=$(ui_menu "Wi-Fi" "Choose an interface." "${menu[@]}") || return 1
    fi

    network_scan_wifi "$device" || true
    local ssid
    ssid=$(ui_input "Wi-Fi" "Network name (SSID):") || return 1
    [[ -n $ssid ]] || return 1
    local password=
    password=$(ui_password "Wi-Fi" "Network password (leave empty for an open network):") || return 1

    command -v iwctl >/dev/null 2>&1 || {
        ui_error "iwctl not found."
        return 1
    }
    info "Connecting to Wi-Fi $ssid."
    # iwctl reads the passphrase from stdin; it is not exposed in argv.
    if ! printf '%s\n' "$password" | iwctl station "$device" connect "$ssid" >/dev/null 2>&1; then
        unset password
        ui_error "Could not connect to $ssid. Check the network name and password."
        return 1
    fi
    unset password
    sleep 3
    if network_online; then
        return 0
    fi
    ui_error "Connected, but the internet is unreachable. Check DHCP/DNS."
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
        info "Internet is available."
        return 0
    fi

    warn "Internet is unavailable."
    local choice
    while true; do
        choice=$(ui_menu "No internet" \
            "Installation needs packages from the Arch repositories. Connect to a network." \
            "retry" "Retry the check" \
            "wifi" "Connect Wi-Fi" \
            "status" "Show network status" \
            "abort" "Abort installation") || die "Cancelled by the user."
        case $choice in
            retry)
                network_wait 3 && { info "Internet is available."; return 0; }
                ui_error "The internet is still unavailable."
                ;;
            wifi)
                network_connect_wifi || true
                ;;
            status)
                network_show_status
                ;;
            abort)
                die "Installation aborted: no internet access."
                ;;
        esac
    done
}

network_check() {
    local failed=0
    if network_online; then
        info "Internet: available."
    else
        error "Internet: unavailable."
        failed=1
    fi
    if network_dns_ok; then
        info "DNS: working."
    else
        error "DNS: not working."
        failed=1
    fi
    return "$failed"
}

# Non-interactive network setup for unattended mode. Uses CONFIG_WIFI_SSID and
# CONFIG_WIFI_PASSWORD from the configuration file if the initial check fails.
network_ensure_auto() {
    local attempt
    for ((attempt = 1; attempt <= 5; attempt++)); do
        if network_online; then
            timedatectl set-ntp true >/dev/null 2>&1 || true
            info "Internet is available."
            return 0
        fi
        if [[ -n ${CONFIG_WIFI_SSID:-} ]]; then
            info "Configuring Wi-Fi: ${CONFIG_WIFI_SSID}."
            if network_connect_wifi_auto; then
                if network_online; then
                    timedatectl set-ntp true >/dev/null 2>&1 || true
                    info "Internet is available."
                    return 0
                fi
            fi
        fi
        ((attempt < 5)) && sleep 3
    done
    die "Unattended installation: no internet access and Wi-Fi could not be configured."
}

# Connect to Wi-Fi without UI prompts. Reads credentials from configuration.
network_connect_wifi_auto() {
    local -a devices=()
    local device
    while IFS= read -r device; do
        [[ -n $device ]] && devices+=("$device")
    done < <(network_wifi_devices)
    ((${#devices[@]} > 0)) || {
        warn "No Wi-Fi adapter found."
        return 1
    }
    device=${devices[0]}

    command -v iwctl >/dev/null 2>&1 || {
        warn "iwctl not found."
        return 1
    }

    info "Scanning Wi-Fi on $device."
    iwctl station "$device" scan >/dev/null 2>&1 || true
    sleep 3

    if ! printf '%s\n' "${CONFIG_WIFI_PASSWORD:-}" | iwctl station "$device" connect "${CONFIG_WIFI_SSID}" >/dev/null 2>&1; then
        warn "Could not connect to ${CONFIG_WIFI_SSID}."
        return 1
    fi
    sleep 5
    return 0
}
