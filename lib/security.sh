#!/usr/bin/env bash
# shellcheck shell=bash
# Security manager: password policy and optional LUKS2 root encryption.
#
# Passwords are never passed as command-line arguments. cryptsetup reads the
# passphrase from stdin through --key-file -, and chpasswd receives it through
# a pipe. The values are unset as soon as they are no longer needed.

[[ -n ${AS_SECURITY_LOADED:-} ]] && return 0
AS_SECURITY_LOADED=1

: "${LUKS_NAME:=cryptroot}"
: "${LUKS_PASSWORD:=}"
: "${LUKS_UUID:=}"
: "${LUKS_OPENED:=0}"

security_password_problem() {
    local password=${1:-}
    local username=${2:-}
    local hostname=${3:-}
    validate_password "$password" "$username" "$hostname" || {
        printf '%s' "$VALIDATION_MESSAGE"
        return 0
    }
    return 1
}

security_validate_password() {
    local password=${1:-}
    local username=${2:-}
    local hostname=${3:-}
    local problem
    if problem=$(security_password_problem "$password" "$username" "$hostname"); then
        die "Password: $problem"
    fi
}

security_luks_available() {
    command -v cryptsetup >/dev/null 2>&1
}

security_luks_is_luks() {
    local device=$1
    cryptsetup isLuks "$device" >/dev/null 2>&1
}

security_luks_create() {
    local device=$1
    security_luks_available || die "cryptsetup is not installed in the live environment."
    [[ -n ${LUKS_PASSWORD:-} ]] || die "Encryption password is not set."
    security_validate_password "$LUKS_PASSWORD" "$USERNAME" "$HOSTNAME"

    info "Creating a LUKS2 container on $device."
    # The passphrase is supplied through stdin; it never appears in argv or log.
    if ! printf '%s' "$LUKS_PASSWORD" | cryptsetup luksFormat \
        --batch-mode --type luks2 --cipher aes-xts-plain64 --key-size 512 \
        --hash sha256 --pbkdf argon2id --key-file - "$device"; then
        die "Could not create the LUKS2 container."
    fi
    if ! printf '%s' "$LUKS_PASSWORD" | cryptsetup open --key-file - "$device" "$LUKS_NAME"; then
        die "Could not open the LUKS2 container."
    fi
    LUKS_OPENED=1
    LUKS_UUID=$(cryptsetup luksUUID "$device" 2>/dev/null || blkid -s UUID -o value "$device" || true)
    [[ -n $LUKS_UUID ]] || die "Could not determine the LUKS container UUID."
    unset LUKS_PASSWORD
    [[ -b /dev/mapper/$LUKS_NAME ]] || die "Device /dev/mapper/$LUKS_NAME did not appear."
}

security_luks_close() {
    if [[ ${LUKS_OPENED:-0} == 1 ]] && [[ -e /dev/mapper/$LUKS_NAME ]]; then
        cryptsetup close "$LUKS_NAME" || warn "Could not close the LUKS container $LUKS_NAME."
    fi
    LUKS_OPENED=0
}

security_luks_boot_args() {
    local luks_uuid=${1:-${LUKS_UUID:-}}
    local name=${2:-$LUKS_NAME}
    [[ -n $luks_uuid ]] || die "The LUKS container UUID is unknown."
    printf 'cryptdevice=UUID=%s:%s root=/dev/mapper/%s rw' "$luks_uuid" "$name" "$name"
}

security_luks_validate() {
    [[ ${ENCRYPT:-0} == 1 ]] || return 0
    security_luks_available || die "cryptsetup is required for encryption."
    [[ -n ${LUKS_UUID:-} ]] || die "The LUKS container UUID is not set."
    [[ -e /dev/mapper/$LUKS_NAME ]] || die "The LUKS container is not open."
    local hooks
    hooks=$(grep '^HOOKS=' "$TARGET/etc/mkinitcpio.conf" 2>/dev/null || true)
    [[ $hooks == *encrypt* ]] || die "The encrypt hook is missing from mkinitcpio.conf."
    grep -q 'cryptdevice=' "$TARGET/boot/loader/entries/archinstall-super.conf" 2>/dev/null ||
        die "cryptdevice is missing from the boot entry."
}

security_lock_root() {
    info "Locking the root account; administration is done through sudo."
    arch-chroot "$TARGET" passwd -l root >/dev/null 2>&1 ||
        die "Could not lock the root account."
}

security_set_root_password() {
    local password=$1
    [[ -n $password ]] || die "The root password is empty."
    if ! printf 'root:%s\n' "$password" | arch-chroot "$TARGET" chpasswd; then
        die "Could not set the root password."
    fi
}

security_set_user_password() {
    local username=$1
    local password=$2
    [[ -n $password ]] || die "The user password is empty."
    if ! printf '%s:%s\n' "$username" "$password" | arch-chroot "$TARGET" chpasswd; then
        die "Could not set the user password."
    fi
}

security_forget_passwords() {
    unset ROOT_PASSWORD USER_PASSWORD LUKS_PASSWORD 2>/dev/null || true
}
