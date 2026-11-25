#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are consumed by sourced modules
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/storage.sh
source "$ROOT/lib/storage.sh"
# shellcheck source=../../lib/security.sh
source "$ROOT/lib/security.sh"
# shellcheck source=../../lib/recovery.sh
source "$ROOT/lib/recovery.sh"

test_failure_before_install() {
    local log="$TEMP_DIR/recovery-before.log"
    : >"$log"
    warn() { printf 'WARN:%s\n' "$*" >>"$log"; }
    install_copy_log() { printf 'copy\n' >>"$log"; }
    storage_unmount_target() { printf 'umount\n' >>"$log"; return 0; }
    security_luks_close() { printf 'close\n' >>"$log"; }
    TEMP_DIR="$TEMP_DIR/recovery-before"
    mkdir -p "$TEMP_DIR"
    INSTALL_STARTED=0
    MOUNTED_BY_US=0
    LUKS_OPENED=0
    INSTALL_PHASE=
    recovery_cleanup 1
    assert_file_contains "$log" "Диск не изменялся" "no disk changes yet"
    assert_not_contains "$(cat "$log")" "umount" "must not unmount before install"
}

test_failure_during_install() {
    local log="$TEMP_DIR/recovery-during.log"
    : >"$log"
    warn() { printf 'WARN:%s\n' "$*" >>"$log"; }
    install_copy_log() { printf 'copy\n' >>"$log"; }
    storage_unmount_target() { printf 'umount\n' >>"$log"; MOUNTED_BY_US=0; return 0; }
    security_luks_close() { printf 'close\n' >>"$log"; }
    TEMP_DIR="$TEMP_DIR/recovery-during"
    mkdir -p "$TEMP_DIR"
    INSTALL_STARTED=1
    MOUNTED_BY_US=1
    LUKS_OPENED=0
    INSTALL_PHASE=partitioning
    recovery_cleanup 1
    assert_file_contains "$log" "copy" "log copied"
    assert_file_contains "$log" "umount" "target unmounted"
    assert_file_contains "$log" "partitioning" "failed phase reported"
}

test_failure_closes_open_luks() {
    local log="$TEMP_DIR/recovery-luks.log"
    : >"$log"
    warn() { printf 'WARN:%s\n' "$*" >>"$log"; }
    install_copy_log() { printf 'copy\n' >>"$log"; }
    storage_unmount_target() { printf 'umount\n' >>"$log"; return 0; }
    security_luks_close() { printf 'close\n' >>"$log"; LUKS_OPENED=0; }
    mountpoint() { return 1; }
    TEMP_DIR="$TEMP_DIR/recovery-luks"
    mkdir -p "$TEMP_DIR"
    INSTALL_STARTED=1
    MOUNTED_BY_US=0
    LUKS_OPENED=1
    INSTALL_PHASE=filesystems
    recovery_cleanup 1
    assert_file_contains "$log" "close" "open LUKS container closed"
}

test_success_unmounts() {
    local log="$TEMP_DIR/recovery-success.log"
    : >"$log"
    warn() { printf 'WARN:%s\n' "$*" >>"$log"; }
    storage_unmount_target() { printf 'umount\n' >>"$log"; return 0; }
    TEMP_DIR="$TEMP_DIR/recovery-success"
    mkdir -p "$TEMP_DIR"
    INSTALL_STARTED=1
    MOUNTED_BY_US=1
    LUKS_OPENED=0
    recovery_cleanup 0
    assert_file_contains "$log" "umount" "success also unmounts"
}

run_test "failure before install" test_failure_before_install
run_test "failure during install" test_failure_during_install
run_test "failure closes LUKS" test_failure_closes_open_luks
run_test "success unmounts" test_success_unmounts
test_summary
