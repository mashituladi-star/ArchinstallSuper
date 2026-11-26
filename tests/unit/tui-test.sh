#!/usr/bin/env bash
# Tests for the full-screen Python/curses interface. These use a real PTY, so
# they exercise the same code path as the installer on the Arch ISO.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

python3 -m py_compile "$ROOT/lib/tui.py"
python3 "$ROOT/tests/lib/tui_pty.py"
