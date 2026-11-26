#!/usr/bin/env python3
"""PTY tests for lib/tui.py.

Curses needs a real terminal, so these tests run the helper in a pseudo
terminal, send keystrokes and verify both the rendered text and the value
returned on fd 3.
"""

from __future__ import annotations

import fcntl
import os
import pty
import re
import select
import struct
import sys
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TUI = os.path.join(ROOT, "lib", "tui.py")

STEPS = "Network|Hardware|Profile|Kernel|Filesystem|Disk|System|Encryption|Packages|Summary|Install"


def strip_ansi(data):
    text = data.decode("utf-8", "replace")
    return re.sub(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][A-Z0-9]|\x1b[=>]", "", text)


def run(args, keys=b"\r", env=None, size=(30, 100), feed=None, timeout=8):
    result_r, result_w = os.pipe()
    feed_r, feed_w = os.pipe()
    pid, master = pty.fork()
    if pid == 0:
        os.close(result_r)
        os.close(feed_w)
        os.dup2(result_w, 3)
        os.dup2(feed_r, 5)
        os.set_inheritable(3, True)
        os.set_inheritable(5, True)
        os.close(result_w)
        if feed_r != 5:
            os.close(feed_r)
        os.environ.update(
            {
                "TERM": "xterm-256color",
                "LANG": "C.UTF-8",
                "LC_ALL": "C.UTF-8",
                "AS_UI_STEPS": STEPS,
                "AS_UI_STEP_INDEX": "2",
                "AS_UI_VERSION": "0.11.0",
            }
        )
        if env:
            os.environ.update(env)
        os.execvp(sys.executable, [sys.executable, TUI] + args)

    os.close(result_w)
    os.close(feed_r)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", size[0], size[1], 0, 0))

    output = b""
    result = b""
    sent = False
    deadline = time.time() + timeout
    while time.time() < deadline:
        ready, _, _ = select.select([master, result_r], [], [], 0.1)
        if master in ready:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                break
            output += chunk
        if result_r in ready:
            try:
                chunk = os.read(result_r, 65536)
            except OSError:
                chunk = b""
            result += chunk
            if not chunk:
                break
        if not sent and output:
            time.sleep(0.3)
            if feed:
                for line in feed:
                    payload = line.encode() if isinstance(line, str) else line
                    try:
                        os.write(feed_w, payload)
                    except BrokenPipeError:
                        pass
            try:
                os.close(feed_w)
            except OSError:
                pass
            os.write(master, keys)
            sent = True

    try:
        os.close(master)
    except OSError:
        pass
    try:
        os.close(result_r)
    except OSError:
        pass
    try:
        os.close(feed_w)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    return strip_ansi(output), result.decode("utf-8", "replace"), os.waitstatus_to_exitcode(status)


def main():
    failures = 0

    def check(name, condition, detail=""):
        nonlocal failures
        if condition:
            print(f"  - {name}")
        else:
            failures += 1
            print(f"  FAIL: {name} {detail}", file=sys.stderr)

    text, result, code = run(
        [
            "menu",
            "--title",
            "Profile",
            "--prompt",
            "Choose the system profile",
            "--item",
            "minimal|Minimal|console",
            "--item",
            "basic|Basic|GNOME",
        ]
    )
    check("menu returns the selected tag", code == 0 and result == "minimal", f"code={code} result={result!r}")
    check("menu renders the title", "Profile" in text)
    check("menu renders the step sidebar", all(label in text for label in ("Network", "Profile", "Install")))

    text, result, code = run(
        ["menu", "--title", "Profile", "--prompt", "Choose", "--item", "a|A", "--item", "b|B"],
        keys=b"\x1b",
    )
    check("Escape cancels a menu", code == 1 and result == "", f"code={code} result={result!r}")

    text, result, code = run(
        ["input", "--title", "Hostname", "--prompt", "Hostname", "--initial", ""],
        keys=b"myhost\r",
    )
    check("input returns typed text", code == 0 and result == "myhost", f"code={code} result={result!r}")

    text, result, code = run(
        ["password", "--title", "Password", "--prompt", "Enter password"],
        keys=b"s3cret\r",
    )
    check("password returns its value", code == 0 and result == "s3cret", f"code={code}")
    check("password is not rendered on screen", "s3cret" not in text)

    _, _, code = run(["confirm", "--title", "Question", "--prompt", "Continue?"], keys=b"y")
    check("confirm accepts yes", code == 0, f"code={code}")
    _, _, code = run(["confirm", "--title", "Question", "--prompt", "Continue?"], keys=b"n")
    check("confirm accepts no", code == 1, f"code={code}")

    text, _, code = run(["msg", "--title", "Summary", "--message", "All done"], keys=b"\r")
    check("message box closes with Enter", code == 0 and "All done" in text, f"code={code}")

    text, _, code = run(
        ["program", "--title", "Install", "--prompt", "Running", "--fd", "5"],
        feed=["line-one\n", "line-two\n"],
    )
    check("program screen shows command output", code == 0 and "line-one" in text and "line-two" in text, f"code={code}")

    text, result, code = run(
        [
            "splash",
            "--app-version",
            "0.11.0",
            "--item",
            "install|Start installation|Configure",
            "--item",
            "exit|Exit|Close",
        ]
    )
    check("splash returns install", code == 0 and result == "install", f"code={code} result={result!r}")
    check("splash shows the installer name", "ArchinstallSuper" in text)

    text, result, code = run(
        ["menu", "--title", "ASCII", "--prompt", "Test", "--item", "one|First"],
        env={"AS_UI_ASCII": "1"},
    )
    check("ASCII fallback still works", code == 0 and result == "one" and "ASCII" in text, f"code={code}")

    text, result, code = run(
        ["menu", "--title", "Linux", "--prompt", "Test", "--item", "one|First"],
        env={"TERM": "linux"},
        size=(25, 80),
    )
    check("linux console terminal works", code == 0 and result == "one", f"code={code}")
    check("80-column terminal shows the step sidebar", "STEPS" in text and "Network" in text)

    if failures:
        print(f"\n{failures} TUI checks failed", file=sys.stderr)
        return 1
    print("\nAll TUI checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
