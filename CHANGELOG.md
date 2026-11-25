# Changelog

## 0.10.0 — 2026-11-25

Аудит и модернизация установщика. Ветка `feature/v1-audit-modernization`.

### Добавлено

- Модульная архитектура: `install.sh` + `lib/*.sh`.
- CLI: `--check`, `--dry-run`, `--plain`, `--debug`, `--log`, `--version`,
  `--help`.
- XFS и выбор ядра (`linux`, `linux-lts`, `linux-zen`, `linux-hardened`).
- LUKS2 с argon2id, aes-xts-plain64 и безопасной передачей пароля через stdin.
- Btrfs-подтомы `@`, `@home`, `@var_log`, `@snapshots`, сжатие zstd.
- Предполётная проверка пакетов и оценка размера установки до разметки.
- Проверка fstab, загрузочной записи, initramfs, systemd-boot и результата
  установки.
- Lock-файл, traps, безопасное размонтирование и закрытие LUKS при сбое.
- Определение оборудования, Secure Boot, микрокода, GPU и сети.
- Wi-Fi в live-среде через `iwctl`.
- zram через `zram-generator`.
- Плагины-хуки `plugins/*.sh`.
- Unit-тесты (13 шагов), включая поддельный `pacman`, safety-проверки диска и
  проверки recovery.
- `tests/integration/qemu-uefi.sh` для ручного UEFI-теста в QEMU.
- Документация: `docs/ARCHITECTURE.md`, `docs/AUDIT.md`, `docs/TESTING.md`,
  `docs/RECOVERY.md`.

### Исправлено

- `dialog` возвращает значения через `--stdout`, а не `--output-fd 3`.
- Btrfs-загрузка всегда получает `rootflags=subvol=@`.
- Разбор модели диска с пробелами.
- Текстовый выбор диска возвращает устройство, а не индекс.
- `subvol=/@` из `genfstab` принимается как корневой подтом.
- `umask 077` больше не делает файлы target закрытыми для чтения.
- `network_ensure` получает инициализированный UI.
- `bootctl install` не перезаписывает наш `loader.conf`.
- Парсинг размера пакетов не зависит от локали.
- Safety-проверка диска учитывает sysfs holders и whole-disk mount/swap.
- Удалён устаревший `tests/profile-config-check.py`.
- CI запускает полный набор тестов.

### Ограничения

- Только UEFI x86_64 и systemd-boot.
- Только разметка «весь диск».
- Secure Boot не подписывается.
- Шифруется только корень, `/boot` открыт.
- Нет swap-раздела/файла, только zram.
- Нет неинтерактивного конфига.
- Реальная установка в QEMU/UEFI ещё не выполнена в среде аудита.

## 0.9.0

- Базовая поддержка Btrfs и исправление загрузочных флагов (PR #1).
- Предварительная проверка и статические проверки.

## 0.8.0 и ранее

- Ранний монолитный прототип.
