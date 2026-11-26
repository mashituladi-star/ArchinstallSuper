#!/usr/bin/env bash
# shellcheck shell=bash
# Configuration manager for the installed system.
#
# Functions that generate file contents are pure so they can be unit-tested.
# Functions that touch $TARGET are only called after pacstrap completed.

[[ -n ${AS_CONFIG_LOADED:-} ]] && return 0
AS_CONFIG_LOADED=1

: "${HOSTNAME:=archlinux}"
: "${USERNAME:=}"
: "${TIMEZONE:=Europe/Prague}"
: "${LOCALE:=en_US.UTF-8}"
: "${KEYMAP:=us}"
: "${ROOT_POLICY:=password}"
: "${ZRAM:=0}"
: "${DESKTOP:=}"

config_hosts_content() {
    local host=${1:-$HOSTNAME}
    printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$host" "$host"
}

config_locale_conf_content() {
    printf 'LANG=%s\n' "${1:-$LOCALE}"
}

config_vconsole_content() {
    printf 'KEYMAP=%s\n' "${1:-$KEYMAP}"
}

config_zram_content() {
    printf '[zram0]\nzram-size = min(ram / 2, 4096)\ncompression-algorithm = zstd\n'
}

config_sudoers_content() {
    printf '%%wheel ALL=(ALL:ALL) ALL\n'
}

config_desktop_service() {
    case ${1:-} in
        gnome) printf 'gdm' ;;
        kde) printf 'sddm' ;;
        xfce|cinnamon) printf 'lightdm' ;;
        *) printf '' ;;
    esac
}

config_write_hostname() {
    validate_hostname "$HOSTNAME" || die "$VALIDATION_MESSAGE"
    printf '%s\n' "$HOSTNAME" >"$TARGET/etc/hostname" || die "Could not write hostname."
    config_hosts_content "$HOSTNAME" >"$TARGET/etc/hosts" || die "Could not write /etc/hosts."
}

config_write_locale() {
    validate_locale "$LOCALE" || die "$VALIDATION_MESSAGE"
    config_locale_conf_content "$LOCALE" >"$TARGET/etc/locale.conf" || die "Could not write locale.conf."
    config_vconsole_content "$KEYMAP" >"$TARGET/etc/vconsole.conf" || die "Could not write vconsole.conf."

    local escaped=${LOCALE//./\\.}
    sed -i "s/^#\\(${escaped}[[:space:]]\\)/\\1/" "$TARGET/etc/locale.gen" ||
        die "Could not update /etc/locale.gen."
    grep -q "^${escaped}[[:space:]]" "$TARGET/etc/locale.gen" ||
        printf '%s UTF-8\n' "$LOCALE" >>"$TARGET/etc/locale.gen"
    arch-chroot "$TARGET" locale-gen || die "locale-gen failed."
}

config_set_timezone() {
    validate_timezone "$TIMEZONE" || die "$VALIDATION_MESSAGE"
    arch-chroot "$TARGET" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime ||
        die "Could not set the timezone."
    arch-chroot "$TARGET" hwclock --systohc >/dev/null 2>&1 ||
        warn "hwclock --systohc failed (the VM may have no RTC)."
}

config_create_user() {
    validate_username "$USERNAME" || die "$VALIDATION_MESSAGE"
    if arch-chroot "$TARGET" id "$USERNAME" >/dev/null 2>&1; then
        die "User $USERNAME already exists."
    fi
    arch-chroot "$TARGET" useradd -m -G wheel -s /bin/bash "$USERNAME" ||
        die "Could not create user $USERNAME."
}

config_set_passwords() {
    case $ROOT_POLICY in
        password)
            security_set_root_password "$ROOT_PASSWORD"
            ;;
        locked)
            security_lock_root
            ;;
        *)
            die "Unknown root policy: $ROOT_POLICY"
            ;;
    esac
    security_set_user_password "$USERNAME" "$USER_PASSWORD"
    security_forget_passwords
}

config_write_sudoers() {
    local file="$TARGET/etc/sudoers.d/10-wheel"
    mkdir -p "$TARGET/etc/sudoers.d" || die "Could not create /etc/sudoers.d."
    config_sudoers_content >"$file" || die "Could not write sudoers."
    chmod 440 "$file" || die "Could not set sudoers permissions."
    arch-chroot "$TARGET" visudo -cf /etc/sudoers || die "visudo found an error in sudoers."
}

config_enable_unit() {
    local unit=$1
    arch-chroot "$TARGET" systemctl enable "$unit" >/dev/null 2>&1 ||
        die "Could not enable service $unit."
}

# Optional units must not abort an otherwise healthy installation. This is
# used for timers/services that depend on the exact package set.
config_enable_unit_optional() {
    local unit=$1
    if ! arch-chroot "$TARGET" systemctl enable "$unit" >/dev/null 2>&1; then
        warn "Service $unit is unavailable; skipping it."
    fi
}

config_configure_services() {
    config_enable_unit NetworkManager
    # Avoid running two time-sync daemons if the user added chrony/ntp.
    if ! core_array_contains chrony "${PACKAGES[@]:-}" &&
        ! core_array_contains ntp "${PACKAGES[@]:-}"; then
        config_enable_unit_optional systemd-timesyncd
    fi
    config_enable_unit_optional fstrim.timer
    local display_manager
    display_manager=$(config_desktop_service "$DESKTOP")
    if [[ -n $display_manager ]]; then
        config_enable_unit "$display_manager"
    fi
}

config_configure_zram() {
    if ((ZRAM)); then
        mkdir -p "$TARGET/etc/systemd"
        config_zram_content >"$TARGET/etc/systemd/zram-generator.conf" ||
            die "Could not write zram-generator.conf."
    fi
}

config_apply_all() {
    # shellcheck disable=SC2034  # read by the EXIT trap in recovery.sh
    INSTALL_PHASE="configuration"
    info "Configuring the installed system."
    config_write_hostname
    config_write_locale
    config_set_timezone
    config_create_user
    config_set_passwords
    config_write_sudoers
    config_configure_services
    config_configure_zram
}
