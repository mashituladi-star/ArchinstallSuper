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
# shellcheck source=../../lib/boot.sh
source "$ROOT/lib/boot.sh"

setup_target() {
    TARGET=$(mktemp -d "$TEMP_DIR/boot.XXXXXX")
    mkdir -p "$TARGET/boot"
}

test_kernel_args_ext4() {
    ENCRYPT=0
    FS_TYPE=ext4
    ROOT_UUID=1111-2222
    assert_eq "root=UUID=1111-2222 rw" "$(boot_kernel_args)" "ext4 args"
}

test_kernel_args_btrfs() {
    ENCRYPT=0
    FS_TYPE=btrfs
    ROOT_UUID=1111-2222
    assert_eq "root=UUID=1111-2222 rw rootflags=subvol=@,compress=zstd" "$(boot_kernel_args)" "btrfs args"
}

test_kernel_args_luks() {
    ENCRYPT=1
    FS_TYPE=btrfs
    LUKS_UUID=aaaa-bbbb
    LUKS_NAME=cryptroot
    ROOT_UUID=fs-uuid
    local args
    args=$(boot_kernel_args)
    assert_contains "$args" "cryptdevice=UUID=aaaa-bbbb:cryptroot" "cryptdevice"
    assert_contains "$args" "root=/dev/mapper/cryptroot" "mapper root"
    assert_contains "$args" "rootflags=subvol=@" "btrfs rootflags"
}

test_entry_content() {
    ENCRYPT=0
    FS_TYPE=btrfs
    ROOT_UUID=1111-2222
    KERNEL=linux
    UCODE_IMAGES=(intel-ucode.img)
    local entry
    entry=$(boot_entry_content linux)
    assert_contains "$entry" "linux /vmlinuz-linux" "kernel"
    assert_contains "$entry" "initrd /intel-ucode.img" "ucode"
    assert_contains "$entry" "initrd /initramfs-linux.img" "initramfs"
    assert_contains "$entry" "rootflags=subvol=@" "btrfs flag"
    assert_contains "$entry" "root=UUID=1111-2222" "root uuid"
}

test_entry_lts_luks() {
    ENCRYPT=1
    FS_TYPE=ext4
    LUKS_UUID=luks-uuid
    LUKS_NAME=cryptroot
    KERNEL=linux-lts
    UCODE_IMAGES=()
    local entry
    entry=$(boot_entry_content linux-lts)
    assert_contains "$entry" "linux /vmlinuz-linux-lts" "lts kernel"
    assert_contains "$entry" "cryptdevice=UUID=luks-uuid:cryptroot" "luks"
    assert_not_contains "$entry" "intel-ucode" "no ucode"
}

test_hooks() {
    assert_eq "base udev encrypt filesystems fsck" \
        "$(boot_hooks_with_encrypt 'base udev filesystems fsck')" "insert encrypt before filesystems"
    assert_eq "base udev encrypt filesystems" \
        "$(boot_hooks_with_encrypt 'base udev encrypt filesystems')" "do not duplicate encrypt"
    assert_eq "base udev encrypt" \
        "$(boot_hooks_with_encrypt 'base udev')" "fallback append"
}

test_modules() {
    assert_eq "btrfs" "$(boot_modules_with_fs '' btrfs)" "empty modules"
    assert_eq "ext4 btrfs" "$(boot_modules_with_fs ext4 btrfs)" "append module"
    assert_eq "btrfs ext4" "$(boot_modules_with_fs 'btrfs ext4' btrfs)" "already present"
}

test_ucode_detection() {
    setup_target
    touch "$TARGET/boot/intel-ucode.img" "$TARGET/boot/amd-ucode.img"
    boot_collect_ucode
    assert_eq "2" "${#UCODE_IMAGES[@]}" "both ucode images"
    rm -rf "$TARGET"
}

test_loader_conf() {
    local conf
    conf=$(boot_loader_conf_content)
    assert_contains "$conf" "default archinstall-super.conf" "default entry"
    assert_contains "$conf" "editor no" "editor disabled"
    assert_contains "$conf" "timeout 3" "timeout"
}

test_initramfs_editing() {
    setup_target
    mkdir -p "$TARGET/etc"
    cat >"$TARGET/etc/mkinitcpio.conf" <<'EOF'
MODULES=()
HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)
EOF
    FS_TYPE=btrfs
    ENCRYPT=1
    local chroot_log="$TEMP_DIR/chroot.log"
    : >"$chroot_log"
    arch-chroot() { printf '%s\n' "$*" >>"$chroot_log"; }
    boot_configure_initramfs
    assert_file_contains "$TARGET/etc/mkinitcpio.conf" "HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)" "encrypt hook"
    assert_file_contains "$TARGET/etc/mkinitcpio.conf" "MODULES=(btrfs)" "btrfs module"
    assert_file_contains "$chroot_log" "mkinitcpio -P" "initramfs regenerated"
    rm -rf "$TARGET"
}

test_entry_written_to_target() {
    setup_target
    ENCRYPT=0
    FS_TYPE=ext4
    ROOT_UUID=1111-2222
    KERNEL=linux
    UCODE_IMAGES=()
    boot_write_loader_conf
    boot_write_entry
    assert_file_contains "$TARGET/boot/loader/entries/archinstall-super.conf" "root=UUID=1111-2222" "root uuid"
    assert_file_contains "$TARGET/boot/loader/loader.conf" "editor no" "editor disabled"
    rm -rf "$TARGET"
}

run_test "ext4 kernel args" test_kernel_args_ext4
run_test "btrfs kernel args" test_kernel_args_btrfs
run_test "LUKS kernel args" test_kernel_args_luks
run_test "boot entry content" test_entry_content
run_test "LTS + LUKS entry" test_entry_lts_luks
run_test "mkinitcpio hooks" test_hooks
run_test "mkinitcpio modules" test_modules
run_test "ucode detection" test_ucode_detection
run_test "loader.conf" test_loader_conf
run_test "initramfs editing" test_initramfs_editing
run_test "entry written to target" test_entry_written_to_target
test_summary
