#!/usr/bin/env bash
# shellcheck shell=bash
# Storage manager: disk discovery, safety checks, GPT layout, filesystems,
# Btrfs subvolumes and mount/unmount lifecycle.
#
# All destructive entry points re-check the selected disk immediately before
# touching it. The caller is responsible for asking for explicit confirmation.

[[ -n ${AS_STORAGE_LOADED:-} ]] && return 0
AS_STORAGE_LOADED=1

: "${DISK:=}"
: "${DISK_BYTES:=0}"
: "${EFI_PART:=}"
: "${ROOT_PART:=}"
: "${ROOT_DEV:=}"
: "${ROOT_UUID:=}"
: "${FS_TYPE:=ext4}"
: "${EFI_SIZE_MIB:=1024}"
: "${MIN_DISK_BYTES:=$((24 * 1024 * 1024 * 1024))}"
: "${ROOT_SUBVOL:=@}"

storage_lsblk_field() {
    local line=$1
    local key=$2
    if [[ $line =~ (^|[[:space:]])${key}=\"([^\"]*)\" ]]; then
        printf '%s' "${BASH_REMATCH[2]}"
    fi
}

# Kept as a function so tests can exercise the rest of the safety logic without
# needing a real block device.
storage_is_block_device() {
    [[ -b ${1:-} ]]
}

storage_normalize_source() {
    local source=${1:-}
    [[ -n $source ]] || return 0
    source=${source%%[*}
    if [[ $source == /dev/* ]]; then
        readlink -f -- "$source" 2>/dev/null || printf '%s' "$source"
    fi
}

storage_live_source() {
    local source
    source=$(findmnt -nro SOURCE /run/archiso/bootmnt 2>/dev/null || true)
    source=$(storage_normalize_source "$source")
    [[ -n $source ]] || return 0
    if [[ -b $source ]]; then
        local parent
        parent=$(lsblk -nro PKNAME "$source" 2>/dev/null | head -n 1 || true)
        [[ -n $parent ]] && source="/dev/$parent"
    fi
    printf '%s' "$source"
}

# The ISO label from the kernel command line. This also protects the boot
# medium when copytoram is used and /run/archiso/bootmnt is no longer mounted.
storage_live_iso_label() {
    local label
    label=$(sed -n 's/.*archisolabel=\([^[:space:]]*\).*/\1/p' /proc/cmdline 2>/dev/null |
        head -n 1 || true)
    printf '%s' "$label"
}

storage_root_source() {
    local source
    source=$(findmnt -nro SOURCE / 2>/dev/null || true)
    source=$(storage_normalize_source "$source")
    [[ -n $source ]] || return 0
    if [[ -b $source ]]; then
        local parent
        parent=$(lsblk -nro PKNAME "$source" 2>/dev/null | head -n 1 || true)
        [[ -n $parent ]] && source="/dev/$parent"
    fi
    printf '%s' "$source"
}

storage_partition_name() {
    local disk=$1
    local number=$2
    if [[ $disk =~ (nvme[0-9]+n[0-9]+|mmcblk[0-9]+|loop[0-9]+|md[0-9]+|nbd[0-9]+)$ ]]; then
        printf '%sp%s' "$disk" "$number"
    else
        printf '%s%s' "$disk" "$number"
    fi
}

storage_human_disk() {
    local path=$1
    local size=$2
    local model=$3
    local transport=${4:-}
    local removable=${5:-0}
    local suffix=
    [[ -n $transport ]] && suffix+=", $transport"
    [[ $removable == 1 ]] && suffix+=", removable"
    printf '%s · %s · %s%s' "$(core_human_size "$size")" "$(core_value_or "$model" 'no model')" "$path" "$suffix"
}

# Print one record per disk: path<TAB>bytes<TAB>model<TAB>transport<TAB>removable
storage_list_disks() {
    local line path size model type transport removable ro
    local live root
    live=$(storage_live_source)
    root=$(storage_root_source)
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        path=$(storage_lsblk_field "$line" PATH)
        [[ -n $path ]] || path="/dev/$(storage_lsblk_field "$line" NAME)"
        size=$(storage_lsblk_field "$line" SIZE)
        model=$(storage_lsblk_field "$line" MODEL)
        # Keep the one-record-per-line TSV format intact.
        model=${model//$'\t'/ }
        type=$(storage_lsblk_field "$line" TYPE)
        transport=$(storage_lsblk_field "$line" TRAN)
        removable=$(storage_lsblk_field "$line" RM)
        ro=$(storage_lsblk_field "$line" RO)
        [[ $type == disk ]] || continue
        [[ $ro == 1 ]] && continue
        [[ -n $live && $path == "$live" ]] && continue
        [[ -n $root && $path == "$root" ]] && continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$path" "${size:-0}" "$model" "$transport" "$removable"
    done < <(lsblk -dn -P -b -o NAME,PATH,SIZE,MODEL,TYPE,TRAN,RM,RO 2>/dev/null || true)
}

storage_disk_safety_problem() {
    local disk=$1
    local live root
    live=$(storage_live_source)
    root=$(storage_root_source)
    if ! storage_is_block_device "$disk"; then
        printf 'This is not a block device.'
        return 0
    fi
    if [[ -n $live && $disk == "$live" ]]; then
        printf 'This is the disk the live system booted from.'
        return 0
    fi
    if [[ -n $root && $disk == "$root" ]]; then
        printf 'This is the disk containing the current root filesystem.'
        return 0
    fi
    local bytes
    bytes=$(lsblk -bndo SIZE "$disk" 2>/dev/null || true)
    core_is_uint "$bytes" || bytes=0
    if ((bytes < MIN_DISK_BYTES)); then
        printf 'Disk is smaller than %s.' "$(core_human_size "$MIN_DISK_BYTES")"
        return 0
    fi
    # Device-mapper, LVM, RAID and similar stacks expose holders in sysfs even
    # when lsblk types vary between versions.
    local disk_name=${disk#/dev/}
    local holder
    if [[ -d /sys/block/$disk_name/holders ]]; then
        for holder in /sys/block/"$disk_name"/holders/*; do
            [[ -e $holder ]] || continue
            printf 'Disk is in use by device %s.' "$(basename -- "$holder")"
            return 0
        done
    fi

    local live_label
    live_label=$(storage_live_iso_label)
    local line name type fstype mountpoints label
    while IFS= read -r line; do
        name=$(storage_lsblk_field "$line" NAME)
        type=$(storage_lsblk_field "$line" TYPE)
        fstype=$(storage_lsblk_field "$line" FSTYPE)
        mountpoints=$(storage_lsblk_field "$line" MOUNTPOINTS)
        label=$(storage_lsblk_field "$line" LABEL)
        if [[ -n $live_label && $label == "$live_label" ]]; then
            printf 'This is the live installation media (%s).' "$name"
            return 0
        fi
        # The disk itself is included on purpose: a whole-disk filesystem or
        # whole-disk swap must also block the operation.
        if [[ -n $mountpoints ]]; then
            printf 'The disk has a mounted partition %s.' "$name"
            return 0
        fi
        case $type in
            crypt|lvm|raid*|mpath|bcache)
                printf 'Disk is in use by device %s (%s).' "$name" "$type"
                return 0
                ;;
        esac
        if [[ $fstype == swap ]]; then
            printf 'Swap is active on the disk (%s).' "$name"
            return 0
        fi
    done < <(lsblk -P -o NAME,TYPE,FSTYPE,MOUNTPOINTS,LABEL "$disk" 2>/dev/null || true)
    return 0
}

storage_disk_is_safe() {
    local disk=$1
    [[ -z $(storage_disk_safety_problem "$disk") ]]
}

storage_validate_selected_disk() {
    [[ -n ${DISK:-} ]] || die "Target disk not selected."
    local problem
    problem=$(storage_disk_safety_problem "$DISK")
    [[ -z $problem ]] || die "Cannot use $DISK: $problem"
}

storage_select_disk() {
    local -a disks=()
    local -a menu=()
    local record path size model transport removable
    while IFS= read -r record; do
        [[ -n $record ]] || continue
        disks+=("$record")
        IFS=$'\t' read -r path size model transport removable <<<"$record"
        menu+=("$path" "$(storage_human_disk "$path" "$size" "$model" "$transport" "$removable")")
    done < <(storage_list_disks)

    ((${#menu[@]} > 0)) || die "No suitable disks found."

    local choice problem
    while true; do
        choice=$(ui_menu "Target disk" \
            "Choose a disk. It will be completely erased after confirmation." "${menu[@]}") ||
            die "Disk selection cancelled."
        problem=$(storage_disk_safety_problem "$choice")
        if [[ -n $problem ]]; then
            ui_error "Disk $choice is unavailable: $problem"
            continue
        fi
        DISK=$choice
        DISK_BYTES=$(lsblk -bndo SIZE "$DISK" 2>/dev/null || echo 0)
        core_is_uint "$DISK_BYTES" || DISK_BYTES=0
        break
    done

    storage_plan_layout
    ui_msg "The following disk will be used:\n\n$DISK\n$(core_human_size "$DISK_BYTES")\n\nEFI: $EFI_PART (${EFI_SIZE_MIB} MiB)\nRoot: $ROOT_PART ($(core_human_size "$((DISK_BYTES - EFI_SIZE_MIB * 1024 * 1024))"))\n\nAll data on the disk will be destroyed."

    ui_confirm "Continue with disk $DISK? All data will be permanently destroyed." ||
        die "Cancelled by the user."
    local answer
    answer=$(ui_input "Erase confirmation" "Type exactly: ERASE $DISK") ||
        die "Cancelled by the user."
    [[ $answer == "ERASE $DISK" ]] || die "Confirmation did not match."
}

storage_plan_layout() {
    [[ -n ${DISK:-} ]] || die "Target disk not selected."
    EFI_PART=$(storage_partition_name "$DISK" 1)
    ROOT_PART=$(storage_partition_name "$DISK" 2)
    core_is_uint "$DISK_BYTES" || DISK_BYTES=$(lsblk -bndo SIZE "$DISK" 2>/dev/null || echo 0)
    ((DISK_BYTES > 0)) || die "Could not determine the disk size."
}

storage_wait_for_partitions() {
    local attempt
    partprobe "$DISK" >/dev/null 2>&1 || true
    udevadm settle --timeout=15 >/dev/null 2>&1 || true
    for attempt in {1..20}; do
        debug "Waiting for partitions, attempt $attempt."
        if [[ -b $EFI_PART && -b $ROOT_PART ]]; then
            return 0
        fi
        core_sleep 1
        partprobe "$DISK" >/dev/null 2>&1 || true
        udevadm settle --timeout=5 >/dev/null 2>&1 || true
    done
    return 1
}

storage_partition_disk() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="partitioning"
    storage_validate_selected_disk
    storage_plan_layout
    info "Creating GPT on $DISK: EFI ${EFI_SIZE_MIB} MiB + root partition."

    wipefs -af "$DISK" || die "Could not wipe signatures on $DISK."
    sgdisk --zap-all "$DISK" || die "Could not wipe the partition table on $DISK."
    if ! sgdisk \
        --new=1:0:+"${EFI_SIZE_MIB}M" --typecode=1:ef00 --change-name=1:EFI \
        --new=2:0:0 --typecode=2:8300 --change-name=2:ARCHROOT \
        "$DISK"; then
        die "Could not create partitions on $DISK."
    fi

    storage_wait_for_partitions || die "Partitions did not appear: $EFI_PART / $ROOT_PART."
    [[ $(blkid -s PTTYPE -o value "$DISK" 2>/dev/null || true) == gpt ]] ||
        die "No GPT partition table found on $DISK."
    wipefs -a "$EFI_PART" "$ROOT_PART" >/dev/null 2>&1 || true
    sync
}

storage_make_filesystems() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="filesystems"
    storage_validate_selected_disk
    [[ -b $EFI_PART && -b $ROOT_PART ]] || die "Partitions not found."
    info "Formatting EFI partition $EFI_PART (FAT32)."
    mkfs.fat -F32 -n EFI "$EFI_PART" >/dev/null || die "Could not create FAT32 on the EFI partition."

    if [[ ${ENCRYPT:-0} == 1 ]]; then
        security_luks_create "$ROOT_PART"
        ROOT_DEV="/dev/mapper/$LUKS_NAME"
        [[ -n ${LUKS_UUID:-} ]] || die "Could not determine the LUKS UUID."
    else
        ROOT_DEV=$ROOT_PART
    fi

    info "Creating $FS_TYPE on $ROOT_DEV."
    case $FS_TYPE in
        ext4) mkfs.ext4 -F -L ARCHROOT "$ROOT_DEV" >/dev/null || die "Could not create ext4." ;;
        btrfs) mkfs.btrfs -f -L ARCHROOT "$ROOT_DEV" >/dev/null || die "Could not create Btrfs." ;;
        xfs) mkfs.xfs -f -L ARCHROOT "$ROOT_DEV" >/dev/null || die "Could not create XFS." ;;
        *) die "Unsupported filesystem: $FS_TYPE" ;;
    esac
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEV" 2>/dev/null || true)
    [[ -n $ROOT_UUID ]] || die "Could not determine the root filesystem UUID."
    sync
}

storage_root_mount_options() {
    case $FS_TYPE in
        btrfs) printf 'noatime,compress=zstd,subvol=%s' "$ROOT_SUBVOL" ;;
        *) printf 'noatime' ;;
    esac
}

storage_subvol_mount_options() {
    local subvol=$1
    printf 'noatime,compress=zstd,subvol=%s' "$subvol"
}

storage_mount_target() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="mounting"
    [[ -n ${ROOT_DEV:-} ]] || die "Root device is not defined."
    mkdir -p -- "$TARGET" || die "Could not create $TARGET."

    if [[ $FS_TYPE == btrfs ]]; then
        info "Creating Btrfs subvolumes."
        mount "$ROOT_DEV" "$TARGET" || die "Could not mount Btrfs to create subvolumes."
        MOUNTED_BY_US=1
        local subvol
        for subvol in @ @home @var_log @snapshots; do
            btrfs subvolume create "$TARGET/$subvol" || die "Could not create subvolume $subvol."
        done
        umount "$TARGET" || die "Could not unmount the Btrfs top level."
        MOUNTED_BY_US=0
        mount -o "$(storage_root_mount_options)" "$ROOT_DEV" "$TARGET" ||
            die "Could not mount the @ root subvolume."
        MOUNTED_BY_US=1
        mkdir -p "$TARGET/home" "$TARGET/var/log" "$TARGET/.snapshots" "$TARGET/boot"
        mount -o "$(storage_subvol_mount_options @home)" "$ROOT_DEV" "$TARGET/home" ||
            die "Could not mount @home."
        mount -o "$(storage_subvol_mount_options @var_log)" "$ROOT_DEV" "$TARGET/var/log" ||
            die "Could not mount @var_log."
        mount -o "$(storage_subvol_mount_options @snapshots)" "$ROOT_DEV" "$TARGET/.snapshots" ||
            die "Could not mount @snapshots."
    else
        mount -o noatime "$ROOT_DEV" "$TARGET" || die "Could not mount the root filesystem."
        MOUNTED_BY_US=1
        mkdir -p "$TARGET/boot"
    fi

    mount "$EFI_PART" "$TARGET/boot" || die "Could not mount the EFI partition at /boot."
    MOUNTED_BY_US=1
    mountpoint -q "$TARGET/boot" || die "The EFI partition is not mounted at $TARGET/boot."
    [[ $(blkid -s TYPE -o value "$EFI_PART" 2>/dev/null || true) == vfat ]] ||
        die "The EFI partition must use the vfat filesystem."
}

storage_generate_fstab() {
    # shellcheck disable=SC2034  # read by recovery.sh
    INSTALL_PHASE="fstab"
    genfstab -U "$TARGET" >"$TARGET/etc/fstab" || die "genfstab failed."
    validate_fstab "$TARGET/etc/fstab"
    info "fstab created and verified."
}

storage_unmount_target() {
    sync || true
    if ((MOUNTED_BY_US)) && mountpoint -q "$TARGET" 2>/dev/null; then
        info "Unmounting $TARGET."
        if ! umount -R "$TARGET"; then
            warn "Could not fully unmount $TARGET."
            return 1
        fi
    fi
    MOUNTED_BY_US=0
    if [[ ${ENCRYPT:-0} == 1 ]]; then
        security_luks_close
    fi
    return 0
}

storage_layout_text() {
    cat <<EOF
Disk:        $DISK ($(core_human_size "$DISK_BYTES"))
Layout:      GPT
EFI:         $EFI_PART, ${EFI_SIZE_MIB} MiB, FAT32, /boot
Root:        $ROOT_PART, $(core_human_size "$((DISK_BYTES - EFI_SIZE_MIB * 1024 * 1024))"), $FS_TYPE, /
Encryption:  $(if [[ ${ENCRYPT:-0} == 1 ]]; then echo "LUKS2 ($LUKS_NAME)"; else echo "no"; fi)
Btrfs:       $(if [[ $FS_TYPE == btrfs ]]; then echo "@, @home, @var_log, @snapshots, compress=zstd"; else echo "—"; fi)
EOF
}

storage_fs_packages() {
    case ${FS_TYPE:-ext4} in
        btrfs) printf 'btrfs-progs' ;;
        xfs) printf 'xfsprogs' ;;
        *) printf '' ;;
    esac
}
