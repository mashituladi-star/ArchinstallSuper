#!/usr/bin/env python3
"""Modern full-screen TUI for ArchinstallSuper.

The shell workflow calls this helper once per screen.  The interface is drawn
on stdout, which the shell redirects to the controlling terminal.  The value
selected by the user is written to file descriptor 3, which is the command
substitution pipe.  Nothing is ever written to fd 3 for passwords unless the
caller explicitly asked for a password value.

The helper is deliberately stateless: every invocation renders one screen and
exits.  That keeps the Bash workflow simple and means a crashed screen cannot
leave the terminal in a broken state.
"""

from __future__ import annotations

import argparse
import curses
import locale
import os
import queue
import sys
import textwrap
import threading
import time
from collections import deque

APP_NAME = "ArchinstallSuper"
DEFAULT_VERSION = "0.11.0"

DEFAULT_STEPS = [
    "Сеть",
    "Железо",
    "Профиль",
    "Ядро",
    "Файлы",
    "Диск",
    "Система",
    "Шифрование",
    "Пакеты",
    "Итог",
    "Установка",
]

LOGO = [
    " █████╗ ██████╗  ██████╗██╗  ██╗",
    "██╔══██╗██╔══██╗██╔════╝██║  ██║",
    "███████║██████╔╝██║     ███████║",
    "██╔══██║██╔══██╗██║     ██╔══██║",
    "██║  ██║██║  ██║╚██████╗██║  ██║",
    "╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝",
]

LOGO_ASCII = [
    r"    _    ____   ____ _   _ ",
    r"   / \  |  _ \ / ___| | | |",
    r"  / _ \ | |_) | |   | |_| |",
    r" / ___ \|  _ <| |___|  _  |",
    r"/_/   \_\_| \_\____|_| |_|",
    r"                           ",
]


# ---------------------------------------------------------------------------
# Theme
# ---------------------------------------------------------------------------


class Theme:
    """Curses colour pairs with a safe 8-colour fallback."""

    def __init__(self, scr):
        self.scr = scr
        self.unicode = _is_utf8()
        self.color = False
        self.pairs = {}
        if curses.has_colors():
            try:
                curses.start_color()
                try:
                    curses.use_default_colors()
                except curses.error:
                    pass
                self.color = True
            except curses.error:
                self.color = False
        if self.color:
            self._init_pairs()

    @staticmethod
    def _c(c256, c8):
        return c256 if curses.COLORS >= 256 else c8

    def _pair(self, name, fg, bg, attr=0):
        if not self.color:
            self.pairs[name] = attr
            return
        number = len(self.pairs) + 1
        try:
            curses.init_pair(number, fg, bg)
            self.pairs[name] = curses.color_pair(number) | attr
        except curses.error:
            self.pairs[name] = attr

    def _init_pairs(self):
        c = curses
        self._pair("bg", self._c(250, c.COLOR_WHITE), self._c(234, c.COLOR_BLACK))
        self._pair("window", self._c(252, c.COLOR_WHITE), self._c(235, c.COLOR_BLACK))
        self._pair("border", self._c(51, c.COLOR_CYAN), self._c(235, c.COLOR_BLACK))
        self._pair("border_dim", self._c(240, c.COLOR_BLUE), self._c(235, c.COLOR_BLACK))
        self._pair("title", self._c(234, c.COLOR_BLACK), self._c(51, c.COLOR_CYAN), c.A_BOLD)
        self._pair("title_dim", self._c(238, c.COLOR_BLACK), self._c(51, c.COLOR_CYAN))
        self._pair("accent", self._c(51, c.COLOR_CYAN), self._c(235, c.COLOR_BLACK), c.A_BOLD)
        self._pair("text", self._c(252, c.COLOR_WHITE), self._c(235, c.COLOR_BLACK))
        self._pair("dim", self._c(245, c.COLOR_WHITE), self._c(235, c.COLOR_BLACK), c.A_DIM)
        self._pair("success", self._c(114, c.COLOR_GREEN), self._c(235, c.COLOR_BLACK))
        self._pair("warn", self._c(221, c.COLOR_YELLOW), self._c(235, c.COLOR_BLACK))
        self._pair("error", self._c(203, c.COLOR_RED), self._c(235, c.COLOR_BLACK), c.A_BOLD)
        self._pair("selected", self._c(234, c.COLOR_BLACK), self._c(51, c.COLOR_CYAN), c.A_BOLD)
        self._pair("selected_dim", self._c(238, c.COLOR_BLACK), self._c(51, c.COLOR_CYAN))
        self._pair("button", self._c(234, c.COLOR_BLACK), self._c(51, c.COLOR_CYAN), c.A_BOLD)
        self._pair("button_off", self._c(252, c.COLOR_WHITE), self._c(239, c.COLOR_BLUE))
        self._pair("sidebar", self._c(250, c.COLOR_WHITE), self._c(234, c.COLOR_BLACK))
        self._pair("sidebar_current", self._c(234, c.COLOR_BLACK), self._c(51, c.COLOR_CYAN), c.A_BOLD)
        self._pair("sidebar_done", self._c(114, c.COLOR_GREEN), self._c(234, c.COLOR_BLACK))
        self._pair("progress", self._c(51, c.COLOR_CYAN), self._c(239, c.COLOR_BLUE))
        self._pair("progress_bg", self._c(239, c.COLOR_BLUE), self._c(239, c.COLOR_BLUE))
        self._pair("shadow", self._c(233, c.COLOR_BLACK), self._c(233, c.COLOR_BLACK))
        self._pair("red", self._c(203, c.COLOR_RED), self._c(51, c.COLOR_CYAN))
        self._pair("yellow", self._c(221, c.COLOR_YELLOW), self._c(51, c.COLOR_CYAN))
        self._pair("green", self._c(114, c.COLOR_GREEN), self._c(51, c.COLOR_CYAN))

    def a(self, name):
        return self.pairs.get(name, 0)


def _is_utf8():
    encoding = (sys.stdout.encoding or "").lower()
    return "utf" in encoding and os.environ.get("AS_UI_ASCII", "0") != "1"


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------


class Screen:
    """A centred application window with a title bar, sidebar and footer."""

    def __init__(self, scr, theme):
        self.scr = scr
        self.t = theme
        self.unicode = theme.unicode
        self.h, self.w = scr.getmaxyx()
        self.y, self.x, self.win_h, self.win_w = self._geometry()
        self.sidebar_w = 0
        self.main_x = self.x + 3
        self.main_w = max(1, self.win_w - 6)
        self.content_y = self.y + 3
        self.content_h = max(1, self.win_h - 6)

    def _geometry(self):
        h, w = self.h, self.w
        win_w = min(max(60, w - 2), 100)
        win_h = min(max(18, h - 2), 30)
        win_w = min(win_w, w)
        win_h = min(win_h, h)
        y = max(0, (h - win_h) // 2)
        x = max(0, (w - win_w) // 2)
        return y, x, win_h, win_w

    # -- primitives --------------------------------------------------------

    def put(self, y, x, text, attr=0):
        if y < 0 or y >= self.h or x >= self.w:
            return
        text = str(text).replace("\t", "    ")
        if x < 0:
            text = text[-x:]
            x = 0
        text = text[: max(0, self.w - x)]
        try:
            self.scr.addstr(y, x, text, attr)
        except curses.error:
            pass

    def fill(self, y, x, h, w, ch=" ", attr=0):
        if h <= 0 or w <= 0:
            return
        line = (ch or " ")[:1] * max(0, w)
        for row in range(y, min(y + h, self.h)):
            if x >= self.w:
                break
            try:
                self.scr.addstr(row, max(0, x), line[: max(0, self.w - max(0, x))], attr)
            except curses.error:
                pass

    def hline(self, y, x, w, attr, ch=None):
        ch = ch or ("─" if self.unicode else "-")
        self.put(y, x, ch * max(0, w), attr)

    def vline(self, y, x, h, attr):
        ch = "│" if self.unicode else "|"
        for row in range(y, y + h):
            self.put(row, x, ch, attr)

    def box(self, y, x, h, w, attr):
        if h < 2 or w < 2:
            return
        if self.unicode:
            tl, tr, bl, br, hz, vt = "╭", "╮", "╰", "╯", "─", "│"
        else:
            tl = tr = bl = br = "+"
            hz, vt = "-", "|"
        self.put(y, x, tl + hz * (w - 2) + tr, attr)
        for row in range(y + 1, y + h - 1):
            self.put(row, x, vt, attr)
            self.put(row, x + w - 1, vt, attr)
        self.put(y + h - 1, x, bl + hz * (w - 2) + br, attr)

    # -- chrome ------------------------------------------------------------

    def chrome(self, title, footer, steps=None, step_index=-1, version=DEFAULT_VERSION):
        try:
            self.scr.bkgd(" ", self.t.a("bg"))
        except curses.error:
            pass
        self.scr.erase()

        # Drop shadow, then the window itself.
        self.fill(self.y + 1, self.x + 2, self.win_h, self.win_w, " ", self.t.a("shadow"))
        self.fill(self.y, self.x, self.win_h, self.win_w, " ", self.t.a("window"))
        self.box(self.y, self.x, self.win_h, self.win_w, self.t.a("border"))

        # Title bar.
        self.fill(self.y + 1, self.x + 1, 1, self.win_w - 2, " ", self.t.a("title"))
        dots = "● ● ●" if self.unicode else "o o o"
        self.put(self.y + 1, self.x + 2, dots, self.t.a("title"))
        for offset, name in ((2, "red"), (4, "yellow"), (6, "green")):
            self.put(self.y + 1, self.x + offset, "●" if self.unicode else "o", self.t.a(name))
        self.put(self.y + 1, self.x + 10, APP_NAME, self.t.a("title"))
        right = f"v{version}  ·  UEFI"
        self.put(self.y + 1, self.x + self.win_w - 2 - len(right), right, self.t.a("title_dim"))

        self.hline(self.y + 2, self.x + 1, self.win_w - 2, self.t.a("border_dim"))

        # Footer.
        self.hline(self.y + self.win_h - 3, self.x + 1, self.win_w - 2, self.t.a("border_dim"))
        self.fill(self.y + self.win_h - 2, self.x + 1, 1, self.win_w - 2, " ", self.t.a("window"))
        self.put(self.y + self.win_h - 2, self.x + 2, footer, self.t.a("dim"))

        # Sidebar.
        steps = steps or []
        if steps and self.win_w >= 76:
            self.sidebar_w = 24
            sx = self.x + 1
            sy = self.y + 3
            sh = self.win_h - 6
            self.fill(sy, sx, sh, self.sidebar_w, " ", self.t.a("sidebar"))
            self.put(sy, sx + 2, "ЭТАПЫ", self.t.a("dim"))
            visible = max(1, sh - 2)
            start = 0
            if step_index >= visible:
                start = step_index - visible + 1
            for i in range(start, min(len(steps), start + visible)):
                row = sy + 1 + (i - start)
                if i == step_index:
                    attr = self.t.a("sidebar_current")
                    self.fill(row, sx, 1, self.sidebar_w, " ", attr)
                    icon = "●"
                elif step_index >= 0 and i < step_index:
                    attr = self.t.a("sidebar_done")
                    icon = "✓"
                else:
                    attr = self.t.a("sidebar")
                    icon = "○"
                text = f"  {icon}  {steps[i]}"
                self.put(row, sx, text[: self.sidebar_w], attr)
            self.vline(sy, self.x + self.sidebar_w + 1, sh, self.t.a("border_dim"))
            self.main_x = self.x + self.sidebar_w + 3
            self.main_w = max(1, self.win_w - self.sidebar_w - 5)
        else:
            self.main_x = self.x + 3
            self.main_w = max(1, self.win_w - 6)
        self.content_y = self.y + 3
        self.content_h = max(1, self.win_h - 6)

        # Content heading.
        self.put(self.content_y, self.main_x, title, self.t.a("accent"))
        return self.content_y + 2

    def prompt(self, row, text):
        for line in wrap(text, self.main_w):
            self.put(row, self.main_x, line, self.t.a("dim"))
            row += 1
        return row

    def buttons(self, row, labels, selected):
        x = self.main_x
        for i, label in enumerate(labels):
            text = f"  {label}  "
            attr = self.t.a("button") if i == selected else self.t.a("button_off")
            self.put(row, x, text, attr)
            x += len(text) + 2
        return row


def wrap(text, width):
    lines = []
    for paragraph in str(text).split("\n"):
        if not paragraph:
            lines.append("")
            continue
        lines.extend(
            textwrap.wrap(
                paragraph,
                width=max(1, width),
                break_long_words=False,
                break_on_hyphens=False,
            )
            or [""]
        )
    return lines


# ---------------------------------------------------------------------------
# Argument helpers
# ---------------------------------------------------------------------------


def parse_items(raw_items):
    items = []
    for raw in raw_items or []:
        parts = raw.split("|")
        tag = parts[0] if parts else ""
        label = parts[1] if len(parts) > 1 else tag
        desc = parts[2] if len(parts) > 2 else ""
        items.append((tag, label, desc))
    return items


def steps_from_args(args):
    raw = args.steps or os.environ.get("AS_UI_STEPS", "")
    steps = [part for part in raw.split("|") if part]
    if not steps:
        steps = []
    try:
        index = int(args.step_index)
    except (TypeError, ValueError):
        try:
            index = int(os.environ.get("AS_UI_STEP_INDEX", "-1"))
        except ValueError:
            index = -1
    return steps, index


def app_version(args):
    return args.app_version or os.environ.get("AS_UI_VERSION", DEFAULT_VERSION)


def emit(value, fd=3):
    if value is None:
        return
    data = str(value).encode("utf-8", "replace")
    try:
        os.write(fd, data)
    except OSError:
        try:
            sys.stdout.write(str(value))
            sys.stdout.flush()
        except Exception:
            pass


def read_key(scr):
    try:
        return scr.get_wch()
    except curses.error:
        return None
    except KeyboardInterrupt:
        return 27


def key_in(ch, *keys):
    """Match a key returned by get_wch against ints and single characters."""
    for key in keys:
        if isinstance(key, str):
            if ch == key or (len(key) == 1 and ch == ord(key)):
                return True
        elif ch == key:
            return True
    return False


def is_enter(ch):
    return key_in(ch, curses.KEY_ENTER, 10, 13, "\n", "\r")


def is_escape(ch):
    return key_in(ch, 27, "\x1b")


def is_up(ch):
    return key_in(ch, curses.KEY_UP, "k")


def is_down(ch):
    return key_in(ch, curses.KEY_DOWN, "j")


def is_left(ch):
    return key_in(ch, curses.KEY_LEFT, "h", "a")


def is_right(ch):
    return key_in(ch, curses.KEY_RIGHT, "l", "d")


# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------


def screen_splash(scr, args):
    theme = Theme(scr)
    items = parse_items(args.item) or [
        ("install", "Начать установку", "Настроить и установить Arch Linux"),
        ("exit", "Выход", "Закрыть установщик"),
    ]
    selected = 0
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    logo = LOGO if theme.unicode else LOGO_ASCII

    while True:
        s = Screen(scr, theme)
        row = s.chrome("", "↑/↓ выбрать   Enter запустить   Esc выход", steps, step_index, version)
        logo_width = max(len(line) for line in logo)
        logo_x = s.main_x + max(0, (s.main_w - logo_width) // 2)
        for line in logo:
            s.put(row, logo_x, line, theme.a("accent"))
            row += 1
        row += 1
        subtitle = "Arch Linux  ·  UEFI Installer  ·  2026"
        s.put(row, s.main_x + max(0, (s.main_w - len(subtitle)) // 2), subtitle, theme.a("dim"))
        row += 1
        tagline = "Безопасная установка без archinstall"
        s.put(row, s.main_x + max(0, (s.main_w - len(tagline)) // 2), tagline, theme.a("text"))
        row += 2

        for i, (tag, label, desc) in enumerate(items):
            if i == selected:
                s.fill(row, s.main_x - 1, 1, s.main_w + 1, " ", theme.a("selected"))
                s.put(row, s.main_x, f"  {label}", theme.a("selected"))
                if desc:
                    s.put(row, s.main_x + len(label) + 5, desc[: max(0, s.main_w - len(label) - 6)], theme.a("selected_dim"))
            else:
                s.put(row, s.main_x, f"  {label}", theme.a("text"))
                if desc:
                    s.put(row, s.main_x + len(label) + 5, desc[: max(0, s.main_w - len(label) - 6)], theme.a("dim"))
            row += 2

        s.put(s.y + s.win_h - 2, s.x + s.win_w - 26, "ArchinstallSuper 2026", theme.a("dim"))
        scr.refresh()
        ch = read_key(scr)
        if is_up(ch):
            selected = max(0, selected - 1)
        elif is_down(ch):
            selected = min(len(items) - 1, selected + 1)
        elif is_enter(ch):
            return items[selected][0]
        elif is_escape(ch) or key_in(ch, "q"):
            return "exit"
        elif ch == curses.KEY_RESIZE:
            continue


def screen_menu(scr, args):
    theme = Theme(scr)
    items = parse_items(args.item)
    if not items:
        return None
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    selected = 0
    for i, item in enumerate(items):
        if args.default and item[0] == args.default:
            selected = i
            break
    top = 0
    footer = "↑/↓ выбрать   Enter подтвердить   Esc отмена"
    if args.no_cancel:
        footer = "↑/↓ выбрать   Enter подтвердить"

    while True:
        s = Screen(scr, theme)
        row = s.chrome(args.title, footer, steps, step_index, version)
        row = s.prompt(row, args.prompt) + 1
        visible = max(1, s.content_y + s.content_h - row - 2)
        if selected < top:
            top = selected
        if selected >= top + visible:
            top = selected - visible + 1

        for i in range(top, min(len(items), top + visible)):
            tag, label, desc = items[i]
            y = row + (i - top)
            if i == selected:
                s.fill(y, s.main_x - 1, 1, s.main_w + 1, " ", theme.a("selected"))
                s.put(y, s.main_x, "› " + label, theme.a("selected"))
                if desc:
                    dx = s.main_x + len(label) + 3
                    if dx < s.main_x + s.main_w:
                        s.put(y, dx, desc[: max(0, s.main_x + s.main_w - dx)], theme.a("selected_dim"))
            else:
                s.put(y, s.main_x, "  " + label, theme.a("text"))
                if desc:
                    dx = s.main_x + len(label) + 3
                    if dx < s.main_x + s.main_w:
                        s.put(y, dx, desc[: max(0, s.main_x + s.main_w - dx)], theme.a("dim"))

        if len(items) > visible:
            bar_x = s.main_x + s.main_w
            bar_h = visible
            thumb = max(1, bar_h * visible // len(items))
            pos = 0 if len(items) <= visible else (bar_h - thumb) * top // max(1, len(items) - visible)
            for i in range(bar_h):
                ch = "█" if pos <= i < pos + thumb else "░"
                s.put(row + i, bar_x, ch, theme.a("accent") if pos <= i < pos + thumb else theme.a("border_dim"))

        scr.refresh()
        ch = read_key(scr)
        if is_up(ch):
            selected = max(0, selected - 1)
        elif is_down(ch):
            selected = min(len(items) - 1, selected + 1)
        elif ch == curses.KEY_PPAGE:
            selected = max(0, selected - visible)
        elif ch == curses.KEY_NPAGE:
            selected = min(len(items) - 1, selected + visible)
        elif ch == curses.KEY_HOME:
            selected = 0
        elif ch == curses.KEY_END:
            selected = len(items) - 1
        elif is_enter(ch):
            return items[selected][0]
        elif (is_escape(ch) or key_in(ch, "q")) and not args.no_cancel:
            return None
        elif ch == curses.KEY_RESIZE:
            continue


def screen_input(scr, args):
    theme = Theme(scr)
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    text = args.initial or ""
    cursor = len(text)
    label = args.label or "Значение"
    footer = "Enter подтвердить   Esc отмена"

    while True:
        s = Screen(scr, theme)
        row = s.chrome(args.title, footer, steps, step_index, version)
        row = s.prompt(row, args.prompt) + 1
        s.put(row, s.main_x, label, theme.a("dim"))
        row += 1
        field_w = max(20, min(s.main_w, 64))
        s.fill(row, s.main_x, 3, field_w, " ", theme.a("window"))
        s.box(row, s.main_x, 3, field_w, theme.a("border"))
        inner_w = field_w - 4
        shown = ("•" if theme.unicode else "*") * len(text) if args.password else text
        start = 0
        if cursor > inner_w:
            start = cursor - inner_w
        visible = shown[start : start + inner_w]
        s.put(row + 1, s.main_x + 2, visible, theme.a("text"))
        cx = s.main_x + 2 + (cursor - start)
        if cx < s.main_x + field_w - 2:
            if cursor < len(shown):
                s.put(row + 1, cx, shown[cursor], theme.a("selected"))
            else:
                s.put(row + 1, cx, " ", theme.a("selected"))
            try:
                scr.move(row + 1, cx)
                curses.curs_set(1)
            except curses.error:
                pass
        else:
            try:
                curses.curs_set(0)
            except curses.error:
                pass

        hint_row = row + 3
        if args.help_text:
            for line in wrap(args.help_text, s.main_w):
                s.put(hint_row, s.main_x, line, theme.a("dim"))
                hint_row += 1
        if args.password:
            s.put(hint_row, s.main_x, "Ввод скрыт. Пароль не записывается в журнал.", theme.a("dim"))

        scr.refresh()
        ch = read_key(scr)
        if ch is None:
            continue
        if isinstance(ch, str):
            if ch in ("\n", "\r"):
                return text
            if ch == "\x1b":
                return None
            if ch in ("\x7f", "\b"):
                if cursor > 0:
                    text = text[: cursor - 1] + text[cursor:]
                    cursor -= 1
            elif ch == "\x15":  # Ctrl-U
                text = ""
                cursor = 0
            elif ch == "\x17":  # Ctrl-W
                end = cursor
                while cursor > 0 and text[cursor - 1].isspace():
                    cursor -= 1
                while cursor > 0 and not text[cursor - 1].isspace():
                    cursor -= 1
                text = text[:cursor] + text[end:]
            elif ch.isprintable():
                text = text[:cursor] + ch + text[cursor:]
                cursor += 1
        elif is_enter(ch):
            return text
        elif is_escape(ch):
            return None
        elif ch in (curses.KEY_BACKSPACE, 8, 127):
            if cursor > 0:
                text = text[: cursor - 1] + text[cursor:]
                cursor -= 1
        elif ch == curses.KEY_DC:
            if cursor < len(text):
                text = text[:cursor] + text[cursor + 1 :]
        elif ch == curses.KEY_LEFT:
            cursor = max(0, cursor - 1)
        elif ch == curses.KEY_RIGHT:
            cursor = min(len(text), cursor + 1)
        elif ch == curses.KEY_HOME:
            cursor = 0
        elif ch == curses.KEY_END:
            cursor = len(text)
        elif ch == curses.KEY_RESIZE:
            continue


def screen_password(scr, args):
    args.password = True
    return screen_input(scr, args)


def screen_confirm(scr, args):
    theme = Theme(scr)
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    labels = [args.yes_label or "Да", args.no_label or "Нет"]
    selected = 1 if args.default == "no" else 0
    footer = "←/→ выбрать   Enter подтвердить   y/n   Esc отмена"

    while True:
        s = Screen(scr, theme)
        row = s.chrome(args.title or "Подтверждение", footer, steps, step_index, version)
        row = s.prompt(row, args.prompt) + 2
        s.buttons(row, labels, selected)
        s.put(row + 3, s.main_x, "Enter — подтвердить выбор, Esc — отмена.", theme.a("dim"))
        scr.refresh()
        ch = read_key(scr)
        if is_left(ch):
            selected = 0
        elif is_right(ch):
            selected = 1
        elif key_in(ch, "\t"):
            selected = 1 - selected
        elif is_enter(ch):
            return selected == 0
        elif key_in(ch, "y", "Y", "д", "Д"):
            return True
        elif key_in(ch, "n", "N", "н", "Н") or is_escape(ch):
            return False
        elif ch == curses.KEY_RESIZE:
            continue


def screen_msg(scr, args):
    theme = Theme(scr)
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    kind = args.kind or "info"
    icons = {
        "info": ("ℹ", "accent"),
        "warning": ("⚠", "warn"),
        "error": ("✖", "error"),
        "success": ("✓", "success"),
    }
    icon, color = icons.get(kind, icons["info"])
    if not theme.unicode:
        icon = {"info": "i", "warning": "!", "error": "x", "success": "+"}[kind]
    lines = wrap(args.message or "", max(1, Screen(scr, theme).main_w))
    offset = 0

    while True:
        s = Screen(scr, theme)
        row = s.chrome(args.title or APP_NAME, "↑/↓ прокрутка   Enter закрыть", steps, step_index, version)
        visible = max(1, s.content_y + s.content_h - row - 2)
        if offset > max(0, len(lines) - visible):
            offset = max(0, len(lines) - visible)
        s.put(row, s.main_x, icon, theme.a(color))
        s.put(row, s.main_x + 2, args.title or "", theme.a("accent"))
        row += 2
        for line in lines[offset : offset + visible]:
            s.put(row, s.main_x, line, theme.a("text"))
            row += 1
        if len(lines) > visible:
            s.put(s.content_y + s.content_h - 1, s.main_x + s.main_w - 1, "▼" if theme.unicode else "v", theme.a("dim"))
        s.put(s.y + s.win_h - 2, s.x + s.win_w - 12, "[ OK ]", theme.a("button"))
        scr.refresh()
        ch = read_key(scr)
        if is_up(ch):
            offset = max(0, offset - 1)
        elif is_down(ch):
            offset = min(max(0, len(lines) - visible), offset + 1)
        elif ch == curses.KEY_PPAGE:
            offset = max(0, offset - visible)
        elif ch == curses.KEY_NPAGE:
            offset = min(max(0, len(lines) - visible), offset + visible)
        elif is_enter(ch) or is_escape(ch) or key_in(ch, "q"):
            return True
        elif ch == curses.KEY_RESIZE:
            continue


def screen_error(scr, args):
    args.kind = "error"
    return screen_msg(scr, args)


def screen_textbox(scr, args):
    theme = Theme(scr)
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    if args.file:
        try:
            with open(args.file, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.read().splitlines()
        except OSError as exc:
            lines = [f"Не удалось прочитать файл: {exc}"]
    else:
        lines = (args.text or "").splitlines()
    if not lines:
        lines = [""]
    offset = 0

    while True:
        s = Screen(scr, theme)
        row = s.chrome(args.title or "Просмотр", "↑/↓ PgUp/PgDn   Enter закрыть", steps, step_index, version)
        visible = max(1, s.content_y + s.content_h - row - 1)
        offset = min(offset, max(0, len(lines) - visible))
        for line in lines[offset : offset + visible]:
            s.put(row, s.main_x, line[: s.main_w], theme.a("text"))
            row += 1
        if len(lines) > visible:
            percent = 100 * offset // max(1, len(lines) - visible)
            s.put(s.y + s.win_h - 2, s.x + s.win_w - 22, f"{percent:3d}%  ↓", theme.a("dim"))
        scr.refresh()
        ch = read_key(scr)
        if is_up(ch):
            offset = max(0, offset - 1)
        elif is_down(ch):
            offset += 1
        elif ch == curses.KEY_PPAGE:
            offset = max(0, offset - visible)
        elif ch == curses.KEY_NPAGE:
            offset += visible
        elif ch == curses.KEY_HOME:
            offset = 0
        elif ch == curses.KEY_END:
            offset = max(0, len(lines) - visible)
        elif is_enter(ch) or is_escape(ch) or key_in(ch, "q"):
            return True
        elif ch == curses.KEY_RESIZE:
            continue


def _reader(fd, target):
    try:
        with os.fdopen(fd, "r", encoding="utf-8", errors="replace", buffering=1) as handle:
            for line in handle:
                target.put(("line", line.rstrip("\r\n")))
    except Exception as exc:  # pragma: no cover - defensive
        target.put(("error", str(exc)))
    finally:
        target.put(("eof", None))


def _program_common(scr, args, gauge):
    theme = Theme(scr)
    steps, step_index = steps_from_args(args)
    version = app_version(args)
    target = queue.Queue()
    thread = threading.Thread(target=_reader, args=(args.fd, target), daemon=True)
    thread.start()
    lines = deque(maxlen=200)
    percent = 0
    message = args.prompt or "Выполняется..."
    done = False
    finished_at = None
    spinner_frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"] if theme.unicode else ["|", "/", "-", "\\"]
    spinner_index = 0
    start = time.monotonic()
    scr.nodelay(True)

    while True:
        while True:
            try:
                kind, value = target.get_nowait()
            except queue.Empty:
                break
            if kind == "line":
                if gauge:
                    raw = value.strip()
                    if raw:
                        head, _, tail = raw.partition("|")
                        if head.strip().isdigit():
                            percent = max(0, min(100, int(head.strip())))
                        if tail:
                            message = tail
                        elif not head.strip().isdigit():
                            message = raw
                else:
                    if value:
                        lines.append(value)
            elif kind == "eof":
                done = True
                finished_at = time.monotonic()
        if done and finished_at and time.monotonic() - finished_at > 0.35:
            break

        s = Screen(scr, theme)
        row = s.chrome(args.title or "Выполняется", "Установка выполняется · не закрывайте терминал", steps, step_index, version)
        row = s.prompt(row, message)
        row += 1
        if gauge:
            bar_w = max(10, s.main_w - 8)
            filled = bar_w * percent // 100
            s.put(row, s.main_x, "█" * filled + "░" * (bar_w - filled), theme.a("progress"))
            s.put(row + 1, s.main_x, f"{percent:3d}%", theme.a("accent"))
            row += 3
        else:
            s.hline(row - 1, s.main_x, s.main_w, theme.a("border_dim"))
        panel_h = max(1, s.content_y + s.content_h - row - 1)
        for line in list(lines)[-panel_h:]:
            s.put(row, s.main_x, line[: s.main_w], theme.a("dim"))
            row += 1
        spinner = spinner_frames[spinner_index % len(spinner_frames)]
        spinner_index += 1
        elapsed = int(time.monotonic() - start)
        status = "готово" if done else "работаю"
        s.put(s.y + s.win_h - 2, s.x + 2, f"{spinner}  {status}  ·  {elapsed}s", theme.a("accent"))
        scr.refresh()
        ch = scr.getch()
        if ch == curses.KEY_RESIZE:
            continue
        time.sleep(0.08)

    try:
        scr.nodelay(False)
    except curses.error:
        pass
    return True


def screen_program(scr, args):
    return _program_common(scr, args, gauge=False)


def screen_gauge(scr, args):
    return _program_common(scr, args, gauge=True)


# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------


def dispatch(scr, args):
    handlers = {
        "splash": screen_splash,
        "menu": screen_menu,
        "input": screen_input,
        "password": screen_password,
        "confirm": screen_confirm,
        "msg": screen_msg,
        "error": screen_error,
        "textbox": screen_textbox,
        "program": screen_program,
        "gauge": screen_gauge,
    }
    return handlers[args.command](scr, args)


def build_parser():
    parser = argparse.ArgumentParser(
        prog="tui.py",
        description="Full-screen TUI helper for ArchinstallSuper.",
    )
    parser.add_argument("--ascii", action="store_true", help="force ASCII drawing")
    sub = parser.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--title", default="")
        p.add_argument("--prompt", default="")
        p.add_argument("--steps", default="")
        p.add_argument("--step-index", default="")
        p.add_argument("--app-version", default="")

    p = sub.add_parser("splash")
    common(p)
    p.add_argument("--item", action="append", default=[])

    p = sub.add_parser("menu")
    common(p)
    p.add_argument("--item", action="append", default=[])
    p.add_argument("--default", default="")
    p.add_argument("--no-cancel", action="store_true")

    p = sub.add_parser("input")
    common(p)
    p.add_argument("--initial", default="")
    p.add_argument("--label", default="")
    p.add_argument("--help-text", default="")
    p.add_argument("--password", action="store_true")

    p = sub.add_parser("password")
    common(p)
    p.add_argument("--initial", default="")
    p.add_argument("--label", default="")
    p.add_argument("--help-text", default="")

    p = sub.add_parser("confirm")
    common(p)
    p.add_argument("--default", default="")
    p.add_argument("--yes-label", default="Да")
    p.add_argument("--no-label", default="Нет")

    p = sub.add_parser("msg")
    common(p)
    p.add_argument("--message", default="")
    p.add_argument("--kind", default="info")

    p = sub.add_parser("error")
    common(p)
    p.add_argument("--message", default="")
    p.add_argument("--kind", default="error")

    p = sub.add_parser("textbox")
    common(p)
    p.add_argument("--file", default="")
    p.add_argument("--text", default="")

    p = sub.add_parser("program")
    common(p)
    p.add_argument("--fd", type=int, default=5)

    p = sub.add_parser("gauge")
    common(p)
    p.add_argument("--fd", type=int, default=5)

    return parser


def main(argv=None):
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        pass
    if os.environ.get("AS_UI_ASCII") == "1":
        os.environ.setdefault("ESCDELAY", "25")

    args = build_parser().parse_args(argv)
    if args.ascii:
        os.environ["AS_UI_ASCII"] = "1"

    if not os.isatty(1):
        print("tui.py: stdout is not a terminal", file=sys.stderr)
        return 2

    os.environ.setdefault("ESCDELAY", "25")
    try:
        curses.set_escdelay(25)
    except (AttributeError, curses.error):
        pass

    result = None
    try:
        result = curses.wrapper(lambda scr: dispatch(scr, args))
    except KeyboardInterrupt:
        return 1
    except Exception:  # pragma: no cover - last-resort diagnostics
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 2

    if result is None:
        return 1
    if isinstance(result, bool):
        return 0 if result else 1
    emit(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
