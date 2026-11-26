# ArchinstallSuper — Quick Start

ArchinstallSuper is a standalone, full-screen UEFI installer for Arch Linux.
It does **not** use `archinstall`; it uses standard Arch tooling
(`pacstrap`, `pacman`, `sgdisk`, `mkfs`, `systemd-boot`, `mkinitcpio`,
`cryptsetup`) and gives you a modern TUI or fully unattended installation.

## 1. Boot the official Arch Linux ISO

Boot in **UEFI mode** (x86_64). Legacy BIOS/CSM and MBR are not supported.
Make sure you have an internet connection (wired or Wi-Fi).

## 2. Run the installer

```bash
# Interactive full-screen installer (recommended first time)
bash install.sh

# Plain text mode (no curses/TUI)
bash install.sh --plain

# Preflight check only (UEFI, live ISO, network)
bash install.sh --check

# Collect settings and show the plan without touching any disk
bash install.sh --dry-run
```

The installer opens immediately into a full-screen window. You choose the
profile, kernel, filesystem, disk, system settings, encryption and then type
`INSTALL` to confirm before any disk is touched.

## 3. Unattended installation (automation)

For automated or repeated installs, prepare a configuration file:

```bash
bash install.sh --example-config > myconfig.conf
# Edit myconfig.conf: set disk, hostname, passwords, etc.
chmod 600 myconfig.conf
bash install.sh --config myconfig.conf --auto
```

The configuration file uses INI-like syntax with sections `[system]`,
`[install]`, `[disk]`, `[packages]`, `[network]`. Passwords are never
written to the log.

## 4. Install as a package (Arch Linux)

```bash
makepkg -si
```

This installs the `archinstallsuper` command, man pages and an example
config to `/usr/share/archinstallsuper/examples/`.

## 5. What gets installed

| Item | Choice |
|------|--------|
| Bootloader | systemd-boot (UEFI) |
| Kernel | linux, linux-lts, linux-zen or linux-hardened |
| Filesystem | ext4, Btrfs (@, @home, @var_log, @snapshots, zstd) or XFS |
| Encryption | Optional LUKS2 (argon2id, aes-xts-plain64) |
| Desktop | Console, GNOME, KDE Plasma, XFCE or Cinnamon |
| Network | NetworkManager enabled |
| zram | Optional compressed swap in RAM |

## 6. Safety

* Every destructive action requires explicit confirmation (`ERASE /dev/…`,
  then `INSTALL`).
* The selected disk is re-validated immediately before partitioning.
* Live ISO disk, current root disk, mounted disks, active swap and LUKS/LVM
  devices are rejected.
* Passwords are never logged or exposed on the command line.
* A single-instance lock prevents concurrent runs.
* On failure the installer unmounts the target and closes LUKS containers.

## 7. Logs

```
/var/log/archinstallsuper.log        (mode 0600)
/var/log/archinstallsuper-install.log (copied into the target system)
```

## 8. More documentation

* `docs/ARCHITECTURE.md` — design and data flow
* `docs/UI.md` — TUI controls and backends
* `docs/RECOVERY.md` — what to do if installation fails
* `docs/TESTING.md` — test suite and QEMU/UEFI integration
* `docs/AUDIT.md` — security audit notes
* `man archinstallsuper(8)` — full reference
