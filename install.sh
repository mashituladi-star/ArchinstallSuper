#!/usr/bin/env bash
# ArchinstallSuper — самостоятельный UEFI-установщик Arch Linux.
set -Eeuo pipefail
umask 077
VERSION=0.4.0
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
exec 3>&1 4>&2
exec > >(tee -a "$LOG") 2>&1


UI=0
ui_init(){
  if command -v dialog >/dev/null 2>&1; then UI=1; return; fi
  if command -v pacman >/dev/null 2>&1 && [[ -t 0 && -t 4 ]]; then
    info "Подготавливаю полноэкранный интерфейс dialog..."
    pacman -Sy --needed --noconfirm dialog || warn "Не удалось установить dialog; включён текстовый режим."
    command -v dialog >/dev/null 2>&1 && UI=1
  fi
}
ui_menu(){
  local title=$1 prompt=$2 height=$3 width=$4 list_height=$5
  shift 5
  if (( UI )); then dialog --clear --backtitle "ARCHINSTALLSUPER  |  UEFI INSTALLER  |  v$VERSION" --title "$title" --menu "$prompt" "$height" "$width" "$list_height" "$@" --output-fd 3 2>&4 || die "Действие отменено."; else
    printf '\\n%s\\n%s\\n' "$title" "$prompt"
    local i=1
    while (( $# )); do printf '%s) %s — %s\\n' "$i" "$1" "$2"; shift 2; ((i+=1)); done
    printf 'Выбор: ' >&4; read -r REPLY
    printf '%s' "$REPLY"
  fi
}
ui_input(){
  local title=$1 prompt=$2 initial=${3-}
  if (( UI )); then dialog --clear --backtitle "ARCHINSTALLSUPER  |  v$VERSION" --title "$title" --inputbox "$prompt" 9 64 "$initial" --output-fd 3 2>&4 || die "Действие отменено."; else printf '%s ' "$prompt" >&4; read -r REPLY; printf '%s' "${REPLY:-$initial}"; fi
}
ui_password(){
  local title=$1 prompt=$2
  if (( UI )); then dialog --clear --backtitle "ARCHINSTALLSUPER  |  v$VERSION" --title "$title" --insecure --passwordbox "$prompt" 9 64 --output-fd 3 2>&4 || die "Действие отменено."; else read -r -s -p "$prompt " REPLY; printf '\\n' >&4; printf '%s' "$REPLY"; fi
}
ui_msg(){ if (( UI )); then dialog --clear --backtitle "ARCHINSTALLSUPER  |  v$VERSION" --title "ArchinstallSuper" --msgbox "$1" 9 70 2>&4; else info "$1"; fi; }
ui_confirm(){ if (( UI )); then dialog --clear --backtitle "ARCHINSTALLSUPER  |  v$VERSION" --title "Подтверждение" --yesno "$1" 11 72 2>&4; else read -r -p "$1 [y/N] " REPLY; [[ $REPLY == y || $REPLY == Y ]]; fi; }
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
  for c in lsblk sgdisk wipefs mkfs.fat mkfs.ext4 pacstrap genfstab arch-chroot bootctl blkid partprobe udevadm curl awk grep sed readlink findmnt; do need "$c"; done
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
  choice=$(ui_menu "Выбор профиля" "Выбери состав системы. Графические профили используют GNOME." 16 76 4 1 "Минимальная · консоль" 2 "Базовая · GNOME" 3 "Полная · GNOME + приложения" 4 "Кастомная настройка")
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
  local -a disk_options=()
  while read -r name size model type; do
    [[ $type == disk ]] || continue
    disk_options+=("$name" "$size · $model")
  done < <(lsblk -dpno NAME,SIZE,MODEL,TYPE)
  (("${#disk_options[@]}" > 0)) || die "Не найдено дисков."
  candidate=$(ui_menu "Целевой диск" "ВНИМАНИЕ: выбранный диск будет полностью очищен." 18 80 8 "${disk_options[@]}")
  [[ -b $candidate && $(lsblk -dnro TYPE "$candidate") == disk ]] || die "Укажи целый диск."
  DISK=$(readlink -f "$candidate")
  disk_bytes=$(lsblk -bndo SIZE "$DISK")
  (( disk_bytes >= 24 * 1024 * 1024 * 1024 )) || die "Диск меньше 24 GiB. Требуется минимум 24 GiB."
  live_source=$(findmnt -nro SOURCE /run/archiso/bootmnt 2>/dev/null || true)
  if [[ -n $live_source && -b $live_source ]]; then
    live_parent=$(lsblk -nro PKNAME "$live_source" 2>/dev/null || true)
    [[ -n $live_parent ]] && live_source="/dev/$live_parent"
    live_source=$(readlink -f "$live_source")
    [[ $DISK != "$live_source" ]] || die "Нельзя устанавливать на диск, с которого запущена live-система."
  fi
  if lsblk -nrpo MOUNTPOINT "$DISK" | grep -q .; then die "Есть смонтированные разделы выбранного диска."; fi
  ui_confirm "Все данные на $DISK будут безвозвратно удалены. Продолжить?" || die "Отменено пользователем."
  answer=$(ui_input "Подтверждение стирания" "Введи точно: ERASE $DISK")
  [[ $answer == "ERASE $DISK" ]] || die "Подтверждение не совпало."
}
system_settings(){
  HOSTNAME=$(ui_input "Имя компьютера" "Задай hostname:" "archlinux")
  [[ $HOSTNAME =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$ ]] || die "Недопустимое имя компьютера."
  USERNAME=$(ui_input "Учётная запись" "Имя обычного пользователя:")
  [[ $USERNAME =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Недопустимое имя пользователя."
  TIMEZONE=$(ui_input "Регион" "Часовой пояс:" "Europe/Prague")
  [[ -e /usr/share/zoneinfo/$TIMEZONE ]] || die "Неизвестный часовой пояс."
  LOCALE=$(ui_input "Язык системы" "Локаль:" "en_US.UTF-8")
  [[ $LOCALE =~ ^[a-zA-Z_]+\.UTF-8$ ]] || die "Неверный формат локали."
  grep -Eq "^#?${LOCALE}[[:space:]]+UTF-8$" /etc/locale.gen || die "Локаль $LOCALE отсутствует в /etc/locale.gen."
  KEYMAP=$(ui_input "Клавиатура" "Раскладка:" "us")
  [[ $KEYMAP =~ ^[a-zA-Z0-9_-]+$ ]] || die "Недопустимое имя раскладки."
  find /usr/share/kbd/keymaps -type f -name "${KEYMAP}.map*" -print -quit 2>/dev/null | grep -q . || die "Раскладка $KEYMAP не найдена в live-системе."
  ROOT_PASSWORD=$(ui_password "Пароль администратора" "Пароль root:")
  value=$(ui_password "Подтверждение" "Повтори пароль root:")
  [[ -n $ROOT_PASSWORD && $ROOT_PASSWORD == "$value" && $ROOT_PASSWORD != *:* ]] || die "Пароли root не совпадают."
  USER_PASSWORD=$(ui_password "Пароль пользователя" "Пароль для $USERNAME:")
  value=$(ui_password "Подтверждение" "Повтори пароль пользователя:")
  [[ -n $USER_PASSWORD && $USER_PASSWORD == "$value" && $USER_PASSWORD != *:* ]] || die "Пароли пользователя не совпадают."
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
  ui_init
  select_mode
  select_disk
  system_settings
  ui_msg "Проверь настройки перед запуском:\n\nПрофиль: $MODE\nОкружение: ${DESKTOP:-консоль}\nДиск: $DISK\nHostname: $HOSTNAME\nПользователь: $USERNAME\n\nДанные на выбранном диске будут уничтожены."
  answer=$(ui_input "Финальное подтверждение" "Введи INSTALL для начала установки:")
  [[ $answer == INSTALL ]] || die "Отменено до изменения диска."
  partition_disk
  install_system
  configure_system
  printf '\nУстановка завершена. Разделы смонтированы в /mnt.\n'
  printf 'Журнал: %s\nВыполни: umount -R /mnt && reboot\n' "$LOG"
}
main "$@"
