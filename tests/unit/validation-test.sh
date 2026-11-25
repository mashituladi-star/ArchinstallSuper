#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/validate.sh
source "$ROOT/lib/validate.sh"

test_hostname() {
    assert_true "simple hostname" validate_hostname archlinux
    assert_true "hyphenated hostname" validate_hostname arch-home
    assert_false "underscore is invalid" validate_hostname arch_home
    assert_false "leading hyphen is invalid" validate_hostname -arch
    assert_false "trailing hyphen is invalid" validate_hostname arch-
    assert_false "empty is invalid" validate_hostname ''
}

test_username() {
    assert_true "normal user" validate_username dima
    assert_true "underscore user" validate_username _service
    assert_false "uppercase is invalid" validate_username Dima
    assert_false "root is reserved" validate_username root
    assert_false "leading digit is invalid" validate_username 1dima
    assert_false "empty is invalid" validate_username ''
}

test_timezone() {
    assert_true "UTC" validate_timezone UTC
    assert_true "regional zone" validate_timezone Europe/Prague
    assert_false "traversal" validate_timezone '../etc/passwd'
    assert_false "unknown zone" validate_timezone Nope/Nope
    assert_false "empty" validate_timezone ''
}

test_locale() {
    assert_true "en_US" validate_locale en_US.UTF-8
    assert_false "missing locale" validate_locale xx_XX.UTF-8
    assert_false "bad format" validate_locale en_US
    assert_false "empty" validate_locale ''
}

test_keymap() {
    assert_true "us keymap" validate_keymap us
    assert_false "traversal keymap" validate_keymap '../evil'
    assert_false "unknown keymap" validate_keymap zz
    assert_false "empty" validate_keymap ''
}

test_passwords() {
    assert_true "reasonable password" validate_password 'CorrectHorse42' alice archlinux
    assert_false "too short" validate_password 'short' alice archlinux
    assert_false "colon is rejected" validate_password 'Good:Pass123' alice archlinux
    assert_false "username is rejected" validate_password 'aliceuser' aliceuser archlinux
    assert_false "hostname is rejected" validate_password 'archlinux' alice archlinux
    assert_false "common password" validate_password 'password' alice archlinux
    assert_false "empty password" validate_password '' alice archlinux
}

test_package_name() {
    assert_true "normal package" validate_package_name 'linux-lts'
    assert_false "space" validate_package_name 'bad package'
    assert_false "empty" validate_package_name ''
}

test_fstab() {
    local file="$TEMP_DIR/fstab"
    cat >"$file" <<'EOF'
UUID=1111 / ext4 rw,relatime 0 1
UUID=2222 /boot vfat rw,relatime 0 2
EOF
    assert_true "valid ext4 fstab" validate_fstab "$file"

    cat >"$file" <<'EOF'
UUID=1111 / btrfs rw,relatime,subvol=@ 0 0
UUID=2222 /boot vfat rw,relatime 0 2
EOF
    FS_TYPE=btrfs
    assert_true "valid btrfs fstab" validate_fstab "$file"

    cat >"$file" <<'EOF'
UUID=1111 / btrfs rw,relatime,subvol=/@ 0 0
UUID=2222 /boot vfat rw,relatime 0 2
EOF
    assert_true "genfstab-style subvol=/@ is accepted" validate_fstab "$file"

    cat >"$file" <<'EOF'
UUID=1111 / btrfs rw,relatime,subvol=/@home 0 0
UUID=2222 /boot vfat rw,relatime 0 2
EOF
    assert_fails "subvol=/@home must not satisfy the root check" validate_fstab "$file"

    cat >"$file" <<'EOF'
UUID=1111 / btrfs rw,relatime 0 0
UUID=2222 /boot vfat rw,relatime 0 2
EOF
    assert_fails "btrfs fstab without subvol" validate_fstab "$file"

    cat >"$file" <<'EOF'
tmpfs / tmpfs rw 0 0
UUID=2222 /boot vfat rw,relatime 0 2
EOF
    assert_fails "volatile root must be rejected" validate_fstab "$file"

    printf 'UUID=1111 / ext4 rw 0 1\n' >"$file"
    assert_fails "fstab without /boot" validate_fstab "$file"
}

test_btrfs_root_flag_helper() {
    local file="$TEMP_DIR/boot-entry"
    printf 'options root=UUID=1111 rw rootflags=subvol=@,compress=zstd\n' >"$file"
    assert_true "kernel-argument form" validate_btrfs_root_flag "$file"
    printf 'options root=UUID=1111 rw rootflags=subvol=/@\n' >"$file"
    assert_true "kernel-argument form with slash" validate_btrfs_root_flag "$file"
    printf 'options root=UUID=1111 rw rootflags=subvol=/@home\n' >"$file"
    assert_false "home subvolume must not match" validate_btrfs_root_flag "$file"
}

run_test "hostname validation" test_hostname
run_test "username validation" test_username
run_test "timezone validation" test_timezone
run_test "locale validation" test_locale
run_test "keymap validation" test_keymap
run_test "password validation" test_passwords
run_test "package name validation" test_package_name
run_test "fstab validation" test_fstab
run_test "Btrfs root flag helper" test_btrfs_root_flag_helper
test_summary
