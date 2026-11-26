# Тестирование

## Быстрый запуск

```bash
bash tests/run-tests.sh
```

Запускать можно обычным пользователем: тесты не трогают реальные диски и не
вызывают `pacstrap`, `sgdisk`, `mkfs`, `cryptsetup`, `bootctl`. Полный набор
сейчас состоит из **14 шагов**; TUI-тесты используют псевдотерминал (PTY) и
не требуют графической среды.

Для ShellCheck:

```bash
shellcheck --severity=warning -x install.sh lib/*.sh tests/*.sh \
  tests/unit/*.sh tests/lib/*.sh tests/integration/*.sh
```

## Что покрыто

| Файл | Проверки |
| --- | --- |
| `tests/syntax-check.sh` | `bash -n` для всех скриптов |
| `tests/static-checks.sh` | запрет `archinstall`, `eval`, паролей в логах; обязательные защитные паттерны; ShellCheck |
| `tests/unit/core-test.sh` | размеры, разбор размеров, имена пакетов, массивы |
| `tests/unit/storage-test.sh` | имена разделов SATA/NVMe/eMMC/loop, разбор `lsblk`, mount options, safety-проверки (mounted, LUKS/LVM/RAID, swap, idle) |
| `tests/unit/boot-test.sh` | kernel cmdline для ext4/Btrfs/LUKS, entry, hooks, modules, микрокод, запись entry |
| `tests/unit/validation-test.sh` | hostname, пользователь, TZ, локаль, keymap, пароли, пакеты, fstab, `subvol=/@`, `subvol=/@home`, tmpfs-root |
| `tests/unit/packages-test.sh` | наличие пакетов, группы, отсутствующие пакеты, размер через поддельный `pacman` |
| `tests/unit/config-test.sh` | `/etc/hosts`, locale/vconsole, zram, sudoers, display manager |
| `tests/unit/security-test.sh` | политика паролей, LUKS-аргументы, очистка переменных |
| `tests/unit/recovery-test.sh` | очистка до/во время установки, закрытие LUKS, размонтирование |
| `tests/unit/ui-test.sh` | меню, подтверждение, ввод, пароль (plain-бэкенд) |
| `tests/unit/tui-test.sh` | полноэкранный TUI в настоящем PTY: меню, боковая панель, Esc, ввод, маскировка пароля, подтверждения, сообщения, вывод команды, splash, ASCII, `TERM=linux` |
| `tests/unit/cli-test.sh` | `--version`, `--help`, неизвестный аргумент, отсутствие `archinstall`, синтаксис |
| `tests/unit/workflow-test.sh` | состав пакетов, предупреждение о стирании, порядок этапов |

## Изоляция от системы

- `AS_TEST=1` отключает `flock` и traps.
- `AS_LOG_TO_FILE=0` отключает перенаправление журнала.
- `TARGET` указывает во временный каталог.
- В тестах подменяются команды: `pacman`, `lsblk`, `findmnt`,
  `storage_is_block_device`, `arch-chroot`.
- `tests/lib/harness.sh` содержит утверждения (`assert_eq`, `assert_contains`,
  `assert_fails`, ...) и счётчик тестов.
- `tests/lib/tui_pty.py` запускает `lib/tui.py` в PTY, отправляет клавиши и
  проверяет как отрисованный текст, так и значение, возвращённое через fd 3.

## CI

`.github/workflows/ci.yml` и `.github/workflows/quality.yml` устанавливают
ShellCheck и запускают `bash tests/run-tests.sh` на Ubuntu. CI не запускает
QEMU-тест.

## Интеграционный тест в UEFI-виртуальной машине

Требуются `qemu-system-x86_64`, OVMF (`edk2-ovmf`/`ovmf`) и официальный ISO.

```bash
export ARCH_ISO=/path/to/archlinux-*.iso
bash tests/integration/qemu-uefi.sh
```

Скрипт создаёт пустой qcow2-диск, поднимает UEFI-VM с OVMF и предлагает
пошаговый чек-лист. Установка выполняется вручную, потому что установщик
намеренно требует явных подтверждений перед стиранием диска. После установки
нужно перезагрузить ту же VM без ISO и проверить systemd-boot, LUKS/Btrfs и
службы.

Подробнее: [../tests/integration/README.md](../tests/integration/README.md).

## Почему нет автоматического QEMU-теста

Автоматизация требует неинтерактивного режима установки. Такой режим — это
отдельная деструктивная возможность, которую нельзя добавлять без ревью и
отдельных тестов. Пока его нет, интеграционный тест остаётся ручным и явно
помечен как таковой.

## Перед реальной установкой

1. Прогнать `bash tests/run-tests.sh`.
2. Прогнать установку в QEMU/UEFI на пустом виртуальном диске.
3. Перезагрузить VM и проверить загрузку.
4. Сделать резервную копию данных на реальном компьютере.
5. Убедиться, что выбран правильный диск (установщик сотрёт его целиком).
