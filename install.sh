#!/usr/bin/env bash
# ArchinstallSuper — самостоятельный UEFI-установщик Arch Linux.
set -Eeuo pipefail
umask 077
VERSION=0.3.0
TARGET=/mnt
LOG=/var/log/archinstallsuper.log
MODE=minimal
DESKTOP=
DISK=
HOSTNAME=archlinux
USERNAME=
TIMEZONE=Europe/Prague
LOCALE=en_US.UTF-8
KEYMAP=us
ROOT_PASSWORD=
USER_PASSWORD=
PACKAGES=()
mkdir -p /var/log
exec > >(tee -a "$LOG") 2>&1

info(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Не найдена команда $1"; }
cleanup(){ rc=$?; if ((rc)); then warn "Ошибка $rc. Журнал: $LOG"; fi; }
trap cleanup EXIT

check_environment(){
  [[ $EUID -eq 0 ]] || die "Запусти от root."
  [[ -d /sys/firmware/efi/efivars ]] || die "Нужна загрузка флешки в режиме UEFI."
  [[ -f /etc/arch-release && -d /run/archiso ]] || die "Нужна live-среда официального Arch ISO."
  [[ $(uname -m) == x86_64 ]] || die "Поддерживается только x86_64."
  for c in lsblk sgdisk wipefs mkfs.fat mkfs.ext4 pacstrap genfstab arch-chroot bootctl blkid partprobe udevadm; do need "$c"; done
  info "UEFI и live-среда проверены."
}
check_network(){
  for _ in 1 2 3; do
    curl -fsSI --connect-timeout 5 https://archlinux.org/ >/dev/null 2>&1 && { timedatectl set-ntp true >/dev/null 2>&1 || true; return; }
    warn "Нет интернета. Настрой Wi-Fi через iwctl."
    command -v iwctl >/dev/null 2>&1 && iwctl
  done
  die "Для установки нужен интернет."
}
select_mode(){
  printf '\nArchinstallSuper %s — режимы установки\n' "$VERSION"
  printf '1) Минимальная — консоль\n2) Базовая — GNOME\n3) Полная — GNOME и приложения\n4) Кастомная\n'
  read -r -p 'Выбор [1-4]: ' choice
  case "$choice" in
    1) MODE=minimal; PACKAGES=(base linux linux-firmware networkmanager sudo nano) ;;
    2) MODE=basic; DESKTOP=gnome; PACKAGES=(base linux linux-firmware networkmanager sudo nano git firefox gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
    3) MODE=full; DESKTOP=gnome; PACKAGES=(base linux linux-firmware networkmanager sudo nano git firefox gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber libreoffice-fresh vlc gimp gnome-tweaks flatpak base-devel fastfetch btop htop curl wget zip unzip) ;;
    4)
      MODE=custom; PACKAGES=(base linux linux-firmware networkmanager sudo nano)
      printf 'Окружение: 0) консоль 1) GNOME 2) KDE 3) XFCE 4) Cinnamon\n'
      read -r -p 'Выбор [1]: ' choice; choice=${choice:-1}
      case "$choice" in
        0) DESKTOP= ;;
        1) DESKTOP=gnome; PACKAGES+=(gnome gdm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        2) DESKTOP=kde; PACKAGES+=(plasma-meta konsole dolphin sddm pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        3) DESKTOP=xfce; PACKAGES+=(xfce4 xfce4-goodies lightdm lightdm-gtk-greeter pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        4) DESKTOP=cinnamon; PACKAGES+=(cinnamon lightdm lightdm-gtk-greeter pipewire pipewire-alsa pipewire-pulse wireplumber) ;;
        *) die "Неверное окружение." ;;
      esac
      read -r -p 'Инструменты разработчика? [д/Н] ' choice
      case "$choice" in д|да|y|Y) PACKAGES+=(git base-devel python python-pip nodejs npm);; esac
      read -r -p 'Firefox, VLC, GIMP, LibreOffice? [д/Н] ' choice
      case "$choice" in д|да|y|Y) PACKAGES+=(firefox vlc gimp libreoffice-fresh);; esac
      read -r -p 'Дополнительные пакеты (пробел-разделитель, Enter — пропустить): ' -a extra
      for p in "${extra[@]}"; do [[ $p =~ ^[a-zA-Z0-9@._+-]+$ ]] || die "Недопустимый пакет: $p"; PACKAGES+=("$p"); done
      ;;
    *) die "Выбери режим от 1 до 4." ;;
  esac
  grep -q GenuineIntel /proc/cpuinfo && PACKAGES+=(intel-ucode)
  grep -q AuthenticAMD /proc/cpuinfo && PACKAGES+=(amd-ucode)
  info "Профиль $MODE; окружение ${DESKTOP:-консоль}."
}
select_disk(){
  lsblk -dpno NAME,SIZE,MODEL,TYPE | awk '$4=="disk"{print}'
  read -r -p 'Полный путь к диску (например /dev/nvme0n1): ' candidate
  [[ -b $candidate && $(lsblk -dnro TYPE "$candidate") == disk ]] || die "Укажи целый диск."
  DISK=$(readlink -f "$candidate")
  if lsblk -nrpo MOUNTPOINT "$DISK" | grep -q .; then die "Есть смонтированные разделы выбранного диска."; fi
  printf '\nВСЕ ДАННЫЕ НА %s БУДУТ УДАЛЕНЫ.\n' "$DISK"
  read -r -p "Введи ERASE $DISK для подтверждения: " answer
  [[ $answer == "ERASE $DISK" ]] || die "Подтверждение не совпало."
}
system_settings(){
  read -r -p 'Имя компьютера [archlinux]: ' value; HOSTNAME=${value:-archlinux}
  [[ $HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Недопустимое имя компьютера."
  read -r -p 'Имя пользователя: ' USERNAME
  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Недопустимое имя пользователя."
  read -r -p 'Часовой пояс [Europe/Prague]: ' value; TIMEZONE=${value:-Europe/Prague}
  [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || die "Неизвестный часовой пояс."
  read -r -p 'Локаль [en_US.UTF-8]: ' value; LOCALE=${value:-en_US.UTF-8}
  [[ $LOCALE =~ ^[a-zA-Z_]+\.UTF-8$ ]] || die "Неверный формат локали."
  read -r -p 'Раскладка [us]: ' value; KEYMAP=${value:-us}
  read -r -s -p 'Пароль root: ' ROOT_PASSWORD; printf '\n'
  read -r -s -p 'Повтори пароль root: ' value; printf '\n'
  [[ -n $ROOT_PASSWORD && $ROOT_PASSWORD == "$value" ]] || die "Пароли root не совпадают."
  read -r -s -p "Пароль $USERNAME: " USER_PASSWORD; printf '\n'
  read -r -s -p 'Повтори пароль пользователя: ' value; printf '\n'
  [[ -n $USER_PASSWORD && $USER_PASSWORD == "$value" ]] || die "Пароли пользователя не совпадают."
}
partition_disk(){
  info "Создаю GPT, EFI 1 GiB и корневой раздел."
  wipefs -af "$DISK"
  sgdisk --zap-all "$DISK"
  sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI "$DISK"
  sgdisk -n 2:0:0 -t 2:8300 -c 2:ARCHROOT "$DISK"
  partprobe "$DISK"; udevadm settle
  if [[ $DISK =~ (nvme[0-9]n[0-9]|mmcblk[0-9])$ ]]; then EFI_PART="${DISK}p1"; ROOT_PART="${DISK}p2"
  else EFI_PART="${DISK}1"; ROOT_PART="${DISK}2"; fi
  for _ in {1..10}; do [[ -b $EFI_PART && -b $ROOT_PART ]] && break; sleep 1; done
  [[ -b $EFI_PART && -b $ROOT_PART ]] || die "Разделы не появились."
}
install_system(){
  mkfs.fat -F32 "$EFI_PART"
  mkfs.ext4 -F "$ROOT_PART"
  mkdir -p "$TARGET/boot"
  mount "$ROOT_PART" "$TARGET"
  mount "$EFI_PART" "$TARGET/boot"
  info "Устанавливаю пакеты: ${PACKAGES[*]}"
  pacstrap -K "$TARGET" "${PACKAGES[@]}"
  genfstab -U "$TARGET" > "$TARGET/etc/fstab"
  [[ -s $TARGET/etc/fstab ]] || die "Не создан fstab."
}
configure_system(){
  root_uuid=$(blkid -s UUID -o value "$ROOT_PART")
  printf '%s\n' "$HOSTNAME" > "$TARGET/etc/hostname"
  printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$HOSTNAME" "$HOSTNAME" > "$TARGET/etc/hosts"
  printf 'LANG=%s\n' "$LOCALE" > "$TARGET/etc/locale.conf"
  printf 'KEYMAP=%s\n' "$KEYMAP" > "$TARGET/etc/vconsole.conf"
  sed -i "s/^#\(${LOCALE}[[:space:]]\)/\1/" "$TARGET/etc/locale.gen"
  grep -q "^$LOCALE " "$TARGET/etc/locale.gen" || printf '%s UTF-8\n' "$LOCALE" >> "$TARGET/etc/locale.gen"
  arch-chroot "$TARGET" ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  arch-chroot "$TARGET" hwclock --systohc
  arch-chroot "$TARGET" locale-gen
  arch-chroot "$TARGET" useradd -m -G wheel -s /bin/bash "$USERNAME"
  printf 'root:%s\n%s:%s\n' "$ROOT_PASSWORD" "$USERNAME" "$USER_PASSWORD" | arch-chroot "$TARGET" chpasswd
  unset ROOT_PASSWORD USER_PASSWORD
  printf '%%wheel ALL=(ALL:ALL) ALL\n' > "$TARGET/etc/sudoers.d/10-wheel"
  chmod 440 "$TARGET/etc/sudoers.d/10-wheel"
  arch-chroot "$TARGET" visudo -cf /etc/sudoers
  arch-chroot "$TARGET" systemctl enable NetworkManager
  case "$DESKTOP" in
    gnome) arch-chroot "$TARGET" systemctl enable gdm ;;
    kde) arch-chroot "$TARGET" systemctl enable sddm ;;
    xfce|cinnamon) arch-chroot "$TARGET" systemctl enable lightdm ;;
  esac
  mkdir -p "$TARGET/boot/loader/entries"
  printf 'default archinstall-super.conf\ntimeout 3\nconsole-mode max\neditor no\n' > "$TARGET/boot/loader/loader.conf"
  {
    printf 'title Arch Linux (ArchinstallSuper)\nlinux /vmlinuz-linux\n'
    [[ -f $TARGET/boot/intel-ucode.img ]] && printf 'initrd /intel-ucode.img\n'
    [[ -f $TARGET/boot/amd-ucode.img ]] && printf 'initrd /amd-ucode.img\n'
    printf 'initrd /initramfs-linux.img\noptions root=UUID=%s rw\n' "$root_uuid"
  } > "$TARGET/boot/loader/entries/archinstall-super.conf"
  arch-chroot "$TARGET" bootctl --esp-path=/boot install
}
main(){
  check_environment
  check_network
  select_mode
  select_disk
  system_settings
  printf '\nРежим: %s; диск: %s; hostname: %s; user: %s\n' "$MODE" "$DISK" "$HOSTNAME" "$USERNAME"
  read -r -p 'Для начала установки введи INSTALL: ' answer
  [[ $answer == INSTALL ]] || die "Отменено до изменения диска."
  partition_disk
  install_system
  configure_system
  printf '\nУстановка завершена. Разделы смонтированы в /mnt.\n'
  printf 'Журнал: %s\nВыполни: umount -R /mnt && reboot\n' "$LOG"
}
main "$@"
