#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bash -n "$ROOT/install.sh"
shellcheck --severity=warning "$ROOT/install.sh"
if grep -qE '(^|[[:space:]])archinstall([[:space:]]|$)' "$ROOT/install.sh"; then
  printf 'Unexpected archinstall invocation found.\n' >&2
  exit 1
fi
grep -q 'disk_bytes >= 24' "$ROOT/install.sh"
grep -q 'Нельзя устанавливать на диск' "$ROOT/install.sh"
grep -q 'curl awk grep sed readlink findmnt' "$ROOT/install.sh"
grep -q 'dialog --clear' "$ROOT/install.sh"
grep -q 'ui_password' "$ROOT/install.sh"
grep -q 'Рабочее окружение' "$ROOT/install.sh"
grep -q -- '--programbox' "$ROOT/install.sh"
grep -q 'btrfs subvolume create' "$ROOT/install.sh"
grep -q 'compress=zstd,subvol=@' "$ROOT/install.sh"
grep -q 'select_filesystem' "$ROOT/install.sh"
printf 'Standalone UEFI installer checks passed.\n'
