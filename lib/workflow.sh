#!/usr/bin/env bash
# shellcheck shell=bash
# Interactive installation workflow. This module owns ordering and user
# decisions; the actual work is delegated to the focused managers.

[[ -n ${AS_WORKFLOW_LOADED:-} ]] && return 0
AS_WORKFLOW_LOADED=1

: "${MODE:=minimal}"
: "${DESKTOP:=}"
: "${KERNEL:=linux}"
: "${FS_TYPE:=ext4}"
: "${ENCRYPT:=0}"
: "${ZRAM:=0}"
: "${ROOT_POLICY:=password}"
PACKAGES=()
EXTRA_PACKAGES=()

workflow_ask_password() {
    local title=$1
    local prompt=$2
    local user=$3
    local attempts=0
    local password confirm problem
    while ((attempts < 3)); do
        password=$(ui_password "$title" "$prompt") || return 1
        confirm=$(ui_password "$title" "Повтори пароль для проверки:") || return 1
        if [[ $password != "$confirm" ]]; then
            ui_error "Пароли не совпадают. Попробуй снова."
            attempts=$((attempts + 1))
            continue
        fi
        if problem=$(security_password_problem "$password" "$user" "$HOSTNAME"); then
            ui_error "Пароль не принят: $problem"
            attempts=$((attempts + 1))
            continue
        fi
        printf '%s' "$password"
        return 0
    done
    ui_error "Слишком много неудачных попыток."
    return 1
}

workflow_select_mode() {
    local choice
    choice=$(ui_menu "Профиль системы" \
        "Выбери состав устанавливаемой системы." \
        "minimal" "Минимальная · консоль" \
        "basic" "Базовая · GNOME" \
        "full" "Полная · GNOME + приложения" \
        "custom" "Кастомная настройка") || die "Выбор профиля отменён."
    case $choice in
        minimal) MODE=minimal; DESKTOP= ;;
        basic) MODE=basic; DESKTOP=gnome ;;
        full) MODE=full; DESKTOP=gnome ;;
        custom) MODE=custom; workflow_select_desktop ;;
        *) die "Неизвестный профиль: $choice" ;;
    esac
}

workflow_select_desktop() {
    local choice
    choice=$(ui_menu "Рабочее окружение" "Выбери графическую среду или консоль." \
        "none" "Только консоль" \
        "gnome" "GNOME" \
        "kde" "KDE Plasma" \
        "xfce" "XFCE" \
        "cinnamon" "Cinnamon") || die "Выбор окружения отменён."
    case $choice in
        none) DESKTOP= ;;
        gnome|kde|xfce|cinnamon) DESKTOP=$choice ;;
        *) die "Неизвестное окружение: $choice" ;;
    esac
}

workflow_select_kernel() {
    local choice
    choice=$(ui_menu "Ядро Linux" "Выбери ядро. Все варианты совместимы с systemd-boot." \
        "linux" "linux · стабильное" \
        "linux-lts" "linux-lts · долгосрочное" \
        "linux-zen" "linux-zen · оптимизировано для отзывчивости" \
        "linux-hardened" "linux-hardened · усиленная безопасность") ||
        die "Выбор ядра отменён."
    KERNEL=$choice
}

workflow_select_filesystem() {
    local choice
    choice=$(ui_menu "Файловая система" "Выбери формат корневого раздела." \
        "ext4" "ext4 · простая и надёжная" \
        "btrfs" "Btrfs · подтомы, снимки, сжатие zstd" \
        "xfs" "XFS · производительная для больших дисков") ||
        die "Выбор файловой системы отменён."
    FS_TYPE=$choice
}

workflow_select_encryption() {
    if ! ui_confirm "Включить шифрование корневого раздела LUKS2?\n\nПароль будет запрошен при каждой загрузке."; then
        ENCRYPT=0
        return 0
    fi
    ENCRYPT=1
    # shellcheck disable=SC2034  # used across modules
    LUKS_PASSWORD=$(workflow_ask_password "Шифрование LUKS2" "Пароль шифрования корневого раздела:" "$USERNAME") ||
        die "Пароль шифрования не задан."
}

workflow_system_settings() {
    local attempts value

    attempts=0
    while true; do
        value=$(ui_input "Имя компьютера" "Hostname:" "archlinux") || die "Отменено."
        if validate_hostname "$value"; then HOSTNAME=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Не удалось задать hostname."
    done

    attempts=0
    while true; do
        value=$(ui_input "Учётная запись" "Имя обычного пользователя:") || die "Отменено."
        if validate_username "$value"; then USERNAME=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Не удалось задать имя пользователя."
    done

    attempts=0
    while true; do
        value=$(ui_input "Часовой пояс" "Например Europe/Prague или UTC:" "Europe/Prague") ||
            die "Отменено."
        if validate_timezone "$value"; then TIMEZONE=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Не удалось задать часовой пояс."
    done

    attempts=0
    while true; do
        value=$(ui_input "Локаль" "Локаль системы:" "en_US.UTF-8") || die "Отменено."
        if validate_locale "$value"; then LOCALE=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Не удалось задать локаль."
    done

    attempts=0
    while true; do
        value=$(ui_input "Раскладка клавиатуры" "Раскладка:" "us") || die "Отменено."
        if validate_keymap "$value"; then KEYMAP=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Не удалось задать раскладку."
    done

    local root_choice
    root_choice=$(ui_menu "Пароль root" "Как администрировать систему?" \
        "password" "Задать пароль root" \
        "locked" "Заблокировать root, использовать sudo") ||
        die "Выбор политики root отменён."
    ROOT_POLICY=$root_choice
    if [[ $ROOT_POLICY == password ]]; then
        # shellcheck disable=SC2034  # used across modules
        ROOT_PASSWORD=$(workflow_ask_password "Пароль root" "Пароль администратора root:" root) ||
            die "Пароль root не задан."
    else
        # shellcheck disable=SC2034  # used across modules
        ROOT_PASSWORD=
    fi

    # shellcheck disable=SC2034  # used across modules
    USER_PASSWORD=$(workflow_ask_password "Пароль пользователя" \
        "Пароль для $USERNAME:" "$USERNAME") || die "Пароль пользователя не задан."
}

workflow_extra_packages() {
    local text package
    local -a extra=()
    text=$(ui_input "Дополнительные пакеты" \
        "Имена пакетов через пробел (можно оставить пустым):" "") || return 0
    [[ -n $text ]] || return 0
    read -r -a extra <<<"$text"
    for package in "${extra[@]}"; do
        if ! validate_package_name "$package"; then
            ui_error "$VALIDATION_MESSAGE"
            continue
        fi
        EXTRA_PACKAGES+=("$package")
    done
}

workflow_build_packages() {
    PACKAGES=(base "$KERNEL" linux-firmware networkmanager wpa_supplicant sudo nano
        kbd e2fsprogs dosfstools)
    case $MODE in
        minimal) ;;
        basic)
            PACKAGES+=(git firefox gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber)
            ;;
        full)
            PACKAGES+=(git firefox gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber
                libreoffice-fresh vlc gimp gnome-tweaks flatpak base-devel fastfetch btop htop
                curl wget zip unzip)
            ;;
        custom)
            if ui_confirm "Добавить инструменты разработки (Git, Python, Node.js, компиляторы)?"; then
                PACKAGES+=(git base-devel python python-pip nodejs npm)
            fi
            if ui_confirm "Добавить Firefox, VLC, GIMP и LibreOffice?"; then
                PACKAGES+=(firefox vlc gimp libreoffice-fresh)
            fi
            ;;
        *) die "Неизвестный профиль: $MODE" ;;
    esac

    case $DESKTOP in
        '') ;;
        gnome) PACKAGES+=(gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        kde) PACKAGES+=(plasma-meta konsole dolphin sddm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        xfce) PACKAGES+=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        cinnamon) PACKAGES+=(cinnamon lightdm lightdm-gtk-greeter pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        *) die "Неизвестное окружение: $DESKTOP" ;;
    esac

    local fs_package
    fs_package=$(storage_fs_packages)
    [[ -n $fs_package ]] && PACKAGES+=("$fs_package")
    ((ZRAM)) && PACKAGES+=(zram-generator)
    [[ ${ENCRYPT:-0} == 1 ]] && PACKAGES+=(cryptsetup)
    PACKAGES+=("${EXTRA_PACKAGES[@]}")
    hw_add_packages "$([[ -n $DESKTOP ]] && echo 1 || echo 0)"
    core_dedupe_array PACKAGES
}

workflow_summary_text() {
    cat <<EOF
ПРОФИЛЬ
  Режим:            $MODE
  Окружение:        $(core_value_or "$DESKTOP" 'консоль')
  Ядро:             $KERNEL
  Пакетов:          ${#PACKAGES[@]}

ДИСК
$(storage_layout_text | sed 's/^/  /')

СИСТЕМА
  Hostname:         $HOSTNAME
  Пользователь:     $USERNAME
  Root:             $(if [[ $ROOT_POLICY == locked ]]; then echo 'заблокирован (sudo)'; else echo 'пароль задан'; fi)
  Часовой пояс:     $TIMEZONE
  Локаль:           $LOCALE
  Раскладка:        $KEYMAP
  zram:             $(if ((ZRAM)); then echo да; else echo нет; fi)
  Secure Boot:      ${HW_SECURE_BOOT:-неизвестно}

ВНИМАНИЕ: все данные на $DISK будут уничтожены.
EOF
}

workflow_show_summary() {
    local file="$TEMP_DIR/summary.txt"
    workflow_summary_text >"$file"
    ui_show_text "Проверка перед установкой" "$file"
}

workflow_final_confirm() {
    local answer
    answer=$(ui_input "Финальное подтверждение" \
        "Введи INSTALL, чтобы начать установку. Диск $DISK будет очищен:") ||
        die "Отменено до изменения диска."
    [[ $answer == INSTALL ]] || die "Подтверждение не совпало; диск не изменён."
}

workflow_collect() {
    workflow_select_mode
    workflow_select_kernel
    workflow_select_filesystem
    storage_select_disk
    workflow_system_settings
    workflow_select_encryption
    if ui_confirm "Включить zram (сжатый swap в оперативной памяти)?"; then
        ZRAM=1
    else
        ZRAM=0
    fi
    workflow_extra_packages
    workflow_build_packages
    hw_check_memory "$([[ -n $DESKTOP ]] && echo 1 || echo 0)"
    if [[ ${HW_SECURE_BOOT:-} == *включ* || ${HW_SECURE_BOOT:-} == *enabled* ]]; then
        warn "Secure Boot включён, а systemd-boot не подписывается. Загрузка может потребовать отключения Secure Boot или ручного добавления ключей."
    fi
    validate_all
}

workflow_execute() {
    # shellcheck disable=SC2034  # used across modules
    INSTALL_STARTED=1
    plugin_hook pre_install
    storage_partition_disk
    storage_make_filesystems
    storage_mount_target
    install_pacstrap
    storage_generate_fstab
    config_apply_all
    boot_apply_all
    install_verify
    # Copy the log after verification so the saved copy includes its result.
    install_copy_log
    plugin_hook post_install
    if ! storage_unmount_target; then
        die "Не удалось безопасно размонтировать целевую систему."
    fi
    # shellcheck disable=SC2034  # used across modules
    INSTALL_COMPLETE=1
    plugin_hook pre_reboot
}

workflow_after_success() {
    ui_msg "$(install_success_text)" "Установка завершена"
    if ui_confirm "Перезагрузиться сейчас?"; then
        reboot
    else
        info "Перезагрузись вручную после извлечения установочного носителя."
    fi
}

workflow_check_only() {
    validate_environment
    hw_detect
    hw_report
    local rc=0
    network_check || rc=1
    if ((rc == 0)); then
        info "Предварительная проверка пройдена: UEFI, live-среда и интернет доступны."
    fi
    return "$rc"
}
