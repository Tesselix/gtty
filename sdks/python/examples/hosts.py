# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
"""A complete extension: a chip that keeps a list of hosts. It uses every
part of the SDK and is checked by sdks/conformance/fake_gtty.py, so it can't
fall behind. Start a new extension from a copy of this file, gtty.py and
manifest.json."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import gtty  # noqa: E402

FILE = "hosts.txt"

# on_window_start runs once per window: state goes by win.id.
filters = {}


def on_window_start(win):
    filters[win.id] = ""
    win.events.register("window_changed")
    # Keys: F6 opens the list. The key still reaches the program too.
    win.events.register("key")
    # A UI needs a chip. Hover opens nothing by itself: onhover does.
    win.ui.set(chip={"text": "hosts", "onhover": "open"})
    win.ui.set(peek={
        "expand": True,
        "onexpand": "refresh",
        "text": gtty.new_text("hosts", bold=True),
        "postButton": {"dots": "horizontal", "onclick": "about"},
    })
    set_list(win)


def on_window_close(win):
    filters.pop(win.id, None)


def on_event(win, ev):
    if ev.kind == "button_click":
        gtty.dispatch(Actions, win, ev)
    elif ev.kind == "window_changed":
        win.ui.set(chip={"dimmed": ev.remote})
    elif ev.kind == "key":
        if ev.key == "f6" and not (ev.ctrl or ev.shift or ev.alt or ev.cmd):
            win.ui.set_display_mode("epeek")


def read_hosts(win):
    """The hosts file's text; no file yet: an empty list."""
    try:
        with win.stateful.open_read(FILE, 200) as f:
            return f.read_all().decode()
    except gtty.NoFile:
        return ""


ROW_MENU = [{"id": "connect", "text": "Connect"}, {"id": "remove", "text": "Remove"}]


def set_list(win):
    flt = filters.get(win.id, "")
    rows = []
    for host in read_hosts(win).split("\n"):
        if not host:
            continue
        # gtty doesn't filter: the extension decides what the text means.
        at = host.lower().find(flt.lower()) if flt else 0
        if at < 0:
            continue
        text = host
        if flt:
            # Mark the letters that match.
            text = gtty.new_text(
                (host[:at], {}),
                (host[at:at + len(flt)], {"fg": 0x202020, "bk": 0xE0B040}),
                (host[at + len(flt):], {}),
            )
        rows.append({
            "id": host, "text": text, "onclick": "pick", "data": host,
            "postButton": {"dots": "vertical", "onclick": "rowMenu", "items": ROW_MENU},
        })
    win.ui.set(epeek={
        "frame": {
            "text": "hosts",
            "filter": {"hint": "filter hosts", "onclick": "filter"},
            "right": [{"icon": "save", "text": "add", "onclick": "askHost"}],
        },
        "lines": rows,
        "selected": 0,
        "empty": "no hosts",
    })


class Actions:
    """Every onclick / onhover / onexpand name is a function here."""

    @staticmethod
    def open(win, b):
        win.log("debug", "opening the peek")
        win.ui.set_display_mode("peek")

    @staticmethod
    def refresh(win, b):
        """Other windows may have added hosts."""
        set_list(win)

    @staticmethod
    def filter(win, b):
        filters[win.id] = b.text
        set_list(win)

    @staticmethod
    def pick(win, b):
        win.ui.set(chip={"text": b.data})
        win.ui.set_display_mode("chip")  # gtty only reports: close it here

    @staticmethod
    def rowMenu(win, b):
        """A ⋮ pick: b.id is the item's."""
        if b.id == "connect":
            win.ui.set_display_mode("chip")

    @staticmethod
    def about(win, b):
        win.ui.set(dialog={
            "title": "About hosts", "layout": "form", "timeout": 20, "buttons": "ok", "onclick": "closeIt",
            "fields": [{"id": "info", "type": "label", "label": "running under " + win.shell()}],
        })
        win.ui.show_dialog()

    @staticmethod
    def closeIt(win, b):
        # After kill and timeout the dialog is already gone.
        if b.id not in ("kill", "timeout"):
            win.ui.close_dialog()

    @staticmethod
    def askHost(win, b):
        win.ui.set(dialog={
            "title": "Add a host", "layout": "form", "timeout": 30, "buttons": "okcancel", "onclick": "addHost",
            "fields": [
                {"id": "host", "type": "text", "label": "Host", "value": ""},
                {"id": "pin", "type": "checkbox", "label": "Show on the chip", "value": False},
                {"id": "kind", "type": "dropdown", "label": "Kind", "value": "ssh", "options": ["ssh", "mosh"], "filter": False},
            ],
        })
        win.ui.show_dialog()

    @staticmethod
    def addHost(win, b):
        if b.id in ("kill", "timeout"):
            return
        if b.id == "ok":
            host = b.field("host") or ""
            # To reject input, update the dialog and leave it open.
            if not host:
                win.ui.set(dialog={"error": "enter a host"})
                return
            old = read_hosts(win)
            # A write replaces the whole file, at close.
            with win.stateful.open_write(FILE, 200) as f:
                f.write(old + host + "\n")
            if b.checked("pin"):
                win.ui.set(chip={"text": host})
            set_list(win)
        win.ui.close_dialog()  # the buttons only report


if __name__ == "__main__":
    gtty.run(globals())
