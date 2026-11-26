#!/usr/bin/env bash
# Standalone syntax/ShellCheck wrapper. The full test suite is run by
# tests/run-tests.sh; this file remains useful for editors and CI jobs.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

integration_files=(tests/integration/*.sh)
[[ -e ${integration_files[0]} ]] || integration_files=()

for file in install.sh lib/*.sh tests/*.sh tests/unit/*.sh tests/lib/*.sh \
    "${integration_files[@]}"; do
    [[ -f $file ]] || continue
    bash -n "$file"
done

if command -v python3 >/dev/null 2>&1; then
    python3 -m py_compile lib/tui.py tests/lib/tui_pty.py
fi

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=warning -x install.sh lib/*.sh tests/*.sh \
        tests/unit/*.sh tests/lib/*.sh "${integration_files[@]}"
else
    printf 'shellcheck not installed; syntax check only.\n'
fi

if grep -qE '(^[[:space:]]*(sudo[[:space:]]+)?archinstall([[:space:]]|$))|([;&|][[:space:]]*archinstall([[:space:]]|$))' \
    install.sh lib/*.sh; then
    printf 'Unexpected archinstall invocation found.\n' >&2
    exit 1
fi

printf 'Standalone UEFI installer checks passed.\n'
