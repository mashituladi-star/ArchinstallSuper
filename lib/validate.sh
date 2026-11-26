#!/usr/bin/env bash
# shellcheck shell=bash
# Validation engine: environment, user input, packages, disk capacity and
# post-install checks. Validation functions must be side-effect free except
# for reading the system and the package database.

[[ -n ${AS_VALIDATE_LOADED:-} ]] && return 0
AS_VALIDATE_LOADED=1

: "${VALIDATION_MESSAGE:=}"
: "${REQUIRED_BYTES:=0}"

validate_efi() {
    core_is_uefi || die "The system was not booted in UEFI mode. Legacy/CSM is not supported."
    [[ -d /sys/firmware/efi/efivars ]] ||
        die "EFI variables are unavailable: /sys/firmware/efi/efivars is missing."
    if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
        warn "efivarfs is not mounted as a separate filesystem."
    fi
    [[ -w /sys/firmware/efi/efivars ]] ||
        die "EFI variables are read-only. Boot in UEFI mode without NVRAM restrictions."
}

validate_target() {
    [[ -d $TARGET ]] || die "Target directory does not exist: $TARGET"
    if mountpoint -q "$TARGET" 2>/dev/null; then
        die "$TARGET is already mounted. Unmount it and start the installer again."
    fi
    if [[ -n $(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
        die "$TARGET is not empty. This may be a previous installation; clean the directory manually."
    fi
}

validate_base_commands() {
    local command
    for command in lsblk sgdisk wipefs mkfs.fat pacstrap pacman genfstab \
        arch-chroot bootctl blkid partprobe udevadm curl awk grep sed readlink \
        findmnt mountpoint flock sync tee install; do
        core_need "$command"
    done
}

validate_storage_commands() {
    core_need mkfs.ext4
    case ${FS_TYPE:-ext4} in
        ext4) ;;
        btrfs) core_need mkfs.btrfs ;;
        xfs) core_need mkfs.xfs ;;
        *) die "Unsupported filesystem: ${FS_TYPE:-}" ;;
    esac
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        core_need cryptsetup
    fi
}

validate_environment() {
    core_require_root
    core_is_live_arch || die "The official Arch Linux ISO live environment is required."
    [[ $(uname -m) == x86_64 ]] || die "Only x86_64 is supported."
    validate_efi
    validate_target
    validate_base_commands
}

validate_hostname() {
    local hostname=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $hostname =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
        VALIDATION_MESSAGE="Hostname must be 1-63 characters: letters, digits and hyphens, without a trailing hyphen."
        return 1
    fi
    return 0
}

validate_username() {
    local username=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $username =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        VALIDATION_MESSAGE="User name: a lowercase letter or _, then lowercase letters, digits, _ or - (up to 32 characters)."
        return 1
    fi
    if [[ $username == root ]]; then
        VALIDATION_MESSAGE="The root user cannot be created again."
        return 1
    fi
    return 0
}

validate_timezone() {
    local timezone=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $timezone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
        VALIDATION_MESSAGE="Invalid timezone format."
        return 1
    fi
    if [[ ! -f /usr/share/zoneinfo/$timezone ]]; then
        VALIDATION_MESSAGE="Timezone not found: $timezone"
        return 1
    fi
    return 0
}

validate_locale() {
    local locale=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $locale =~ ^[A-Za-z_]+\.UTF-8$ ]]; then
        VALIDATION_MESSAGE="Locale must have the form xx_XX.UTF-8."
        return 1
    fi
    local escaped=${locale//./\\.}
    if ! grep -Eq "^#?${escaped}[[:space:]]+UTF-8[[:space:]]*$" /etc/locale.gen 2>/dev/null; then
        VALIDATION_MESSAGE="Locale $locale is missing from the live /etc/locale.gen."
        return 1
    fi
    return 0
}

validate_keymap() {
    local keymap=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $keymap =~ ^[A-Za-z0-9_-]+$ ]]; then
        VALIDATION_MESSAGE="Invalid keyboard layout name."
        return 1
    fi
    if ! find /usr/share/kbd/keymaps -type f -name "${keymap}.map*" -print -quit 2>/dev/null | grep -q .; then
        VALIDATION_MESSAGE="Keyboard layout $keymap was not found in the live environment."
        return 1
    fi
    return 0
}

validate_password() {
    local password=${1:-}
    local username=${2:-}
    local hostname=${3:-}
    VALIDATION_MESSAGE=
    if ((${#password} < 8)); then
        VALIDATION_MESSAGE="Password must contain at least 8 characters."
        return 1
    fi
    if [[ $password == *:* ]]; then
        VALIDATION_MESSAGE="Password must not contain a colon (chpasswd limitation)."
        return 1
    fi
    if [[ $password == *$'\n'* || $password == *$'\r'* ]]; then
        VALIDATION_MESSAGE="Password must not contain newlines."
        return 1
    fi
    if [[ -n $username && $password == "$username" ]]; then
        VALIDATION_MESSAGE="Password must not match the user name."
        return 1
    fi
    if [[ -n $hostname && $password == "$hostname" ]]; then
        VALIDATION_MESSAGE="Password must not match the hostname."
        return 1
    fi
    case ${password,,} in
        password|password123|12345678|123456789|qwerty123|archlinux)
            VALIDATION_MESSAGE="This password is too common."
            return 1
            ;;
    esac
    return 0
}

validate_package_name() {
    local package=${1:-}
    VALIDATION_MESSAGE=
    if ! core_validate_package_name "$package"; then
        VALIDATION_MESSAGE="Invalid package name: $package"
        return 1
    fi
    return 0
}

validate_package_available() {
    local package=$1
    if LC_ALL=C pacman -Sgq -- "$package" >/dev/null 2>&1; then
        return 0
    fi
    LC_ALL=C pacman -Si -- "$package" >/dev/null 2>&1
}

validate_packages() {
    ((${#PACKAGES[@]} > 0)) || die "The package list is empty."
    local -a missing=()
    local package
    for package in "${PACKAGES[@]}"; do
        validate_package_name "$package" || die "$VALIDATION_MESSAGE"
        if ! validate_package_available "$package"; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]})); then
        die "Packages not found in the repositories: $(core_join_by ', ' "${missing[@]}"). Check the names and mirror access."
    fi
}

_package_installed_bytes() {
    local package=$1
    local size
    size=$(LC_ALL=C pacman -Si -- "$package" 2>/dev/null |
        awk -F': ' '/^Installed Size/ {print $2; exit}')
    [[ -n $size ]] || return 1
    core_bytes_from_size "$size"
}

validate_package_size() {
    local total=0
    local package member bytes
    local -a queue=("${PACKAGES[@]}")
    local -A seen=()
    local index=0
    while ((index < ${#queue[@]})); do
        package=${queue[$index]}
        index=$((index + 1))
        [[ -n ${seen[$package]:-} ]] && continue
        seen[$package]=1
        if LC_ALL=C pacman -Sgq -- "$package" >/dev/null 2>&1; then
            while IFS= read -r member; do
                [[ -n $member ]] && queue+=("$member")
            done < <(LC_ALL=C pacman -Sgq -- "$package" 2>/dev/null || true)
            continue
        fi
        bytes=$(_package_installed_bytes "$package" || true)
        core_is_uint "$bytes" || continue
        total=$((total + bytes))
    done
    REQUIRED_BYTES=$total
    info "Estimated installed size: $(core_human_size "$total")."
}

validate_disk_capacity() {
    [[ -n ${DISK_BYTES:-} ]] || die "No disk selected."
    local reserve=$((2 * 1024 * 1024 * 1024))
    local available=$((DISK_BYTES - EFI_SIZE_MIB * 1024 * 1024 - reserve))
    if ((available < REQUIRED_BYTES)); then
        die "Not enough space: about $(core_human_size "$REQUIRED_BYTES") required, $(core_human_size "$available") available after reserve."
    fi
    if [[ ${MODE:-minimal} != minimal ]] && ((DISK_BYTES < 30 * 1024 * 1024 * 1024)); then
        warn "A disk of at least 30 GiB is recommended for a graphical profile."
    fi
}

validate_layout() {
    [[ -n ${DISK:-} ]] || die "Target disk not selected."
    [[ -b $DISK ]] || die "Target disk is not a block device: $DISK"
    ((EFI_SIZE_MIB >= 512)) || die "EFI partition is too small."
    local root_bytes=$((DISK_BYTES - EFI_SIZE_MIB * 1024 * 1024))
    ((root_bytes >= 16 * 1024 * 1024 * 1024)) ||
        die "The root partition would be smaller than 16 GiB."
}

# Match a Btrfs root subvolume flag in either the mount-option form used by
# fstab (subvol=/@ or subvol=@) or the kernel-argument form (rootflags=subvol=@).
# The trailing delimiter prevents @home from being mistaken for the root.
validate_btrfs_root_flag() {
    local file=$1
    grep -Eq '(^|[,[:space:]=])subvol=/?@([,[:space:]]|$)' "$file"
}

validate_fstab() {
    local fstab=$1
    [[ -s $fstab ]] || die "fstab is empty or missing: $fstab"
    grep -Eq '^[^#].*[[:space:]]/[[:space:]]' "$fstab" || die "fstab has no entry for /."
    grep -Eq '^[^#].*[[:space:]]/boot[[:space:]]' "$fstab" || die "fstab has no entry for /boot."
    if grep -Eq '^(tmpfs|overlay|proc|sysfs|devtmpfs|none)[[:space:]]+/[[:space:]]' "$fstab"; then
        die "The root filesystem in fstab is not a persistent device."
    fi
    if [[ ${FS_TYPE:-} == btrfs ]]; then
        validate_btrfs_root_flag "$fstab" ||
            die "The Btrfs root subvolume @ is missing from fstab."
    fi
    if command -v findmnt >/dev/null 2>&1; then
        if ! findmnt --verify --tab-file "$fstab" >/dev/null 2>&1; then
            warn "findmnt --verify reported fstab warnings; check the log."
        fi
    fi
}

validate_install_result() {
    local kernel=${KERNEL:-linux}
    [[ -x $TARGET/bin/bash ]] || die "The target system has no /bin/bash."
    [[ -s $TARGET/etc/fstab ]] || die "/etc/fstab was not created."
    [[ -f $TARGET/boot/vmlinuz-$kernel ]] || die "/boot/vmlinuz-$kernel was not found."
    [[ -f $TARGET/boot/initramfs-$kernel.img ]] || die "initramfs for kernel $kernel was not found."
    [[ -f $TARGET/boot/loader/entries/archinstall-super.conf ]] ||
        die "The systemd-boot entry was not created."
    [[ -f $TARGET/boot/EFI/systemd/systemd-bootx64.efi ]] ||
        die "systemd-boot is not installed in the EFI partition."
    arch-chroot "$TARGET" id "$USERNAME" >/dev/null 2>&1 ||
        die "User $USERNAME was not created."
    arch-chroot "$TARGET" systemctl is-enabled NetworkManager >/dev/null 2>&1 ||
        die "NetworkManager is not enabled in the target system."
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        grep -q "cryptdevice=UUID=${LUKS_UUID:-}" "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "cryptdevice is missing from the boot entry."
    fi
    if [[ ${FS_TYPE:-} == btrfs ]]; then
        validate_btrfs_root_flag "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "rootflags=subvol=@ is missing from the boot entry."
    fi
}

validate_config() {
    validate_hostname "$HOSTNAME" || die "$VALIDATION_MESSAGE"
    validate_username "$USERNAME" || die "$VALIDATION_MESSAGE"
    validate_timezone "$TIMEZONE" || die "$VALIDATION_MESSAGE"
    validate_locale "$LOCALE" || die "$VALIDATION_MESSAGE"
    validate_keymap "$KEYMAP" || die "$VALIDATION_MESSAGE"
    case ${ROOT_POLICY:-password} in
        password)
            validate_password "$ROOT_PASSWORD" root "$HOSTNAME" || die "Root password: $VALIDATION_MESSAGE"
            ;;
        locked) ;;
        *) die "Unknown root policy: $ROOT_POLICY" ;;
    esac
    validate_password "$USER_PASSWORD" "$USERNAME" "$HOSTNAME" ||
        die "User password: $VALIDATION_MESSAGE"
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        validate_password "$LUKS_PASSWORD" "$USERNAME" "$HOSTNAME" ||
            die "Encryption password: $VALIDATION_MESSAGE"
    fi
    case ${KERNEL:-linux} in
        linux|linux-lts|linux-zen|linux-hardened) ;;
        *) die "Unsupported kernel: ${KERNEL:-}" ;;
    esac
    case ${FS_TYPE:-ext4} in
        ext4|btrfs|xfs) ;;
        *) die "Unsupported filesystem: ${FS_TYPE:-}" ;;
    esac
}

validate_all() {
    validate_config
    validate_storage_commands
    storage_validate_selected_disk
    validate_packages
    validate_package_size
    validate_disk_capacity
    validate_layout
}
