#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/install.sh"
shellcheck --severity=warning "$ROOT/install.sh"
if grep -qE '(^|[[:space:]])archinstall([[:space:]]|$)' "$ROOT/install.sh"; then
  printf 'Unexpected archinstall invocation found.\n' >&2
  exit 1
fi
printf 'Standalone UEFI installer checks passed.\n'
