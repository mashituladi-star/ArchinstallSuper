#!/usr/bin/env bash
# shellcheck shell=bash
# Tiny assertion harness for ArchinstallSuper unit tests.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
export ROOT
export AS_TEST=1
export AS_LOG_TO_FILE=0
export UI_MODE=plain
export UI_TTY_FD=4
export TARGET="${TARGET:-$ROOT/.test-target}"
export TEMP_DIR="${TEMP_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/as-test.XXXXXX")}"
export LOG_FILE="${LOG_FILE:-$TEMP_DIR/test.log}"

# The UI writes to fd 4. Keep test output clean while still exercising the
# real redirection path.
exec 4>/dev/null

TESTS_RUN=0
TESTS_FAILED=0

fail() {
    printf '  FAIL: %s\n' "$*" >&2
    return 1
}

assert_eq() {
    local expected=$1
    local actual=$2
    local label=${3:-values differ}
    if [[ $expected != "$actual" ]]; then
        fail "$label: expected [$expected], got [$actual]"
        return 1
    fi
}

assert_ne() {
    local unexpected=$1
    local actual=$2
    local label=${3:-values should differ}
    if [[ $unexpected == "$actual" ]]; then
        fail "$label: both are [$actual]"
        return 1
    fi
}

assert_contains() {
    local haystack=$1
    local needle=$2
    local label=${3:-substring missing}
    if [[ $haystack != *"$needle"* ]]; then
        fail "$label: [$needle] not found"
        return 1
    fi
}

assert_not_contains() {
    local haystack=$1
    local needle=$2
    local label=${3:-unexpected substring}
    if [[ $haystack == *"$needle"* ]]; then
        fail "$label: [$needle] unexpectedly found"
        return 1
    fi
}

assert_true() {
    local label=$1
    shift
    if ! "$@"; then
        fail "$label"
        return 1
    fi
}

assert_false() {
    local label=$1
    shift
    if "$@"; then
        fail "$label"
        return 1
    fi
}

# Like assert_false, but runs the command in a subshell. Use this for
# validation functions that call die(), so the test process is not terminated.
assert_fails() {
    local label=$1
    shift
    if ("$@"); then
        fail "$label"
        return 1
    fi
}

assert_file_contains() {
    local file=$1
    local needle=$2
    local label=${3:-file content missing}
    [[ -f $file ]] || {
        fail "$label: file $file does not exist"
        return 1
    }
    if ! grep -Fq -- "$needle" "$file"; then
        fail "$label: [$needle] not found in $file"
        return 1
    fi
}

run_test() {
    local name=$1
    local function=$2
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  - %s\n' "$name"
    if (set -Eeuo pipefail; "$function"); then
        return 0
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
    return 0
}

test_summary() {
    printf '\n%d tests, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    if ((TESTS_FAILED > 0)); then
        return 1
    fi
    return 0
}
