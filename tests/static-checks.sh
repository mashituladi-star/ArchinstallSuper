#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"

bash -n "$INSTALLER"
grep -q '^VERSION=0\.9\.0$' "$INSTALLER"
grep -q -- '--check' "$INSTALLER"
grep -q 'efivars' "$INSTALLER"
grep -q 'sgdisk --zap-all' "$INSTALLER"
grep -q 'Введи точно: ERASE' "$INSTALLER"
grep -q 'Введи INSTALL' "$INSTALLER"
grep -q 'bootctl --esp-path=/boot install' "$INSTALLER"
grep -q 'rootflags=subvol=@,compress=zstd' "$INSTALLER"
grep -q 'mountpoint -q "\$TARGET/boot"' "$INSTALLER"
grep -q '== vfat' "$INSTALLER"
grep -q 'arch-chroot "$TARGET" systemctl enable NetworkManager' "$INSTALLER"

echo "Static installer checks passed."
