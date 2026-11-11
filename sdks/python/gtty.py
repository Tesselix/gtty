# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
"""The gtty SDK for Python 3 (3.8 or later, standard library only).

Copy this file next to your extension's main file. AI assistants: read
AGENTS.md first; examples/hosts.py is a complete extension.

An extension is a module (or object) with any of these functions:

    on_gtty_start(ext)        once, when it starts
    on_window_start(win)      each window: the open ones, then new ones
    on_window_close(win)      a notice: the window is gone
    on_gtty_close(ext)        a notice: gtty is closing
    on_event(win, ev)         registered events and clicks

and ends with `gtty.run(globals())`. gtty starts it (docs/protocol.md);
callbacks run one at a time.
"""

import base64
import json
import os
import socket
import sys
import threading

API_VERSION = 1

__all__ = [
    "run", "dispatch", "new_text", "Window", "Extension", "Event", "ButtonClick",
    "GttyError", "WindowClosed", "NoChip", "BadName", "NoFile", "FileInUse",
    "FileClosed", "StorageFull", "StorageFailed",
]


class GttyError(Exception):
    """An error gtty answered a call with; `.name` is its name."""

    name = "GttyError"


def _error_class(name):
    return type(name, (GttyError,), {"name": name})


WindowClosed = _error_class("WindowClosed")
NoChip = _error_class("NoChip")
BadName = _error_class("BadName")
NoFile = _error_class("NoFile")
FileInUse = _error_class("FileInUse")
FileClosed = _error_class("FileClosed")
StorageFull = _error_class("StorageFull")
StorageFailed = _error_class("StorageFailed")
_ERRORS = {c.name: c for c in (WindowClosed, NoChip, BadName, NoFile, FileInUse, FileClosed, StorageFull, StorageFailed)}


def _color(v):
    if isinstance(v, int):
        return "#%06x" % (v & 0xFFFFFF)
    return v


def _part(string, attr=None):
    p = {"string": string}
    for k, v in (attr or {}).items():
        if k not in ("fg", "bk", "size", "bold", "stroke"):
            raise ValueError("unknown text attribute: " + k)
        if v is None or v is False:
            continue
        p[k] = _color(v) if k in ("fg", "bk") else v
    return p


def new_text(*args, **attr):
    """A text: new_text("main"), new_text("main", bold=True, fg=0xe0b040),
    or parts: new_text(("feature/", {}), ("login", {"bold": True})).
    Colors are 0xrrggbb or "#rrggbb"; size is percent (50-200); at most 8
    parts. A plain string works wherever a text goes, too."""
    if len(args) == 1 and isinstance(args[0], str):
        if not attr:
            return args[0]
        return [_part(args[0], attr)]
    parts = []
    for a in args:
        if isinstance(a, str):
            parts.append(_part(a))
        else:
            parts.append(_part(a[0], a[1] if len(a) > 1 else None))
    return parts[:8]


class ButtonClick:
    """A button pressed. For a dialog `id` is ok, cancel, yes, no, or kill /
    timeout (the dialog is already closed, no fields)."""

    def __init__(self, d):
        self.id = d.get("id", "")
        self.text = d.get("text", "")
        self.data = d.get("data", "")
        self.function = d.get("function", "")
        self.fields = d.get("fields", [])
        self.command = d.get("command", False)

    def field(self, id):
        """A text box's or drop box's value, or None."""
        for f in self.fields:
            if f.get("id") == id and isinstance(f.get("value"), str):
                return f["value"]
        return None

    def checked(self, id):
        """A check box's value."""
        for f in self.fields:
            if f.get("id") == id and isinstance(f.get("value"), bool):
                return f["value"]
        return False

    def __repr__(self):
        return "ButtonClick(id=%r, function=%r, data=%r)" % (self.id, self.function, self.data)


class Event:
    """`kind`: window_changed, command_started, key or button_click."""

    def __init__(self, d):
        self.event_id = d.get("eventId", 0)
        self.kind = d.get("kind", "")
        self.folder = d.get("folder", "")
        self.branch = d.get("branch", "")
        self.remote = d.get("remote", False)
        self.command = d.get("command", "")
        # key: its name, what it typed, the modifier keys (cmd: ⌘ / Super)
        self.key = d.get("key", "")
        self.text = d.get("text", "")
        self.ctrl = d.get("ctrl", False)
        self.shift = d.get("shift", False)
        self.alt = d.get("alt", False)
        self.cmd = d.get("cmd", False)
        self.button = ButtonClick(d["button"]) if "button" in d else None


def dispatch(actions, win, ev):
    """The central on-click: calls the function of `actions` (a class, an
    object or a dict) that the click names, with (win, button)."""
    b = ev.button
    if b is None:
        return
    if isinstance(actions, dict):
        f = actions.get(b.function)
    else:
        f = getattr(actions, b.function, None)
    if f is None or b.function.startswith("_"):
        raise LookupError("no function " + repr(b.function) + " in actions")
    return f(win, b)


class _Conn:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.pending = []
        self.next_id = 0
        self.lock = threading.Lock()
        self.current_ev = 0

    def send(self, msg):
        data = (json.dumps(msg, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        with self.lock:
            try:
                self.sock.sendall(data)
            except OSError:
                pass  # gtty is gone: the read loop ends

    def read(self):
        while b"\n" not in self.buf:
            try:
                chunk = self.sock.recv(65536)
            except InterruptedError:
                continue
            except OSError:
                return None
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        try:
            return json.loads(line)
        except ValueError:
            return {}

    def next(self):
        if self.pending:
            return self.pending.pop(0)
        return self.read()

    def call(self, win, op, **fields):
        self.next_id += 1
        rid = self.next_id
        msg = {"t": "call", "id": rid, "win": win, "op": op}
        msg.update(fields)
        self.send(msg)
        while True:
            m = self.read()
            if m is None:
                raise WindowClosed("gtty is gone")
            if m.get("t") == "reply" and m.get("id") == rid:
                if "error" in m:
                    cls = _ERRORS.get(m["error"], StorageFailed)
                    raise cls(m["error"])
                return m.get("value")
            self.pending.append(m)


class _Ui:
    def __init__(self, win):
        self._win = win

    def set(self, chip=..., peek=..., epeek=..., dialog=...):
        """Set one of chip, peek, epeek or dialog: win.ui.set(chip={"text":
        "main"}). A key left out stays, None clears it; peek=None or
        epeek=None removes it. Errors go to `gtty ext logs`."""
        given = [(k, v) for k, v in (("chip", chip), ("peek", peek), ("epeek", epeek), ("dialog", dialog)) if v is not ...]
        if len(given) != 1:
            raise TypeError("win.ui.set: one of chip, peek, epeek or dialog")
        key, value = given[0]
        if key in ("chip", "dialog") and not isinstance(value, dict):
            raise TypeError("win.ui.set: " + key + " must be a dict")
        self._win._post("set", **{key: value})

    def set_display_mode(self, mode):
        """Show "chip" (closes this extension's peek or epeek), "peek" or
        "epeek". Opened while handling the user's click, it gets the
        keyboard."""
        if mode not in ("chip", "peek", "epeek"):
            raise ValueError("mode: chip, peek or epeek")
        self._win._post("mode", mode=mode, ev=_rt.conn.current_ev)

    def show_dialog(self):
        self._win._post("showDialog", ev=_rt.conn.current_ev)

    def close_dialog(self):
        """The buttons only report: close it yourself (not after kill or
        timeout, it's gone already)."""
        self._win._post("closeDialog")


class _Events:
    def __init__(self, win):
        self._win = win

    def register(self, kind):
        """kind: "window_changed", "command_started" or "key". Clicks come
        without."""
        if kind == "button_click":
            return
        if kind not in ("window_changed", "command_started", "key"):
            raise ValueError("unknown event: " + kind)
        self._win._post("register", event=kind)

    def unregister(self, kind):
        if kind == "button_click":
            return
        self._win._post("unregister", event=kind)


class File:
    """A file open in a storage; use `with`, or call close()."""

    def __init__(self, win, handle):
        self._win = win
        self._handle = handle

    def read(self, size=65536):
        """Up to `size` bytes; b"" at the end."""
        v = _rt.conn.call(self._win.id, "read", handle=self._handle, max=max(1, min(size, 1 << 20)))
        return base64.b64decode(v or "")

    def read_all(self):
        out = b""
        while True:
            part = self.read(1 << 20)
            if not part:
                return out
            out += part

    def write(self, data):
        """bytes, or str (written as UTF-8)."""
        if isinstance(data, str):
            data = data.encode()
        for i in range(0, max(len(data), 1), 1 << 20):
            _rt.conn.call(self._win.id, "write", handle=self._handle, data=base64.b64encode(data[i:i + (1 << 20)]).decode())

    def close(self):
        """A file opened for writing takes the old one's place now."""
        if self._handle is not None:
            h, self._handle = self._handle, None
            _rt.conn.call(self._win.id, "close", handle=h)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class Storage:
    """win.ephemeral (this instance's files, gone with the window) or
    win.stateful (the extension's, shared by all its instances). Names are
    plain file names."""

    def __init__(self, win, kind):
        self._win = win
        self._kind = kind

    def open_write(self, name, timeout_ms=0):
        """Waits up to timeout_ms for the file (0: tries once). Writing
        replaces the whole file, at close; until then nobody else can use it."""
        return File(self._win, _rt.conn.call(self._win.id, "open", storage=self._kind, name=name, mode="write", timeout=timeout_ms))

    def open_read(self, name, timeout_ms=0):
        """Waits up to timeout_ms while someone writes it (0: tries once).
        No such file: NoFile."""
        return File(self._win, _rt.conn.call(self._win.id, "open", storage=self._kind, name=name, mode="read", timeout=timeout_ms))

    def delete(self, name, timeout_ms=0):
        _rt.conn.call(self._win.id, "delete", storage=self._kind, name=name, timeout=timeout_ms)

    def list(self):
        return list(_rt.conn.call(self._win.id, "list", storage=self._kind) or [])


_LEVELS = ("debug", "info", "warn", "err")


class Window:
    """The connection to one window: its id, ui, events, ephemeral and
    stateful storage, shell() and log()."""

    def __init__(self, id):
        self.id = id
        self.ui = _Ui(self)
        self.events = _Events(self)
        self.ephemeral = Storage(self, "ephemeral")
        self.stateful = Storage(self, "stateful")
        self.closed = False

    def _post(self, t, **fields):
        if self.closed:
            raise WindowClosed("the window closed")
        msg = {"t": t, "win": self.id}
        msg.update(fields)
        _rt.conn.send(msg)

    def shell(self):
        """The shell in front (bash inside zsh: bash); if something else is
        in front, the window's own shell."""
        return _rt.conn.call(self.id, "shell")

    def log(self, level, message):
        """A line in `gtty ext logs`, with this window's id. Works from any
        thread and in on_window_close."""
        _log(self.id, level, message)


class Extension:
    """For on_gtty_start and on_gtty_close."""

    def __init__(self, name):
        self.name = name

    def log(self, level, message):
        _log(0, level, message)


def _log(win, level, message):
    if level not in _LEVELS:
        raise ValueError("level: debug, info, warn or err")
    _rt.conn.send({"t": "log", "win": win, "level": level, "message": str(message)[:4096]})


class _Runtime:
    conn = None


_rt = _Runtime()


def _dev_socket():
    """Where an extension gtty didn't start connects: GTTY_EXT_SOCKET, else
    the newest gtty's shared address (only when the folder is this user's
    alone)."""
    path = os.environ.get("GTTY_EXT_SOCKET")
    if path:
        return path
    folder = "%s/gtty-dev-%d" % ((os.environ.get("TMPDIR") or "/tmp").rstrip("/"), os.getuid())
    try:
        st = os.lstat(folder)
    except OSError:
        return None
    if st.st_uid != os.getuid() or st.st_mode & 0o077:
        return None
    return folder + "/ext.sock"


def _connect():
    """(socket, debugging): gtty's socket on GTTY_EXT_FD, or the developer
    socket when an IDE started it."""
    fd = os.environ.get("GTTY_EXT_FD")
    if fd:
        return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=int(fd)), False
    path = _dev_socket()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        if not path:
            raise OSError("no developer socket")
        s.connect(path)
    except OSError:
        sys.stderr.write("No gtty to connect to: start gtty first (or set GTTY_EXT_SOCKET, see `gtty ext socket`).\n")
        sys.exit(2)
    return s, True


def _fn(ext, name):
    if isinstance(ext, dict):
        return ext.get(name)
    return getattr(ext, name, None)


def _report(win, callback, e):
    if isinstance(e, WindowClosed):
        return
    _log(win, "err", "%s raised %s: %s" % (callback, type(e).__name__, e))


def run(ext):
    """Run the extension: `gtty.run(globals())`, or a module or object.
    Returns when gtty closes."""
    sock, debugging = _connect()
    _rt.conn = _Conn(sock)
    if debugging:
        # Started by an IDE: say which extension this is.
        _rt.conn.send({"t": "attach", "api": API_VERSION, "name": os.environ.get("GTTY_EXT_NAME", ""), "dir": os.getcwd()})
    # print() reaches `gtty ext logs` line by line, not when a buffer fills.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(line_buffering=True)
        except (AttributeError, ValueError):
            pass
    name = os.environ.get("GTTY_EXT_NAME", "extension")
    windows = {}
    while True:
        m = _rt.conn.next()
        if m is None:
            return
        t = m.get("t")
        win = m.get("win", 0)
        if t == "refused":
            sys.stderr.write("gtty refused the connection: %s\n" % m.get("reason", ""))
            sys.exit(1)
        if t == "hello":
            if m.get("api") != API_VERSION:
                sys.stderr.write("gtty speaks extension API %s, this SDK %d\n" % (m.get("api"), API_VERSION))
                return
            name = m.get("name", name)
        elif t in ("gttyStart", "gttyClose"):
            f = _fn(ext, "on_gtty_start" if t == "gttyStart" else "on_gtty_close")
            if f:
                try:
                    f(Extension(name))
                except Exception as e:  # noqa: BLE001 - reported, not fatal
                    _report(0, f.__name__, e)
            if t == "gttyClose":
                return
        elif t == "windowStart":
            w = windows[win] = Window(win)
            f = _fn(ext, "on_window_start")
            if f:
                try:
                    f(w)
                except Exception as e:  # noqa: BLE001
                    _report(win, "on_window_start", e)
        elif t == "windowClose":
            w = windows.pop(win, None)
            if w is not None:
                w.closed = True
                f = _fn(ext, "on_window_close")
                if f:
                    try:
                        f(w)
                    except Exception as e:  # noqa: BLE001
                        _report(win, "on_window_close", e)
        elif t == "event":
            w = windows.get(win)
            f = _fn(ext, "on_event")
            if w is None or f is None:
                continue
            ev = Event(m.get("event", {}))
            _rt.conn.current_ev = ev.event_id
            try:
                f(w, ev)
            except Exception as e:  # noqa: BLE001
                _report(win, "on_event", e)
            finally:
                _rt.conn.current_ev = 0
