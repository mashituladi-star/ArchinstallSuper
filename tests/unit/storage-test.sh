#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/storage.sh
source "$ROOT/lib/storage.sh"

test_partition_names() {
    assert_eq "/dev/sda1" "$(storage_partition_name /dev/sda 1)" "SATA"
    assert_eq "/dev/vda2" "$(storage_partition_name /dev/vda 2)" "virtio"
    assert_eq "/dev/nvme0n1p1" "$(storage_partition_name /dev/nvme0n1 1)" "NVMe"
    assert_eq "/dev/mmcblk0p2" "$(storage_partition_name /dev/mmcblk0 2)" "eMMC"
    assert_eq "/dev/loop0p1" "$(storage_partition_name /dev/loop0 1)" "loop"
}

test_lsblk_parsing() {
    local line='NAME="sda" PATH="/dev/sda" SIZE="1000204886016" MODEL="Samsung SSD 970 EVO Plus 1TB" TYPE="disk" TRAN="nvme" RM="0" RO="0"'
    assert_eq "/dev/sda" "$(storage_lsblk_field "$line" PATH)" "path"
    assert_eq "1000204886016" "$(storage_lsblk_field "$line" SIZE)" "size"
    assert_eq "Samsung SSD 970 EVO Plus 1TB" "$(storage_lsblk_field "$line" MODEL)" "model with spaces"
    assert_eq "disk" "$(storage_lsblk_field "$line" TYPE)" "type"
    assert_eq "" "$(storage_lsblk_field "$line" MISSING)" "missing field"
}

test_mount_options() {
    FS_TYPE=ext4
    assert_eq "noatime" "$(storage_root_mount_options)" "ext4 options"
    FS_TYPE=xfs
    assert_eq "noatime" "$(storage_root_mount_options)" "xfs options"
    FS_TYPE=btrfs
    ROOT_SUBVOL=@
    assert_eq "noatime,compress=zstd,subvol=@" "$(storage_root_mount_options)" "btrfs options"
    assert_eq "noatime,compress=zstd,subvol=@home" "$(storage_subvol_mount_options @home)" "btrfs home"
}

test_fs_packages() {
    FS_TYPE=ext4
    assert_eq "" "$(storage_fs_packages)" "ext4 needs no extra package"
    FS_TYPE=btrfs
    assert_eq "btrfs-progs" "$(storage_fs_packages)" "btrfs tools"
    FS_TYPE=xfs
    assert_eq "xfsprogs" "$(storage_fs_packages)" "xfs tools"
}

test_unsafe_device() {
    assert_contains "$(storage_disk_safety_problem /dev/null)" "блочное" "character device must be rejected"
    assert_false "character device is not safe" storage_disk_is_safe /dev/null
}

test_safety_rejects_mounted_disk() {
    storage_is_block_device() { return 0; }
    findmnt() { return 1; }
    storage_live_iso_label() { printf ''; }
    lsblk() {
        case "$*" in
            *'-bndo SIZE'*) printf '100000000000\n' ;;
            *'-P -o NAME,TYPE,FSTYPE,MOUNTPOINTS'*)
                printf 'NAME="sdz" TYPE="disk" FSTYPE="" MOUNTPOINTS=""\n'
                printf 'NAME="sdz1" TYPE="part" FSTYPE="ext4" MOUNTPOINTS="/mnt"\n'
                ;;
            *) return 1 ;;
        esac
    }
    assert_contains "$(storage_disk_safety_problem /dev/sdz)" "смонтирован" "mounted partition"
    assert_false "mounted disk is not safe" storage_disk_is_safe /dev/sdz
}

test_safety_rejects_active_stack() {
    storage_is_block_device() { return 0; }
    findmnt() { return 1; }
    storage_live_iso_label() { printf ''; }
    lsblk() {
        case "$*" in
            *'-bndo SIZE'*) printf '100000000000\n' ;;
            *'-P -o NAME,TYPE,FSTYPE,MOUNTPOINTS'*)
                printf 'NAME="sdz" TYPE="disk" FSTYPE="" MOUNTPOINTS=""\n'
                printf 'NAME="sdz1" TYPE="crypt" FSTYPE="ext4" MOUNTPOINTS=""\n'
                ;;
            *) return 1 ;;
        esac
    }
    assert_contains "$(storage_disk_safety_problem /dev/sdz)" "устройством" "active crypt"
}

test_safety_rejects_swap() {
    storage_is_block_device() { return 0; }
    findmnt() { return 1; }
    storage_live_iso_label() { printf ''; }
    lsblk() {
        case "$*" in
            *'-bndo SIZE'*) printf '100000000000\n' ;;
            *'-P -o NAME,TYPE,FSTYPE,MOUNTPOINTS'*)
                printf 'NAME="sdz" TYPE="disk" FSTYPE="" MOUNTPOINTS=""\n'
                printf 'NAME="sdz1" TYPE="part" FSTYPE="swap" MOUNTPOINTS=""\n'
                ;;
            *) return 1 ;;
        esac
    }
    assert_contains "$(storage_disk_safety_problem /dev/sdz)" "swap" "active swap"
}

test_safety_rejects_live_media() {
    storage_is_block_device() { return 0; }
    findmnt() { return 1; }
    storage_live_iso_label() { printf 'ARCH_TEST'; }
    lsblk() {
        case "$*" in
            *'-bndo SIZE'*) printf '100000000000\n' ;;
            *'-P -o NAME,TYPE,FSTYPE,MOUNTPOINTS,LABEL'*)
                printf 'NAME="sdz" TYPE="disk" FSTYPE="" MOUNTPOINTS="" LABEL=""\n'
                printf 'NAME="sdz1" TYPE="part" FSTYPE="iso9660" MOUNTPOINTS="" LABEL="ARCH_TEST"\n'
                ;;
            *) return 1 ;;
        esac
    }
    assert_contains "$(storage_disk_safety_problem /dev/sdz)" "live" "live install medium"
}

test_safety_accepts_idle_disk() {
    storage_is_block_device() { return 0; }
    findmnt() { return 1; }
    storage_live_iso_label() { printf ''; }
    lsblk() {
        case "$*" in
            *'-bndo SIZE'*) printf '100000000000\n' ;;
            *'-P -o NAME,TYPE,FSTYPE,MOUNTPOINTS'*)
                printf 'NAME="sdz" TYPE="disk" FSTYPE="" MOUNTPOINTS=""\n'
                printf 'NAME="sdz1" TYPE="part" FSTYPE="ext4" MOUNTPOINTS=""\n'
                ;;
            *) return 1 ;;
        esac
    }
    assert_eq "" "$(storage_disk_safety_problem /dev/sdz)" "idle disk is safe"
    assert_true "idle disk passes" storage_disk_is_safe /dev/sdz
}

test_layout_text() {
    DISK=/dev/vda
    DISK_BYTES=$((30 * 1024 * 1024 * 1024))
    EFI_PART=/dev/vda1
    ROOT_PART=/dev/vda2
    FS_TYPE=btrfs
    ENCRYPT=1
    LUKS_NAME=cryptroot
    local text
    text=$(storage_layout_text)
    assert_contains "$text" "GPT" "GPT"
    assert_contains "$text" "/dev/vda1" "EFI partition"
    assert_contains "$text" "LUKS2" "encryption"
    assert_contains "$text" "@snapshots" "subvolumes"
}

run_test "partition naming" test_partition_names
run_test "lsblk field parsing" test_lsblk_parsing
run_test "mount options" test_mount_options
run_test "filesystem packages" test_fs_packages
run_test "unsafe device rejection" test_unsafe_device
run_test "safety: mounted disk" test_safety_rejects_mounted_disk
run_test "safety: active device stack" test_safety_rejects_active_stack
run_test "safety: active swap" test_safety_rejects_swap
run_test "safety: live install medium" test_safety_rejects_live_media
run_test "safety: idle disk" test_safety_accepts_idle_disk
run_test "layout summary" test_layout_text
test_summary
