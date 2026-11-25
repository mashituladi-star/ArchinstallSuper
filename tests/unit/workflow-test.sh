#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/validate.sh
source "$ROOT/lib/validate.sh"
# shellcheck source=../../lib/security.sh
source "$ROOT/lib/security.sh"
# shellcheck source=../../lib/storage.sh
source "$ROOT/lib/storage.sh"
# shellcheck source=../../lib/hardware.sh
source "$ROOT/lib/hardware.sh"
# shellcheck source=../../lib/workflow.sh
source "$ROOT/lib/workflow.sh"

test_minimal_package_set() {
    MODE=minimal
    DESKTOP=
    KERNEL=linux
    FS_TYPE=btrfs
    ZRAM=1
    ENCRYPT=1
    EXTRA_PACKAGES=(htop)
    hw_detect_cpu
    workflow_build_packages
    assert_contains " ${PACKAGES[*]} " " base " "base"
    assert_contains " ${PACKAGES[*]} " " linux " "kernel"
    assert_contains " ${PACKAGES[*]} " " btrfs-progs " "btrfs tools"
    assert_contains " ${PACKAGES[*]} " " zram-generator " "zram"
    assert_contains " ${PACKAGES[*]} " " cryptsetup " "cryptsetup"
    assert_contains " ${PACKAGES[*]} " " htop " "extra package"
    local first second
    first=$(printf '%s\n' "${PACKAGES[@]}" | sort | uniq -d)
    assert_eq "" "$first" "no duplicate packages"
}

test_summary_contains_safety_warning() {
    MODE=minimal
    DESKTOP=
    KERNEL=linux
    FS_TYPE=ext4
    ZRAM=0
    ENCRYPT=0
    DISK=/dev/vda
    DISK_BYTES=$((30 * 1024 * 1024 * 1024))
    EFI_PART=/dev/vda1
    ROOT_PART=/dev/vda2
    HOSTNAME=archlinux
    USERNAME=alice
    ROOT_POLICY=locked
    TIMEZONE=UTC
    LOCALE=en_US.UTF-8
    KEYMAP=us
    HW_SECURE_BOOT=выключен
    PACKAGES=(base linux)
    local text
    text=$(workflow_summary_text)
    assert_contains "$text" "все данные" "data-loss warning"
    assert_contains "$text" "заблокирован" "root policy"
    assert_contains "$text" "/dev/vda" "disk"
    assert_contains "$text" "Secure Boot" "secure boot state"
}

test_execute_order() {
    local log="$TEMP_DIR/order.log"
    : >"$log"
    storage_partition_disk() { printf 'partition\n' >>"$log"; }
    storage_make_filesystems() { printf 'mkfs\n' >>"$log"; }
    storage_mount_target() { printf 'mount\n' >>"$log"; }
    install_pacstrap() { printf 'pacstrap\n' >>"$log"; }
    storage_generate_fstab() { printf 'fstab\n' >>"$log"; }
    config_apply_all() { printf 'config\n' >>"$log"; }
    boot_apply_all() { printf 'boot\n' >>"$log"; }
    install_copy_log() { printf 'log\n' >>"$log"; }
    install_verify() { printf 'verify\n' >>"$log"; }
    storage_unmount_target() { printf 'unmount\n' >>"$log"; return 0; }
    plugin_hook() { printf 'plugin-%s\n' "$1" >>"$log"; }

    workflow_execute
    local expected actual
    expected=$'plugin-pre_install\npartition\nmkfs\nmount\npacstrap\nfstab\nconfig\nboot\nverify\nlog\nplugin-post_install\nunmount\nplugin-pre_reboot'
    actual=$(cat "$log")
    assert_eq "$expected" "$actual" "installation order"
    assert_eq "1" "$INSTALL_COMPLETE" "completion flag"
}

run_test "minimal package set" test_minimal_package_set
run_test "summary warning" test_summary_contains_safety_warning
run_test "installation order" test_execute_order
test_summary
