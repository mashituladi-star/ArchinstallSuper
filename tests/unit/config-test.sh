#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/validate.sh
source "$ROOT/lib/validate.sh"
# shellcheck source=../../lib/config.sh
source "$ROOT/lib/config.sh"

test_hosts() {
    local content
    content=$(config_hosts_content archlinux)
    assert_contains "$content" "127.0.0.1 localhost" "localhost"
    assert_contains "$content" "127.0.1.1 archlinux.localdomain archlinux" "hostname mapping"
}

test_locale_files() {
    assert_eq "LANG=en_US.UTF-8" "$(config_locale_conf_content en_US.UTF-8)" "locale.conf"
    assert_eq "KEYMAP=us" "$(config_vconsole_content us)" "vconsole.conf"
}

test_zram() {
    local content
    content=$(config_zram_content)
    assert_contains "$content" "[zram0]" "zram section"
    assert_contains "$content" "min(ram / 2, 4096)" "size formula"
    assert_contains "$content" "compression-algorithm = zstd" "zstd"
}

test_sudoers() {
    assert_contains "$(config_sudoers_content)" "%wheel ALL=(ALL:ALL) ALL" "wheel sudo"
}

test_desktop_services() {
    assert_eq "gdm" "$(config_desktop_service gnome)" "gnome"
    assert_eq "sddm" "$(config_desktop_service kde)" "kde"
    assert_eq "lightdm" "$(config_desktop_service xfce)" "xfce"
    assert_eq "lightdm" "$(config_desktop_service cinnamon)" "cinnamon"
    assert_eq "" "$(config_desktop_service '')" "console"
}

test_no_secrets_in_generated_files() {
    local content
    content="$(config_hosts_content archlinux)$(config_locale_conf_content en_US.UTF-8)$(config_zram_content)$(config_sudoers_content)"
    assert_not_contains "$content" "PASSWORD" "no password marker"
    assert_not_contains "$content" "LUKS" "no LUKS secret"
}

test_services() {
    local log="$TEMP_DIR/services.log"
    : >"$log"
    arch-chroot() { printf '%s\n' "$*" >>"$log"; }
    PACKAGES=(base chrony)
    config_configure_services
    assert_file_contains "$log" "systemctl enable NetworkManager" "NetworkManager"
    assert_file_contains "$log" "systemctl enable fstrim.timer" "fstrim"
    assert_not_contains "$(cat "$log")" "systemd-timesyncd" "chrony must suppress timesyncd"

    : >"$log"
    PACKAGES=(base)
    config_configure_services
    assert_file_contains "$log" "systemctl enable systemd-timesyncd" "timesyncd"
}

test_sudoers_file() {
    TARGET=$(mktemp -d "$TEMP_DIR/target.XXXXXX")
    arch-chroot() { return 0; }
    config_write_sudoers
    assert_file_contains "$TARGET/etc/sudoers.d/10-wheel" "%wheel ALL=(ALL:ALL) ALL" "sudoers rule"
    assert_eq "440" "$(stat -c '%a' "$TARGET/etc/sudoers.d/10-wheel")" "sudoers mode"
    rm -rf "$TARGET"
}

run_test "hosts file" test_hosts
run_test "locale files" test_locale_files
run_test "zram configuration" test_zram
run_test "sudoers configuration" test_sudoers
run_test "desktop services" test_desktop_services
run_test "no secrets in generated files" test_no_secrets_in_generated_files
run_test "service enablement" test_services
run_test "sudoers file" test_sudoers_file
test_summary
