#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"

test_version() {
    local output
    output=$(bash "$ROOT/install.sh" --version)
    assert_contains "$output" "ArchinstallSuper" "product name"
    assert_contains "$output" "0.10.0" "version"
}

test_help() {
    local output
    output=$(bash "$ROOT/install.sh" --help)
    assert_contains "$output" "--check" "check option"
    assert_contains "$output" "--dry-run" "dry-run option"
    assert_contains "$output" "UEFI" "UEFI"
    assert_contains "$output" "archinstall" "independence statement"
}

test_unknown_argument() {
    local status=0
    bash "$ROOT/install.sh" --definitely-not-an-option >/dev/null 2>&1 || status=$?
    assert_eq "2" "$status" "unknown argument exit code"
}

test_no_archinstall_invocation() {
    local matches
    matches=$(grep -RInE --include='*.sh' '(^[[:space:]]*(sudo[[:space:]]+)?archinstall([[:space:]]|$))|([;&|][[:space:]]*archinstall([[:space:]]|$))|(pacman[^#]*[[:space:]]archinstall([[:space:]]|$))' \
        "$ROOT/install.sh" "$ROOT/lib" || true)
    assert_eq "" "$matches" "no archinstall invocation"
}

test_no_old_dialog_output_fd() {
    local matches
    matches=$(grep -RIn --include='*.sh' -- '--output-fd 3' "$ROOT/install.sh" "$ROOT/lib" || true)
    assert_eq "" "$matches" "dialog must use --stdout for captured values"
}

test_shell_syntax() {
    local file
    for file in "$ROOT"/install.sh "$ROOT"/lib/*.sh; do
        assert_true "syntax $file" bash -n "$file"
    done
}

run_test "version output" test_version
run_test "help output" test_help
run_test "unknown argument" test_unknown_argument
run_test "no archinstall invocation" test_no_archinstall_invocation
run_test "no broken dialog output fd" test_no_old_dialog_output_fd
run_test "shell syntax" test_shell_syntax
test_summary
