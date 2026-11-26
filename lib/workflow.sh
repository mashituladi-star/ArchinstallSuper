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
        confirm=$(ui_password "$title" "Repeat the password to verify:") || return 1
        if [[ $password != "$confirm" ]]; then
            ui_error "Passwords do not match. Try again."
            attempts=$((attempts + 1))
            continue
        fi
        if problem=$(security_password_problem "$password" "$user" "$HOSTNAME"); then
            ui_error "Password rejected: $problem"
            attempts=$((attempts + 1))
            continue
        fi
        printf '%s' "$password"
        return 0
    done
    ui_error "Too many failed attempts."
    return 1
}

workflow_select_mode() {
    local choice
    choice=$(ui_menu "System profile" \
        "Choose the software set to install." \
        "minimal" "Minimal · console" \
        "basic" "Basic · GNOME" \
        "full" "Full · GNOME + applications" \
        "custom" "Custom setup") || die "Profile selection cancelled."
    case $choice in
        minimal) MODE=minimal; DESKTOP= ;;
        basic) MODE=basic; DESKTOP=gnome ;;
        full) MODE=full; DESKTOP=gnome ;;
        custom) MODE=custom; workflow_select_desktop ;;
        *) die "Unknown profile: $choice" ;;
    esac
}

workflow_select_desktop() {
    local choice
    choice=$(ui_menu "Desktop environment" "Choose a graphical desktop or console." \
        "none" "Console only" \
        "gnome" "GNOME" \
        "kde" "KDE Plasma" \
        "xfce" "XFCE" \
        "cinnamon" "Cinnamon") || die "Desktop selection cancelled."
    case $choice in
        none) DESKTOP= ;;
        gnome|kde|xfce|cinnamon) DESKTOP=$choice ;;
        *) die "Unknown desktop: $choice" ;;
    esac
}

workflow_select_kernel() {
    local choice
    choice=$(ui_menu "Linux kernel" "Choose a kernel. All options work with systemd-boot." \
        "linux" "linux · stable" \
        "linux-lts" "linux-lts · long-term support" \
        "linux-zen" "linux-zen · optimized for responsiveness" \
        "linux-hardened" "linux-hardened · hardened security") ||
        die "Kernel selection cancelled."
    KERNEL=$choice
}

workflow_select_filesystem() {
    local choice
    choice=$(ui_menu "Filesystem" "Choose the root filesystem format." \
        "ext4" "ext4 · simple and reliable" \
        "btrfs" "Btrfs · subvolumes, snapshots, zstd compression" \
        "xfs" "XFS · high performance for large disks") ||
        die "Filesystem selection cancelled."
    FS_TYPE=$choice
}

workflow_select_encryption() {
    if ! ui_confirm "Enable LUKS2 encryption for the root partition?\n\nYou will be asked for the password on every boot."; then
        ENCRYPT=0
        return 0
    fi
    ENCRYPT=1
    # shellcheck disable=SC2034  # used across modules
    LUKS_PASSWORD=$(workflow_ask_password "LUKS2 encryption" "Root encryption password:" "$USERNAME") ||
        die "Encryption password not set."
}

workflow_system_settings() {
    local attempts value

    attempts=0
    while true; do
        value=$(ui_input "Hostname" "Hostname:" "archlinux") || die "Cancelled."
        if validate_hostname "$value"; then HOSTNAME=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Could not set the hostname."
    done

    attempts=0
    while true; do
        value=$(ui_input "User account" "Regular user name:") || die "Cancelled."
        if validate_username "$value"; then USERNAME=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Could not set the user name."
    done

    attempts=0
    while true; do
        value=$(ui_input "Timezone" "For example Europe/Prague or UTC:" "Europe/Prague") ||
            die "Cancelled."
        if validate_timezone "$value"; then TIMEZONE=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Could not set the timezone."
    done

    attempts=0
    while true; do
        value=$(ui_input "Locale" "System locale:" "en_US.UTF-8") || die "Cancelled."
        if validate_locale "$value"; then LOCALE=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Could not set the locale."
    done

    attempts=0
    while true; do
        value=$(ui_input "Keyboard layout" "Keyboard layout:" "us") || die "Cancelled."
        if validate_keymap "$value"; then KEYMAP=$value; break; fi
        ui_error "$VALIDATION_MESSAGE"
        attempts=$((attempts + 1))
        ((attempts < 3)) || die "Could not set the keyboard layout."
    done

    local root_choice
    root_choice=$(ui_menu "Root password" "How should the system be administered?" \
        "password" "Set a root password" \
        "locked" "Lock root and use sudo") ||
        die "Root policy selection cancelled."
    ROOT_POLICY=$root_choice
    if [[ $ROOT_POLICY == password ]]; then
        # shellcheck disable=SC2034  # used across modules
        ROOT_PASSWORD=$(workflow_ask_password "Root password" "Root administrator password:" root) ||
            die "Root password not set."
    else
        # shellcheck disable=SC2034  # used across modules
        ROOT_PASSWORD=
    fi

    # shellcheck disable=SC2034  # used across modules
    USER_PASSWORD=$(workflow_ask_password "User password" \
        "Password for $USERNAME:" "$USERNAME") || die "User password not set."
}

workflow_extra_packages() {
    local text package
    local -a extra=()
    text=$(ui_input "Additional packages" \
        "Package names separated by spaces (leave empty to skip):" "") || return 0
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
            if ui_confirm "Add development tools (Git, Python, Node.js, compilers)?"; then
                PACKAGES+=(git base-devel python python-pip nodejs npm)
            fi
            if ui_confirm "Add Firefox, VLC, GIMP and LibreOffice?"; then
                PACKAGES+=(firefox vlc gimp libreoffice-fresh)
            fi
            ;;
        *) die "Unknown profile: $MODE" ;;
    esac

    case $DESKTOP in
        '') ;;
        gnome) PACKAGES+=(gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        kde) PACKAGES+=(plasma-meta konsole dolphin sddm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        xfce) PACKAGES+=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        cinnamon) PACKAGES+=(cinnamon lightdm lightdm-gtk-greeter pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        *) die "Unknown desktop: $DESKTOP" ;;
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
PROFILE
  Mode:             $MODE
  Desktop:          $(core_value_or "$DESKTOP" 'console')
  Kernel:           $KERNEL
  Packages:         ${#PACKAGES[@]}

DISK
$(storage_layout_text | sed 's/^/  /')

SYSTEM
  Hostname:         $HOSTNAME
  User:             $USERNAME
  Root:             $(if [[ $ROOT_POLICY == locked ]]; then echo 'locked (sudo)'; else echo 'password set'; fi)
  Timezone:         $TIMEZONE
  Locale:           $LOCALE
  Keyboard layout:  $KEYMAP
  zram:             $(if ((ZRAM)); then echo yes; else echo no; fi)
  Secure Boot:      ${HW_SECURE_BOOT:-unknown}

WARNING: all data on $DISK will be destroyed.
EOF
}

workflow_show_summary() {
    local file="$TEMP_DIR/summary.txt"
    workflow_summary_text >"$file"
    ui_show_text "Pre-installation check" "$file"
}

workflow_final_confirm() {
    local answer
    answer=$(ui_input "Final confirmation" \
        "Type INSTALL to begin. Disk $DISK will be erased:") ||
        die "Cancelled before any disk changes."
    [[ $answer == INSTALL ]] || die "Confirmation did not match; the disk was not changed."
}

workflow_collect() {
    ui_step_set 2
    workflow_select_mode
    ui_step_set 3
    workflow_select_kernel
    ui_step_set 4
    workflow_select_filesystem
    ui_step_set 5
    storage_select_disk
    ui_step_set 6
    workflow_system_settings
    ui_step_set 7
    workflow_select_encryption
    ui_step_set 8
    if ui_confirm "Enable zram (compressed swap in RAM)?"; then
        ZRAM=1
    else
        ZRAM=0
    fi
    workflow_extra_packages
    workflow_build_packages
    hw_check_memory "$([[ -n $DESKTOP ]] && echo 1 || echo 0)"
    if [[ ${HW_SECURE_BOOT:-} == *enabled* ]]; then
        warn "Secure Boot is enabled, but systemd-boot is not signed. Booting may require disabling Secure Boot or manually enrolling keys."
    fi
    validate_all
    ui_step_set 9
}

workflow_execute() {
    ui_step_set 10
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
        die "Could not safely unmount the target system."
    fi
    # shellcheck disable=SC2034  # used across modules
    INSTALL_COMPLETE=1
    plugin_hook pre_reboot
}

workflow_after_success() {
    ui_msg "$(install_success_text)" "Installation complete"
    if ui_confirm "Reboot now?"; then
        reboot
    else
        info "Reboot manually after removing the installation media."
    fi
}

workflow_check_only() {
    validate_environment
    hw_detect
    hw_report
    local rc=0
    network_check || rc=1
    if ((rc == 0)); then
        info "Preflight check passed: UEFI, live environment and network are available."
    fi
    return "$rc"
}

# Non-interactive execution for unattended mode. Skips all UI screens and
# uses values already loaded from the configuration file.
workflow_execute_auto() {
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
    install_copy_log
    plugin_hook post_install
    if ! storage_unmount_target; then
        die "Could not safely unmount the target system."
    fi
    # shellcheck disable=SC2034  # completion flag
    INSTALL_COMPLETE=1
    plugin_hook pre_reboot
}

workflow_after_success_auto() {
    local text
    text=$(install_success_text)
    printf '%s\n' "$text"
    local reboot=${CONFIG_REBOOT:-1}
    if ((reboot)); then
        info "Rebooting in 10 seconds. Press Ctrl-C to cancel."
        sleep 10 || true
        reboot
    else
        info "Reboot manually after removing the installation media."
    fi
}
