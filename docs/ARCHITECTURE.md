# Архитектура

## Принципы

1. **Никакого `archinstall`.** Используются только штатные инструменты Arch
   Linux. Это позволяет понимать и проверять каждый шаг установки.
2. **Безопасность важнее количества функций.** Любая деструктивная операция
   требует явного подтверждения и повторной проверки диска.
3. **Модульность.** `install.sh` — тонкая точка входа; логика разложена по
   `lib/*.sh`. Функции, генерирующие содержимое файлов, по возможности чистые и
   тестируются без root.
4. **Проверяемость.** Каждый этап оставляет след в журнале; результат
   установки проверяется до размонтирования.
5. **Никаких секретов в argv и журнале.** Пароли передаются только через pipe
   или stdin.

## Поток выполнения

```text
install.sh
  parse_args
  core_init                  umask, журнал, state/temp dirs
  recovery_init              trap EXIT/INT/TERM/HUP
  [--check] -> workflow_check_only

  validate_environment       root, live Arch, x86_64, UEFI, пустой /mnt, команды
  recovery_lock              flock, один экземпляр
  ui_init                    dialog или plain
  network_ensure             интернет, Wi-Fi при необходимости
  install_refresh_packages   pacman -Sy, archlinux-keyring
  hw_detect / hw_show_screen
  plugin_load_all

  workflow_collect
    профиль, ядро, ФС
    storage_select_disk      выбор + ERASE <disk>
    system settings          hostname, пользователь, TZ, локаль, keymap, пароли
    encryption / zram
    extra packages
    workflow_build_packages
    validate_all             конфиг, пакеты, размер, диск, разметка

  workflow_show_summary
  [--dry-run] -> выход без изменений
  workflow_final_confirm     ввод INSTALL

  workflow_execute
    plugin pre_install
    storage_partition_disk   wipefs, sgdisk, GPT
    storage_make_filesystems FAT32 + ext4/Btrfs/XFS (+ LUKS2)
    storage_mount_target     монтирование, Btrfs subvolumes
    install_pacstrap
    storage_generate_fstab   genfstab + validate_fstab
    config_apply_all
    boot_apply_all           initramfs, systemd-boot, entry, verify
    install_verify
    install_copy_log
    plugin post_install
    storage_unmount_target   umount -R, close LUKS
    plugin pre_reboot

  workflow_after_success     итог, предложение перезагрузки
```

## Модули

### `lib/core.sh`

Глобальные значения по умолчанию, журналирование, `die`, `debug`, проверки
команд, `core_human_size`, `core_bytes_from_size`, работа с массивами.

`core_init` сначала создаёт защищённые пути под `umask 077` (журнал `0600`,
state `0700`, temp `0700`), затем ставит `umask 022`, чтобы файлы в целевой
системе (`/etc/fstab`, загрузочные записи) получили обычные права.

### `lib/ui.sh`

Единый интерфейс. В режиме `dialog` возвращаемые значения читаются через
`dialog --stdout` и командную подстановку; сам интерфейс рисуется в fd 4
(исходный stderr), чтобы не смешиваться с захваченным stdout. В режиме `plain`
меню нумеруются, пароль читается с `-s`.

### `lib/hardware.sh`

Только чтение: CPU, RAM, плата, прошивка, GPU, сеть, Secure Boot, микрокод.
`hw_add_packages` добавляет `intel-ucode`/`amd-ucode` и `mesa` для графических
профилей.

### `lib/validate.sh`

Проверки ввода (hostname, пользователь, TZ, локаль, keymap, пароли, имена
пакетов), среды (root, live Arch, UEFI, команды), пакетов (наличие и размер),
fstab, разметки и результата установки.

`validate_btrfs_root_flag` принимает и `subvol=@`, и `subvol=/@` (формат
`genfstab`), но не `subvol=/@home`.

### `lib/network.sh`

Проверка интернета и DNS, статус интерфейсов, Wi-Fi через `iwctl`. Пароль
Wi-Fi передаётся через stdin.

### `lib/security.sh`

Политика паролей, LUKS2 (argon2id, aes-xts-plain64), открытие/закрытие
контейнера, генерация `cryptdevice=... root=/dev/mapper/...`. Пароль LUKS
передаётся в `cryptsetup` через `--key-file -` и stdin, затем переменная
удаляется.

### `lib/storage.sh`

Поиск дисков, проверки безопасности, GPT, FAT32/ext4/Btrfs/XFS, Btrfs-подтомы,
монтирование и размонтирование.

Проверка безопасности (`storage_disk_safety_problem`) отклоняет:

- не блочное устройство;
- диск live-системы и текущего корня;
- диск меньше 24 GiB;
- любой смонтированный раздел (включая whole-disk mount);
- активный swap;
- активные `crypt`, `lvm`, `raid*`, `mpath` и любые sysfs holders.

### `lib/config.sh`

Настройка установленной системы: hostname, `/etc/hosts`, локаль, `vconsole`,
часовой пояс, пользователь, пароли, sudoers, службы, zram. Функции генерации
содержимого отделены от записи в `$TARGET`.

### `lib/boot.sh`

`mkinitcpio.conf` (hook `encrypt`, модуль ФС), `mkinitcpio -P`, установка
systemd-boot, `loader.conf`, загрузочная запись с микрокодом и проверка.
`bootctl install` вызывается до записи `loader.conf`, чтобы наша конфигурация
не была перезаписана. Если NVRAM недоступен, выполняется
`bootctl --no-variables install`.

### `lib/install.sh`

`pacman -Sy`, обновление keyring, `pacstrap -K`, копирование журнала,
финальная проверка (`bootctl status`, `findmnt --verify`).

### `lib/recovery.sh`

`flock`-блокировка, trap на EXIT/INT/TERM/HUP, безопасное размонтирование и
закрытие LUKS, понятные сообщения при сбое.

### `lib/plugins.sh`

Локальные файлы `plugins/*.sh`. Хук — функция
`plugin_<имя>_<hook>` (`pre_install`, `post_install`, `pre_reboot`). Плагины не
скачиваются автоматически.

## Соглашения об именах

- `storage_*` — диски и ФС;
- `validate_*` — проверки;
- `config_*` — настройка target;
- `boot_*` — загрузчик;
- `install_*` — pacstrap и проверка;
- `recovery_*` — lock/cleanup;
- `workflow_*` — интерактивный сценарий;
- `ui_*`, `hw_*`, `network_*`, `security_*` — соответствующие области.

## Тестируемость

Чистые функции (генерация файлов, разбор размеров, имена разделов,
загрузочные аргументы) тестируются напрямую. Функции, требующие системы,
изолированы: в тестах подменяются `pacman`, `lsblk`, `findmnt`,
`storage_is_block_device`, `arch-chroot`.
