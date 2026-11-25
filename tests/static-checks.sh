#!/usr/bin/env bash
# Static safety checks. These are deliberately simple, explicit guards: they
# catch regressions in the properties that matter most (no archinstall, no
# silent disk wiping, correct boot flags, secret-safe password handling).

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

FAILED=0

fail() {
    printf 'STATIC FAIL: %s\n' "$*" >&2
    FAILED=1
}

require_pattern() {
    local pattern=$1
    local file=$2
    local label=$3
    if ! grep -Fq -- "$pattern" "$file"; then
        fail "$label (missing '$pattern' in $file)"
    fi
}

reject_pattern() {
    local pattern=$1
    local file=$2
    local label=$3
    if grep -Fq -- "$pattern" "$file"; then
        fail "$label (found '$pattern' in $file)"
    fi
}

integration_files=(tests/integration/*.sh)
[[ -e ${integration_files[0]} ]] || integration_files=()

for file in install.sh lib/*.sh tests/*.sh tests/unit/*.sh tests/lib/*.sh \
    "${integration_files[@]}"; do
    [[ -f $file ]] || continue
    bash -n "$file" || fail "syntax error in $file"
done

require_pattern 'VERSION=0.10.0' install.sh 'version'
require_pattern '--check' install.sh 'preflight CLI'
require_pattern '--dry-run' install.sh 'dry-run CLI'
require_pattern 'flock -n' lib/recovery.sh 'single-instance lock'
require_pattern 'mountpoint -q "$TARGET"' lib/storage.sh 'target mount check'
require_pattern 'sgdisk --zap-all' lib/storage.sh 'GPT wipe'
require_pattern '--typecode=1:ef00' lib/storage.sh 'EFI partition type'
require_pattern 'ERASE $DISK' lib/storage.sh 'explicit erase confirmation'
require_pattern 'INSTALL' lib/workflow.sh 'final confirmation'
require_pattern 'bootctl --esp-path=/boot install' lib/boot.sh 'systemd-boot install'
require_pattern 'mkinitcpio -P' lib/boot.sh 'initramfs regeneration'
require_pattern 'rootflags=subvol=@' lib/boot.sh 'Btrfs root flags'
require_pattern 'cryptdevice=UUID=' lib/security.sh 'LUKS boot arguments'
require_pattern '--type luks2' lib/security.sh 'LUKS2'
require_pattern '--key-file -' lib/security.sh 'passphrase via stdin'
require_pattern 'findmnt --verify' lib/validate.sh 'fstab verification'
require_pattern 'NetworkManager' lib/config.sh 'NetworkManager enablement'
require_pattern 'btrfs-progs' lib/storage.sh 'Btrfs tools'
require_pattern 'xfsprogs' lib/storage.sh 'XFS tools'
require_pattern 'zram-generator' lib/workflow.sh 'zram'
require_pattern 'intel-ucode' lib/hardware.sh 'Intel microcode'
require_pattern 'amd-ucode' lib/hardware.sh 'AMD microcode'
require_pattern 'chpasswd' lib/security.sh 'password setting'

reject_pattern '--output-fd 3' lib/ui.sh 'dialog must use --stdout for return values'
reject_pattern 'archinstall ' install.sh 'no archinstall invocation in entrypoint'
reject_pattern 'eval ' install.sh 'no eval in entrypoint'
reject_pattern 'eval ' lib/core.sh 'no eval in core'

if grep -RInE --include='*.sh' '(^[[:space:]]*(sudo[[:space:]]+)?archinstall([[:space:]]|$))|([;&|][[:space:]]*archinstall([[:space:]]|$))|(pacman[^#]*[[:space:]]archinstall([[:space:]]|$))' \
    install.sh lib >/dev/null 2>&1; then
    fail 'archinstall invocation found'
fi

if grep -RInE --include='*.sh' '(info|warn|error|echo)[^#]*\$\{?(ROOT_PASSWORD|USER_PASSWORD|LUKS_PASSWORD)' \
    install.sh lib >/dev/null 2>&1; then
    fail 'password variable appears in an output/log statement'
fi

if command -v shellcheck >/dev/null 2>&1; then
    if ! shellcheck --severity=warning -x install.sh lib/*.sh tests/*.sh \
        tests/unit/*.sh tests/lib/*.sh "${integration_files[@]}"; then
        fail 'ShellCheck reported warnings'
    fi
else
    printf 'NOTE: shellcheck not installed; static checks without ShellCheck.\n'
fi

if ((FAILED)); then
    exit 1
fi
printf 'Static installer checks passed.\n'
