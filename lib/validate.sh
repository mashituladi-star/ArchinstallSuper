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
    core_is_uefi || die "Система загружена не в UEFI-режиме. Legacy/CSM не поддерживается."
    [[ -d /sys/firmware/efi/efivars ]] ||
        die "EFI-переменные недоступны: отсутствует /sys/firmware/efi/efivars."
    if ! mountpoint -q /sys/firmware/efi/efivars 2>/dev/null; then
        warn "efivarfs не смонтирован как отдельная файловая система."
    fi
    [[ -w /sys/firmware/efi/efivars ]] ||
        die "EFI-переменные доступны только для чтения. Загрузитесь в UEFI без ограничений NVRAM."
}

validate_target() {
    [[ -d $TARGET ]] || die "Целевой каталог не существует: $TARGET"
    if mountpoint -q "$TARGET" 2>/dev/null; then
        die "$TARGET уже смонтирован. Размонтируй его и запусти установщик снова."
    fi
    if [[ -n $(find "$TARGET" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null) ]]; then
        die "$TARGET не пуст. Это может быть предыдущая установка; очисти каталог вручную."
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
        *) die "Неподдерживаемая файловая система: ${FS_TYPE:-}" ;;
    esac
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        core_need cryptsetup
    fi
}

validate_environment() {
    core_require_root
    core_is_live_arch || die "Нужна live-среда официального Arch Linux ISO."
    [[ $(uname -m) == x86_64 ]] || die "Поддерживается только x86_64."
    validate_efi
    validate_target
    validate_base_commands
}

validate_hostname() {
    local hostname=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $hostname =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
        VALIDATION_MESSAGE="Имя компьютера должно содержать 1–63 символа: буквы, цифры и дефис, без дефиса в конце."
        return 1
    fi
    return 0
}

validate_username() {
    local username=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $username =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        VALIDATION_MESSAGE="Имя пользователя: строчная буква или _, затем строчные буквы, цифры, _ или - (до 32 символов)."
        return 1
    fi
    if [[ $username == root ]]; then
        VALIDATION_MESSAGE="Нельзя создавать пользователя root повторно."
        return 1
    fi
    return 0
}

validate_timezone() {
    local timezone=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $timezone =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; then
        VALIDATION_MESSAGE="Неверный формат часового пояса."
        return 1
    fi
    if [[ ! -f /usr/share/zoneinfo/$timezone ]]; then
        VALIDATION_MESSAGE="Часовой пояс не найден: $timezone"
        return 1
    fi
    return 0
}

validate_locale() {
    local locale=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $locale =~ ^[A-Za-z_]+\.UTF-8$ ]]; then
        VALIDATION_MESSAGE="Локаль должна иметь вид xx_XX.UTF-8."
        return 1
    fi
    local escaped=${locale//./\\.}
    if ! grep -Eq "^#?${escaped}[[:space:]]+UTF-8[[:space:]]*$" /etc/locale.gen 2>/dev/null; then
        VALIDATION_MESSAGE="Локаль $locale отсутствует в /etc/locale.gen live-системы."
        return 1
    fi
    return 0
}

validate_keymap() {
    local keymap=${1:-}
    VALIDATION_MESSAGE=
    if [[ ! $keymap =~ ^[A-Za-z0-9_-]+$ ]]; then
        VALIDATION_MESSAGE="Недопустимое имя раскладки."
        return 1
    fi
    if ! find /usr/share/kbd/keymaps -type f -name "${keymap}.map*" -print -quit 2>/dev/null | grep -q .; then
        VALIDATION_MESSAGE="Раскладка $keymap не найдена в live-системе."
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
        VALIDATION_MESSAGE="Пароль должен содержать не менее 8 символов."
        return 1
    fi
    if [[ $password == *:* ]]; then
        VALIDATION_MESSAGE="Пароль не должен содержать двоеточие (ограничение chpasswd)."
        return 1
    fi
    if [[ $password == *$'\n'* || $password == *$'\r'* ]]; then
        VALIDATION_MESSAGE="Пароль не должен содержать переводы строк."
        return 1
    fi
    if [[ -n $username && $password == "$username" ]]; then
        VALIDATION_MESSAGE="Пароль не должен совпадать с именем пользователя."
        return 1
    fi
    if [[ -n $hostname && $password == "$hostname" ]]; then
        VALIDATION_MESSAGE="Пароль не должен совпадать с именем компьютера."
        return 1
    fi
    case ${password,,} in
        password|password123|12345678|123456789|qwerty123|archlinux)
            VALIDATION_MESSAGE="Этот пароль слишком распространён."
            return 1
            ;;
    esac
    return 0
}

validate_package_name() {
    local package=${1:-}
    VALIDATION_MESSAGE=
    if ! core_validate_package_name "$package"; then
        VALIDATION_MESSAGE="Недопустимое имя пакета: $package"
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
    ((${#PACKAGES[@]} > 0)) || die "Список пакетов пуст."
    local -a missing=()
    local package
    for package in "${PACKAGES[@]}"; do
        validate_package_name "$package" || die "$VALIDATION_MESSAGE"
        if ! validate_package_available "$package"; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]})); then
        die "Пакеты не найдены в репозиториях: $(core_join_by ', ' "${missing[@]}"). Проверь имена и доступ к зеркалам."
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
    info "Оценка устанавливаемых данных: $(core_human_size "$total")."
}

validate_disk_capacity() {
    [[ -n ${DISK_BYTES:-} ]] || die "Не выбран диск."
    local reserve=$((2 * 1024 * 1024 * 1024))
    local available=$((DISK_BYTES - EFI_SIZE_MIB * 1024 * 1024 - reserve))
    if ((available < REQUIRED_BYTES)); then
        die "Недостаточно места: нужно примерно $(core_human_size "$REQUIRED_BYTES"), доступно $(core_human_size "$available") после резерва."
    fi
    if [[ ${MODE:-minimal} != minimal ]] && ((DISK_BYTES < 30 * 1024 * 1024 * 1024)); then
        warn "Для графического профиля рекомендуется диск не менее 30 GiB."
    fi
}

validate_layout() {
    [[ -n ${DISK:-} ]] || die "Целевой диск не выбран."
    [[ -b $DISK ]] || die "Целевой диск не является блочным устройством: $DISK"
    ((EFI_SIZE_MIB >= 512)) || die "EFI-раздел слишком мал."
    local root_bytes=$((DISK_BYTES - EFI_SIZE_MIB * 1024 * 1024))
    ((root_bytes >= 16 * 1024 * 1024 * 1024)) ||
        die "Корневой раздел получится меньше 16 GiB."
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
    [[ -s $fstab ]] || die "fstab пуст или не создан: $fstab"
    grep -Eq '^[^#].*[[:space:]]/[[:space:]]' "$fstab" || die "В fstab нет записи для /."
    grep -Eq '^[^#].*[[:space:]]/boot[[:space:]]' "$fstab" || die "В fstab нет записи для /boot."
    if grep -Eq '^(tmpfs|overlay|proc|sysfs|devtmpfs|none)[[:space:]]+/[[:space:]]' "$fstab"; then
        die "Корневая файловая система в fstab не является постоянным устройством."
    fi
    if [[ ${FS_TYPE:-} == btrfs ]]; then
        validate_btrfs_root_flag "$fstab" ||
            die "В fstab отсутствует корневой подтом Btrfs @."
    fi
    if command -v findmnt >/dev/null 2>&1; then
        if ! findmnt --verify --tab-file "$fstab" >/dev/null 2>&1; then
            warn "findmnt --verify сообщил о замечаниях к fstab; проверь журнал."
        fi
    fi
}

validate_install_result() {
    local kernel=${KERNEL:-linux}
    [[ -x $TARGET/bin/bash ]] || die "В целевой системе нет /bin/bash."
    [[ -s $TARGET/etc/fstab ]] || die "Не создан /etc/fstab."
    [[ -f $TARGET/boot/vmlinuz-$kernel ]] || die "Не найден /boot/vmlinuz-$kernel."
    [[ -f $TARGET/boot/initramfs-$kernel.img ]] || die "Не найден initramfs для ядра $kernel."
    [[ -f $TARGET/boot/loader/entries/archinstall-super.conf ]] ||
        die "Не создана загрузочная запись systemd-boot."
    [[ -f $TARGET/boot/EFI/systemd/systemd-bootx64.efi ]] ||
        die "systemd-boot не установлен в EFI-раздел."
    arch-chroot "$TARGET" id "$USERNAME" >/dev/null 2>&1 ||
        die "Пользователь $USERNAME не создан."
    arch-chroot "$TARGET" systemctl is-enabled NetworkManager >/dev/null 2>&1 ||
        die "NetworkManager не включён в целевой системе."
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        grep -q "cryptdevice=UUID=${LUKS_UUID:-}" "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "В загрузочной записи отсутствует cryptdevice."
    fi
    if [[ ${FS_TYPE:-} == btrfs ]]; then
        validate_btrfs_root_flag "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "В загрузочной записи отсутствует rootflags=subvol=@."
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
            validate_password "$ROOT_PASSWORD" root "$HOSTNAME" || die "Пароль root: $VALIDATION_MESSAGE"
            ;;
        locked) ;;
        *) die "Неизвестная политика root: $ROOT_POLICY" ;;
    esac
    validate_password "$USER_PASSWORD" "$USERNAME" "$HOSTNAME" ||
        die "Пароль пользователя: $VALIDATION_MESSAGE"
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        validate_password "$LUKS_PASSWORD" "$USERNAME" "$HOSTNAME" ||
            die "Пароль шифрования: $VALIDATION_MESSAGE"
    fi
    case ${KERNEL:-linux} in
        linux|linux-lts|linux-zen|linux-hardened) ;;
        *) die "Неподдерживаемое ядро: ${KERNEL:-}" ;;
    esac
    case ${FS_TYPE:-ext4} in
        ext4|btrfs|xfs) ;;
        *) die "Неподдерживаемая файловая система: ${FS_TYPE:-}" ;;
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
