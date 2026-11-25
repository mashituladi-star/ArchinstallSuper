#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=../lib/harness.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/../lib/harness.sh"
# shellcheck source=../../lib/core.sh
source "$ROOT/lib/core.sh"

test_human_size() {
    assert_eq "512 B" "$(core_human_size 512)" "bytes"
    assert_eq "1.0 KiB" "$(core_human_size 1024)" "kib"
    assert_eq "1.0 MiB" "$(core_human_size 1048576)" "mib"
    assert_eq "1.5 GiB" "$(core_human_size 1610612736)" "gib"
    assert_eq "0 B" "$(core_human_size not-a-number)" "invalid input"
}

test_bytes_from_size() {
    assert_eq "1024" "$(core_bytes_from_size '1 KiB')" "KiB"
    assert_eq "1572864" "$(core_bytes_from_size '1.5 MiB')" "MiB"
    assert_eq "1610612736" "$(core_bytes_from_size '1.5 GiB')" "GiB"
    assert_false "invalid unit must fail" core_bytes_from_size '12 bananas'
}

test_package_names() {
    assert_true "valid package" core_validate_package_name 'python-pip'
    assert_true "valid package with plus" core_validate_package_name 'gtk+'
    assert_false "space is invalid" core_validate_package_name 'bad package'
    assert_false "slash is invalid" core_validate_package_name '../evil'
    assert_false "empty is invalid" core_validate_package_name ''
}

test_join_and_dedupe() {
    assert_eq "a, b, c" "$(core_join_by ', ' a b c)" "join"
    local -a values=(a b a c b)
    core_dedupe_array values
    assert_eq "a b c" "${values[*]}" "dedupe preserves order"
}

test_trim_and_uint() {
    assert_eq "hello" "$(core_trim '  hello  ')" "trim"
    assert_true "uint" core_is_uint 123
    assert_false "negative is not uint" core_is_uint -1
    assert_false "text is not uint" core_is_uint abc
}

run_test "human size formatting" test_human_size
run_test "size parsing" test_bytes_from_size
run_test "package name validation" test_package_names
run_test "array helpers" test_join_and_dedupe
run_test "trim and integer helpers" test_trim_and_uint
test_summary
