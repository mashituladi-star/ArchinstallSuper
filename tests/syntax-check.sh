#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT/install.sh"
printf 'Bash syntax check passed.\n'

python3 "$ROOT/tests/profile-config-check.py"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=warning "$ROOT/install.sh"
    printf 'ShellCheck passed.\n'
else
    printf 'ShellCheck is not installed; skipped.\n'
fi
