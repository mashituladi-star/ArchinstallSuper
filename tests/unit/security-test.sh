#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"
# shellcheck source=../../lib/validate.sh
source "$ROOT/lib/validate.sh"
# shellcheck source=../../lib/security.sh
source "$ROOT/lib/security.sh"

test_luks_boot_args() {
    local args
    args=$(security_luks_boot_args 'aaaa-bbbb' cryptroot)
    assert_contains "$args" "cryptdevice=UUID=aaaa-bbbb:cryptroot" "cryptdevice"
    assert_contains "$args" "root=/dev/mapper/cryptroot" "mapper root"
    assert_contains "$args" " rw" "rw"
}

test_password_problems() {
    local problem
    problem=$(security_password_problem 'short' alice archlinux)
    assert_contains "$problem" "8" "short password"

    problem=$(security_password_problem 'CorrectHorse42' alice archlinux)
    assert_eq "" "$problem" "strong password has no problem"

    problem=$(security_password_problem 'with:colon123' alice archlinux)
    assert_contains "$problem" "colon" "colon"

    problem=$(security_password_problem 'aliceuser' aliceuser archlinux)
    assert_contains "$problem" "user name" "username reuse"
}

test_forget_passwords() {
    ROOT_PASSWORD=secret
    USER_PASSWORD=secret
    LUKS_PASSWORD=secret
    security_forget_passwords
    assert_eq "" "${ROOT_PASSWORD:-}" "root password cleared"
    assert_eq "" "${USER_PASSWORD:-}" "user password cleared"
    assert_eq "" "${LUKS_PASSWORD:-}" "luks password cleared"
}

run_test "LUKS boot arguments" test_luks_boot_args
run_test "password policy" test_password_problems
run_test "password memory cleanup" test_forget_passwords
test_summary
