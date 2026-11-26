#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034  # variables set here are consumed by configfile_load
# Unit tests for lib/configfile.sh (unattended installation configuration).

set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/configfile.sh
source "$ROOT/lib/configfile.sh"

test_configfile_parse_basic() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
[system]
hostname = myarch
username = testuser
zram = true

[install]
mode = minimal
kernel = linux-lts
filesystem = btrfs
encryption = false

[disk]
device = /dev/nvme0n1
efi_size_mib = 512

[packages]
extra = git vim htop

[network]
wifi_ssid = MyWiFi
wifi_password = secret
EOF

    local line
    local count=0
    while IFS=$'\t' read -r section key value; do
        count=$((count + 1))
    done < <(configfile_parse "$tmp")
    assert_eq "12" "$count" "parsed key/value pairs"
    rm -f "$tmp"
}

test_configfile_apply_values() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
[system]
hostname = myarch
username = testuser
timezone = UTC
locale = en_US.UTF-8
keymap = us
root_policy = locked
zram = false

[install]
mode = custom
desktop = kde
kernel = linux-lts
filesystem = xfs
encryption = true
luks_password = lukssecret
root_password = rootsecret
user_password = usersecret
efi_size_mib = 512

[disk]
device = /dev/nvme0n1

[packages]
extra = git vim

[network]
wifi_ssid = MyWiFi
wifi_password = wifi secret
EOF

    HOSTNAME=archlinux
    USERNAME=
    TIMEZONE=Europe/Prague
    LOCALE=en_US.UTF-8
    KEYMAP=us
    ROOT_POLICY=password
    ZRAM=0
    MODE=minimal
    DESKTOP=
    KERNEL=linux
    FS_TYPE=ext4
    ENCRYPT=0
    LUKS_PASSWORD=
    ROOT_PASSWORD=
    USER_PASSWORD=
    EFI_SIZE_MIB=1024
    DISK=
    EXTRA_PACKAGES=()
    CONFIG_WIFI_SSID=
    CONFIG_WIFI_PASSWORD=

    configfile_load "$tmp"

    assert_eq "myarch" "$HOSTNAME" "hostname"
    assert_eq "testuser" "$USERNAME" "username"
    assert_eq "UTC" "$TIMEZONE" "timezone"
    assert_eq "en_US.UTF-8" "$LOCALE" "locale"
    assert_eq "us" "$KEYMAP" "keymap"
    assert_eq "locked" "$ROOT_POLICY" "root_policy"
    assert_eq "0" "$ZRAM" "zram false"
    assert_eq "custom" "$MODE" "mode"
    assert_eq "kde" "$DESKTOP" "desktop"
    assert_eq "linux-lts" "$KERNEL" "kernel"
    assert_eq "xfs" "$FS_TYPE" "filesystem"
    assert_eq "1" "$ENCRYPT" "encryption true"
    assert_eq "lukssecret" "$LUKS_PASSWORD" "luks_password"
    assert_eq "rootsecret" "$ROOT_PASSWORD" "root_password"
    assert_eq "usersecret" "$USER_PASSWORD" "user_password"
    assert_eq "512" "$EFI_SIZE_MIB" "efi_size_mib"
    assert_eq "/dev/nvme0n1" "$DISK" "disk device"
    assert_eq "git vim" "${EXTRA_PACKAGES[*]}" "extra packages"
    assert_eq "MyWiFi" "$CONFIG_WIFI_SSID" "wifi ssid"
    assert_eq "wifi secret" "$CONFIG_WIFI_PASSWORD" "wifi password"
    rm -f "$tmp"
}

test_configfile_quotes_and_comments() {
    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
# This is a comment
[system] ; inline comment
hostname = "quoted value"
; another comment
username = testuser
EOF

    configfile_load "$tmp"
    assert_eq "quoted value" "$HOSTNAME" "quoted string"
    assert_eq "testuser" "$USERNAME" "username after comment section"
    rm -f "$tmp"
}

test_configfile_validate_required_missing() {
    # Unset required fields, expect die (non-zero exit).
    DISK='' MODE='' KERNEL='' FS_TYPE='' HOSTNAME='' USERNAME=''
    ENCRYPT=0 ROOT_PASSWORD='' USER_PASSWORD='' LUKS_PASSWORD=''
    assert_fails "configfile_validate_required exits non-zero" configfile_validate_required
}

test_configfile_validate_required_ok() {
    DISK=/dev/nvme0n1
    MODE=minimal
    KERNEL=linux
    FS_TYPE=ext4
    HOSTNAME=archlinux
    USERNAME=alice
    ENCRYPT=0
    ROOT_PASSWORD=rootsecret
    USER_PASSWORD=usersecret
    LUKS_PASSWORD=
    assert_true "configfile_validate_required passes" configfile_validate_required
}

run_test "configfile parse basic" test_configfile_parse_basic
run_test "configfile apply values" test_configfile_apply_values
run_test "configfile quotes and comments" test_configfile_quotes_and_comments
run_test "configfile validate required missing" test_configfile_validate_required_missing
run_test "configfile validate required ok" test_configfile_validate_required_ok
test_summary
