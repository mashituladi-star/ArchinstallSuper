#!/usr/bin/env bash
# shellcheck shell=bash
# Boot manager: systemd-boot, kernel command line and initramfs.
#
# The generated entry is the single source of truth for the root filesystem:
# encrypted roots use cryptdevice=..., Btrfs roots carry rootflags=subvol=@.

[[ -n ${AS_BOOT_LOADED:-} ]] && return 0
AS_BOOT_LOADED=1

: "${KERNEL:=linux}"
UCODE_IMAGES=()

boot_collect_ucode() {
    UCODE_IMAGES=()
    [[ -f $TARGET/boot/intel-ucode.img ]] && UCODE_IMAGES+=("intel-ucode.img")
    [[ -f $TARGET/boot/amd-ucode.img ]] && UCODE_IMAGES+=("amd-ucode.img")
}

boot_kernel_args() {
    local args
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        args=$(security_luks_boot_args)
    else
        args="root=UUID=${ROOT_UUID} rw"
    fi
    if [[ ${FS_TYPE:-ext4} == btrfs ]]; then
        args+=" rootflags=subvol=@,compress=zstd"
    fi
    printf '%s' "$args"
}

boot_entry_content() {
    local kernel=${1:-$KERNEL}
    printf 'title Arch Linux (ArchinstallSuper)\n'
    printf 'linux /vmlinuz-%s\n' "$kernel"
    local image
    for image in "${UCODE_IMAGES[@]}"; do
        printf 'initrd /%s\n' "$image"
    done
    printf 'initrd /initramfs-%s.img\n' "$kernel"
    printf 'options %s\n' "$(boot_kernel_args)"
}

boot_loader_conf_content() {
    printf 'default archinstall-super.conf\ntimeout 3\nconsole-mode max\neditor no\nauto-entries no\nauto-firmware yes\n'
}

boot_hooks_with_encrypt() {
    local hooks=${1:-}
    [[ $hooks == *encrypt* ]] && {
        printf '%s' "$hooks"
        return 0
    }
    if [[ $hooks == *filesystems* ]]; then
        printf '%s' "${hooks/filesystems/encrypt filesystems}"
    else
        printf '%s encrypt' "$hooks"
    fi
}

boot_modules_with_fs() {
    local modules=${1:-}
    local fs=$2
    [[ -z $fs ]] && {
        printf '%s' "$modules"
        return 0
    }
    [[ " $modules " == *" $fs "* ]] && {
        printf '%s' "$modules"
        return 0
    }
    if [[ -n $modules ]]; then
        printf '%s %s' "$modules" "$fs"
    else
        printf '%s' "$fs"
    fi
}

boot_configure_initramfs() {
    local conf="$TARGET/etc/mkinitcpio.conf"
    [[ -f $conf ]] || die "File not found: $conf."
    local hooks_line hooks new_hooks
    hooks_line=$(grep '^HOOKS=' "$conf" || true)
    [[ -n $hooks_line ]] || die "HOOKS line not found in mkinitcpio.conf."
    hooks=${hooks_line#HOOKS=(}
    hooks=${hooks%)}
    new_hooks=$(boot_hooks_with_encrypt "$hooks")
    sed -i "s|^HOOKS=.*|HOOKS=(${new_hooks})|" "$conf" ||
        die "Could not update HOOKS in mkinitcpio.conf."

    local fs_module=
    case ${FS_TYPE:-ext4} in
        btrfs) fs_module=btrfs ;;
        xfs) fs_module=xfs ;;
        *) fs_module= ;;
    esac
    if [[ -n $fs_module ]]; then
        local modules_line modules new_modules
        modules_line=$(grep '^MODULES=' "$conf" || true)
        if [[ -n $modules_line ]]; then
            modules=${modules_line#MODULES=(}
            modules=${modules%)}
            new_modules=$(boot_modules_with_fs "$modules" "$fs_module")
            sed -i "s|^MODULES=.*|MODULES=(${new_modules})|" "$conf" ||
                die "Could not update MODULES in mkinitcpio.conf."
        else
            printf 'MODULES=(%s)\n' "$fs_module" >>"$conf"
        fi
    fi

    info "Rebuilding initramfs."
    arch-chroot "$TARGET" mkinitcpio -P || die "mkinitcpio failed."
}

boot_write_loader_conf() {
    mkdir -p "$TARGET/boot/loader/entries" || die "Could not create the systemd-boot directory."
    boot_loader_conf_content >"$TARGET/boot/loader/loader.conf" ||
        die "Could not write loader.conf."
}

boot_write_entry() {
    boot_collect_ucode
    boot_entry_content "$KERNEL" >"$TARGET/boot/loader/entries/archinstall-super.conf" ||
        die "Could not write the boot entry."
}

boot_install() {
    info "Installing systemd-boot to the EFI partition."
    if arch-chroot "$TARGET" bootctl --esp-path=/boot install; then
        return 0
    fi
    # Some virtual machines and locked-down firmware reject NVRAM updates even
    # though the EFI files themselves can be installed. Fall back to a
    # files-only install; the entry can be added later from the firmware menu.
    warn "bootctl could not update NVRAM; retrying without EFI variables."
    arch-chroot "$TARGET" bootctl --esp-path=/boot --no-variables install ||
        die "bootctl could not install systemd-boot. Check the EFI partition and NVRAM."
}

boot_verify() {
    [[ -f $TARGET/boot/EFI/systemd/systemd-bootx64.efi ]] ||
        die "systemd-bootx64.efi is missing from the EFI partition."
    [[ -f $TARGET/boot/loader/loader.conf ]] || die "loader.conf is missing."
    [[ -f $TARGET/boot/loader/entries/archinstall-super.conf ]] ||
        die "The boot entry is missing."
    [[ -f $TARGET/boot/vmlinuz-$KERNEL ]] || die "Kernel /vmlinuz-$KERNEL is not installed."
    [[ -f $TARGET/boot/initramfs-$KERNEL.img ]] ||
        die "initramfs for $KERNEL was not created."
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        grep -q "cryptdevice=UUID=${LUKS_UUID}" "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "The boot entry has an invalid cryptdevice."
        grep -q "root=/dev/mapper/${LUKS_NAME}" "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "The boot entry has an invalid root for LUKS."
        security_luks_validate
    else
        grep -q "root=UUID=${ROOT_UUID}" "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "The boot entry has an invalid root=UUID."
    fi
    if [[ ${FS_TYPE:-} == btrfs ]]; then
        validate_btrfs_root_flag "$TARGET/boot/loader/entries/archinstall-super.conf" ||
            die "rootflags=subvol=@ is not set for Btrfs."
    fi
}

boot_apply_all() {
    # shellcheck disable=SC2034  # read by the EXIT trap in recovery.sh
    INSTALL_PHASE="bootloader"
    boot_configure_initramfs
    # Install the loader first: bootctl may create a default loader.conf, and
    # our explicit configuration must win.
    boot_install
    boot_write_loader_conf
    boot_write_entry
    boot_verify
}
