#!/usr/bin/env bash
# Full local test runner. Safe to run as a normal user: it never touches disks
# and never invokes pacstrap, sgdisk, mkfs, cryptsetup or bootctl.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

FAILED=0
RUN=0

run_step() {
    local name=$1
    shift
    RUN=$((RUN + 1))
    printf '\n== %s ==\n' "$name"
    if "$@"; then
        return 0
    fi
    FAILED=$((FAILED + 1))
    printf 'FAILED: %s\n' "$name" >&2
    return 0
}

printf 'ArchinstallSuper test suite\n'
printf 'Repository: %s\n' "$ROOT"

run_step "Bash syntax" bash tests/syntax-check.sh

if [[ -x tests/static-checks.sh || -f tests/static-checks.sh ]]; then
    run_step "Static safety checks" bash tests/static-checks.sh
fi

for test_file in tests/unit/*-test.sh; do
    [[ -f $test_file ]] || continue
    run_step "Unit: $(basename "$test_file" .sh)" bash "$test_file"
done

printf '\n========================================\n'
printf 'Steps: %d, failed: %d\n' "$RUN" "$FAILED"
if ((FAILED > 0)); then
    printf 'RESULT: FAILED\n' >&2
    exit 1
fi
printf 'RESULT: PASSED\n'
