# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
"""commands: a chip that keeps the commands you run (all but the
very common ones: cd, ls, pwd, …). A click on one copies it. See ../README.md."""

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# gtty.py beside this file in a package; the SDK's own in this repository.
if not os.path.exists(os.path.join(HERE, "gtty.py")):
    sys.path.insert(1, os.path.join(HERE, "..", "..", "..", "sdks", "python"))
import gtty  # noqa: E402

FILE = "commands.tsv"
KEEP = 500  # commands kept, the ones used last
SHOWN = 200  # lines in the list at most
WAIT_MS = 300  # storage timeout

# Too common to keep: a line made only of these is dropped.
EXCLUDED = {"cd", "pushd", "popd", "ls", "ll", "la", "l", "lsd", "exa", "eza",
            "gls", "dir", "vdir", "pwd", "clear", "exit"}
# Skipped in front of the command, with their own options.
WRAPPERS = {"sudo", "doas", "env", "time", "nohup", "nice", "command", "builtin", "exec"}
# Wrapper options that take the next word.
WRAPPER_ARG = {
    "sudo": {"-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"},
    "doas": {"-u", "-C"},
    "env": {"-u", "-C", "-S", "-P"},
    "nice": {"-n"},
}
SEPARATORS = "|&;\n()"


# ---- which commands are kept (pure, tested by test_commands.py) ----

def segments(line):
    """The line's parts, each a list of (raw, value) words: raw as typed,
    value with the quotes and backslashes taken off."""
    parts, words = [], []
    raw, val = "", ""
    quote = None
    in_word = False
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            raw += ch
            if ch == quote:
                quote = None
            elif ch == "\\" and quote == '"' and i + 1 < len(line):
                i += 1
                raw += line[i]
                val += line[i]
            else:
                val += ch
        elif ch in ("'", '"'):
            quote = ch
            raw += ch
            in_word = True
        elif ch == "\\" and i + 1 < len(line):
            i += 1
            raw += ch + line[i]
            if line[i] != "\n":
                val += line[i]
            in_word = True
        elif ch in (" ", "\t") or ch in SEPARATORS:
            if in_word:
                words.append((raw, val))
                raw, val, in_word = "", "", False
            if ch in SEPARATORS and words:
                parts.append(words)
                words = []
        else:
            raw += ch
            val += ch
            in_word = True
        i += 1
    if in_word:
        words.append((raw, val))
    if words:
        parts.append(words)
    return parts


def is_assignment(raw):
    eq = raw.find("=")
    if eq <= 0:
        return False
    name = raw[:eq]
    return (name[0].isalpha() or name[0] == "_") and all(c.isalnum() or c == "_" for c in name)


def is_flag(raw):
    return len(raw) >= 2 and raw[0] == "-" and raw != "--"


def worth(line):
    """Is this command line worth keeping? See ../README.md."""
    if not line.strip() or line[0] in (" ", "\t"):
        return False
    found = False  # a part runs a command worth keeping
    for words in segments(line):
        i = 0
        # Assignments and wrappers in front, with the wrappers' options.
        while i < len(words):
            raw, val = words[i]
            if is_assignment(raw):
                i += 1
                continue
            name = os.path.basename(val)
            if name not in WRAPPERS:
                break
            i += 1
            while i < len(words) and is_flag(words[i][0]):
                i += 2 if words[i][0] in WRAPPER_ARG.get(name, ()) else 1
        if i >= len(words):
            continue
        if os.path.basename(words[i][1]) not in EXCLUDED:
            found = True
    return found


# ---- the file: lines "count<TAB>last<TAB>command", escaped ----

def escape(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append({"t": "\t", "n": "\n", "r": "\r"}.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def parse(text):
    """Entries [count, last, command], oldest use first."""
    entries = []
    for line in text.split("\n"):
        f = line.split("\t", 2)
        if len(f) != 3 or not f[0].isdigit() or not f[1].isdigit():
            continue
        entries.append([int(f[0]), int(f[1]), unescape(f[2])])
    entries.sort(key=lambda e: (e[1], e[0]))
    return entries


def format_entries(entries):
    return "".join("%d\t%d\t%s\n" % (n, last, escape(cmd)) for n, last, cmd in entries)


def record(entries, cmd, now):
    """One more use of cmd; keeps the KEEP used last."""
    for e in entries:
        if e[2] == cmd:
            e[0] += 1
            e[1] = max(e[1], now)
            break
    else:
        entries.append([1, now, cmd])
    entries.sort(key=lambda e: (e[1], e[0]))
    del entries[:-KEEP]
    return entries


# ---- storage ----

def load(win):
    try:
        with win.stateful.open_read(FILE, WAIT_MS) as f:
            return parse(f.read_all().decode("utf-8", "replace"))
    except gtty.NoFile:
        return []


def save(win, entries):
    with win.stateful.open_write(FILE, WAIT_MS) as f:
        f.write(format_entries(entries))


# ---- the clipboard: the SDK can't type into a window ----

def copy(text):
    """None when copied, else why not."""
    if sys.platform == "darwin":
        tools = [["pbcopy"]]
    else:
        tools = []
        if os.environ.get("WAYLAND_DISPLAY"):
            tools.append(["wl-copy"])
        tools += [["xclip", "-selection", "clipboard"], ["xsel", "--clipboard", "--input"]]
    for argv in tools:
        try:
            r = subprocess.run(argv, input=text.encode(), stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=2)
        except (OSError, subprocess.SubprocessError):
            continue
        if r.returncode == 0:
            return None
    return "no clipboard tool (pbcopy, wl-copy, xclip, xsel)"


PASTE = "⌘V" if sys.platform == "darwin" else "Ctrl+Shift+V"


# ---- the extension ----

filters = {}  # win.id -> the filter's text


def on_window_start(win):
    filters[win.id] = ""
    win.events.register("command_started")
    # A click and the mouse resting on the chip both open the list.
    win.ui.set(chip={"text": "commands", "onclick": "open", "onhover": "open"})
    set_list(win, load(win))


def on_window_close(win):
    filters.pop(win.id, None)


def on_event(win, ev):
    if ev.kind == "button_click":
        gtty.dispatch(Actions, win, ev)
    elif ev.kind == "command_started" and worth(ev.command):
        cmd = ev.command.strip()
        try:
            entries = record(load(win), cmd, int(time.time()))
            save(win, entries)
        except gtty.FileInUse:
            win.log("warn", "commands.tsv busy: a command not kept")


def one_line(cmd):
    return cmd.replace("\r\n", "\n").replace("\n", " ⏎ ").replace("\t", " ")


def set_list(win, entries):
    flt = filters.get(win.id, "").lower()
    rows = []
    for n, _last, cmd in entries:
        shown = one_line(cmd)
        at = shown.lower().find(flt) if flt else 0
        if at < 0:
            continue
        parts = [(shown, {})]
        if flt:
            # Mark the letters that match.
            parts = [(shown[:at], {}), (shown[at:at + len(flt)], {"fg": 0x202020, "bk": 0xE0B040}),
                     (shown[at + len(flt):], {})]
        if n > 1:
            parts.append(("  ×%d" % n, {"fg": 0x8A8A8A}))
        rows.append({
            "id": str(len(rows)), "text": gtty.new_text(*parts), "onclick": "pick", "data": cmd,
            "postButton": {"dots": "vertical", "onclick": "rowMenu", "items": [
                {"id": "copy", "text": "Copy", "data": cmd},
                {"id": "forget", "text": "Forget", "data": cmd},
            ]},
        })
    rows = rows[-SHOWN:]
    win.ui.set(epeek={
        "frame": {"text": "commands", "filter": {"hint": "filter commands", "onclick": "filter"}},
        "lines": rows,
        "selected": max(len(rows) - 1, 0),  # the newest, next to the chip
        "empty": "no commands match" if flt else "no commands yet: run one",
        "footer": "a click copies it, %s pastes it" % PASTE,
        "state": "idle",
        "message": [],
    })


def copy_it(win, cmd):
    why = copy(cmd)
    if why:
        win.log("warn", why)
        win.ui.set(epeek={"state": "err", "message": [why]})
    else:
        win.ui.set(epeek={"state": "ok", "message": ["copied: %s pastes it" % PASTE]})


class Actions:
    """Every onclick / onhover name is a function here."""

    @staticmethod
    def open(win, b):
        set_list(win, load(win))  # other windows may have added commands
        win.ui.set_display_mode("epeek")

    @staticmethod
    def filter(win, b):
        filters[win.id] = b.text
        set_list(win, load(win))

    @staticmethod
    def pick(win, b):
        copy_it(win, b.data)

    @staticmethod
    def rowMenu(win, b):
        if b.id == "copy":
            copy_it(win, b.data)
        elif b.id == "forget":
            entries = [e for e in load(win) if e[2] != b.data]
            save(win, entries)
            set_list(win, entries)


if __name__ == "__main__":
    gtty.run(globals())
