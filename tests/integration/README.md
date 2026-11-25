# QEMU/UEFI integration test

The unit tests never touch disks, EFI variables or the network. A real
installer must also be exercised in a UEFI virtual machine before it is used
on hardware.

This directory contains an interactive launcher, not a CI test. It boots the
official Arch Linux ISO with OVMF firmware and a blank virtio disk. You drive
the installer inside the VM, then reboot to prove that systemd-boot and the
initramfs work.

## Prerequisites

Arch Linux host:

```bash
sudo pacman -S --needed qemu-full edk2-ovmf
```

Debian/Ubuntu host:

```bash
sudo apt-get install --yes qemu-system-x86 ovmf
```

Also download an official ISO from <https://archlinux.org/download/> and verify
its signature as described on that page.

## Run

```bash
export ARCH_ISO=/path/to/archlinux-*.iso
bash tests/integration/qemu-uefi.sh
```

Useful options:

```bash
# Keep the disk image after the VM exits.
bash tests/integration/qemu-uefi.sh --keep --workdir /tmp/as-vm

# Headless host: expose the VM over VNC on localhost:5901.
bash tests/integration/qemu-uefi.sh --display vnc --vnc :1
```

## Manual checklist inside the VM

1. Confirm UEFI mode: `ls /sys/firmware/efi` must succeed.
2. Confirm the virtual disk is visible: `lsblk` (usually `/dev/vda`).
3. Run `bash install.sh --check`.
4. Run `bash install.sh` and complete the wizard.
5. Power off, then start the same VM again with the ISO detached. The
   systemd-boot menu must appear and the installed system must boot.
6. Log in and verify:
   - `findmnt /` and `findmnt /boot`
   - `bootctl status`
   - `systemctl status NetworkManager`
   - `lsblk -f` for the expected filesystem and encryption layout
7. For LUKS, the passphrase prompt must appear before the root filesystem is
   mounted. For Btrfs, `cat /proc/cmdline` must contain `rootflags=subvol=@`.

## Why this is not automated

The installer is deliberately interactive and asks for typed confirmations
before erasing a disk. Automating that safely requires a separate, explicitly
non-interactive configuration path. Until such a path exists and is reviewed,
the integration test stays manual on purpose.

## What the unit tests do cover

`bash tests/run-tests.sh` checks Bash syntax, ShellCheck, disk-safety logic,
partition naming, Btrfs boot flags, fstab validation, LUKS argument generation,
package preflight with a fake pacman, configuration file generation and the
installation order. It is safe to run as a normal user.
