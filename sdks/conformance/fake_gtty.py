#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
"""A stand-in for gtty that runs an SDK's hosts example through one
conversation (docs/protocol.md) and checks what it sends back. Every SDK's
example (sdks/<language>/examples/hosts.*) does the same, so this one test
covers them all:

    python3 sdks/conformance/fake_gtty.py -- <command that starts the example>

Exit code 0: it behaved as gtty expects. --verbose prints every message.
Only the standard library, so CI needs nothing more.
"""

import base64
import json
import os
import select
import socket
import subprocess
import sys
import time

VERBOSE = "--verbose" in sys.argv
WIN = 7


class Fake:
    def __init__(self, argv):
        parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        env = dict(os.environ, GTTY_EXT_FD="3", GTTY_EXT_NAME="hosts", GTTY_EXT_DIR=os.getcwd())
        self.proc = subprocess.Popen(
            argv, env=env, pass_fds=(3,), stdin=subprocess.DEVNULL,
            preexec_fn=lambda: os.dup2(child.fileno(), 3),
        )
        child.close()
        self.sock = parent
        self.buf = b""
        self.files = {}  # name -> bytes
        self.open_files = {}  # handle -> [name, mode, data, pos]
        self.next_handle = 1
        self.next_event = 100
        self.seen = []

    def send(self, msg):
        if VERBOSE:
            print("gtty >", json.dumps(msg))
        self.sock.sendall((json.dumps(msg) + "\n").encode())

    def read(self, timeout):
        end = time.time() + timeout
        while b"\n" not in self.buf:
            left = end - time.time()
            if left <= 0:
                return None
            r, _, _ = select.select([self.sock], [], [], left)
            if not r:
                return None
            chunk = self.sock.recv(65536)
            if not chunk:
                return None
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        msg = json.loads(line)
        if VERBOSE:
            print("ext  <", json.dumps(msg))
        return msg

    def answer(self, m):
        op, rid = m["op"], m["id"]
        if m.get("win") != WIN:
            return self.send({"t": "reply", "id": rid, "error": "WindowClosed"})
        if op == "shell":
            return self.send({"t": "reply", "id": rid, "value": "zsh"})
        if op == "open":
            name = m["name"]
            if "/" in name or name.startswith("."):
                return self.send({"t": "reply", "id": rid, "error": "BadName"})
            if m["mode"] == "read" and name not in self.files:
                return self.send({"t": "reply", "id": rid, "error": "NoFile"})
            h = self.next_handle
            self.next_handle += 1
            self.open_files[h] = [name, m["mode"], self.files.get(name, b"") if m["mode"] == "read" else b"", 0]
            return self.send({"t": "reply", "id": rid, "value": h})
        f = self.open_files.get(m.get("handle"))
        if op in ("read", "write", "close") and f is None:
            return self.send({"t": "reply", "id": rid, "error": "FileClosed"})
        if op == "read":
            part = f[2][f[3]:f[3] + m["max"]]
            f[3] += len(part)
            return self.send({"t": "reply", "id": rid, "value": base64.b64encode(part).decode()})
        if op == "write":
            f[2] += base64.b64decode(m["data"])
            return self.send({"t": "reply", "id": rid, "value": True})
        if op == "close":
            if f[1] == "write":
                self.files[f[0]] = f[2]
            del self.open_files[m["handle"]]
            return self.send({"t": "reply", "id": rid, "value": True})
        if op == "list":
            return self.send({"t": "reply", "id": rid, "value": sorted(self.files)})
        if op == "delete":
            self.files.pop(m["name"], None)
            return self.send({"t": "reply", "id": rid, "value": True})
        self.send({"t": "reply", "id": rid, "error": "StorageFailed"})

    def settle(self, wait=1.5):
        """Answer calls and collect messages until the extension is quiet."""
        got = []
        quiet = 0.4
        end = time.time() + wait
        while time.time() < end:
            m = self.read(quiet)
            if m is None:
                break
            if m["t"] == "call":
                self.answer(m)
                end = time.time() + wait
                continue
            got.append(m)
        self.seen += got
        return got

    def click(self, function, **fields):
        self.next_event += 1
        button = {"function": function}
        button.update(fields)
        self.send({"t": "event", "win": WIN, "event": {"eventId": self.next_event, "kind": "button_click", "button": button}})
        return self.next_event


def text_of(t):
    if t is None:
        return ""
    if isinstance(t, str):
        return t
    return "".join(p if isinstance(p, str) else p.get("string", "") for p in t)


def find(msgs, t, key=None):
    for m in msgs:
        if m["t"] == t and (key is None or key in m):
            return m
    return None


failures = []


def check(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures.append(what)


def dev_check(argv):
    """Started by an IDE (no GTTY_EXT_FD): it connects to GTTY_EXT_SOCKET,
    says `attach` first, and exits non-zero when gtty refuses it."""
    import shutil
    import tempfile
    folder = tempfile.mkdtemp(prefix="gtty-conf-", dir="/tmp")
    path = folder + "/ext.sock"
    lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    lsock.bind(path)
    lsock.listen(1)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GTTY_EXT_")}
    env["GTTY_EXT_SOCKET"] = path
    proc = subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        r, _, _ = select.select([lsock], [], [], 10)
        check(bool(r), "debugging: it connects to GTTY_EXT_SOCKET")
        if not r:
            return
        conn, _ = lsock.accept()
        buf = b""
        end = time.time() + 5
        while b"\n" not in buf and time.time() < end:
            rr, _, _ = select.select([conn], [], [], max(0, end - time.time()))
            if not rr:
                break
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
        m = json.loads(buf.split(b"\n", 1)[0]) if b"\n" in buf else {}
        if VERBOSE:
            print("ext  <", json.dumps(m))
        check(m.get("t") == "attach" and m.get("api") == 1, "debugging: its first message is attach, api 1")
        check(os.path.realpath(m.get("dir", "")) == os.path.realpath(os.getcwd()), "debugging: attach names its folder")
        conn.sendall(b'{"t":"refused","reason":"a test"}\n')
        try:
            code = proc.wait(timeout=5)
            err = proc.stderr.read().decode(errors="replace")
            check(code != 0 and "a test" in err, "debugging: refused, it says why and exits non-zero")
        except subprocess.TimeoutExpired:
            check(False, "debugging: refused, it exits")
        conn.close()
    finally:
        if proc.poll() is None:
            proc.kill()
        lsock.close()
        shutil.rmtree(folder, ignore_errors=True)


def main():
    if "--" not in sys.argv:
        print(__doc__)
        return 2
    argv = sys.argv[sys.argv.index("--") + 1:]
    g = Fake(argv)
    g.send({"t": "hello", "api": 1, "name": "hosts"})
    g.send({"t": "gttyStart"})
    g.send({"t": "windowStart", "win": WIN})
    got = g.settle(5)
    regs = [m["event"] for m in got if m["t"] == "register" and m.get("win") == WIN]
    check("window_changed" in regs and "key" in regs, "registers window_changed and key")
    chip = find(got, "set", "chip")
    check(chip is not None and text_of(chip["chip"].get("text")) == "hosts" and chip["chip"].get("onhover") == "open", "sets its chip: text hosts, onhover open")
    peek = find(got, "set", "peek")
    check(peek is not None and peek["peek"].get("expand") is True and peek["peek"].get("postButton", {}).get("dots") == "horizontal", "sets its peek: expand, ⋯ button")
    ep = find(got, "set", "epeek")
    check(ep is not None and ep["epeek"].get("lines") == [] and "filter" in ep["epeek"].get("frame", {}), "sets an empty epeek with a filter (no hosts file yet)")

    g.send({"t": "event", "win": WIN, "event": {"eventId": 50, "kind": "window_changed", "folder": "/tmp", "remote": True}})
    got = g.settle()
    chip = find(got, "set", "chip")
    check(chip is not None and chip["chip"].get("dimmed") is True, "window_changed in a remote session dims the chip")

    g.send({"t": "event", "win": WIN, "event": {"eventId": 60, "kind": "key", "key": "f6", "shift": True}})
    got = g.settle()
    check(find(got, "mode") is None, "key: Shift+F6 does nothing")
    g.send({"t": "event", "win": WIN, "event": {"eventId": 61, "kind": "key", "key": "f6"}})
    got = g.settle()
    mode = find(got, "mode")
    check(mode is not None and mode["mode"] == "epeek" and mode.get("ev") == 61, "key: F6 opens the list (mode epeek, with the event's id)")
    g.send({"t": "event", "win": WIN, "event": {"eventId": 62, "kind": "key", "key": "a", "text": "A", "shift": True}})
    got = g.settle()
    check(find(got, "mode") is None, "key: other keys do nothing")

    ev = g.click("open")
    got = g.settle()
    mode = find(got, "mode")
    check(mode is not None and mode["mode"] == "peek" and mode.get("ev") == ev, "a click on open: mode peek, with the event's id")
    check(find(got, "log") is not None, "logs (win.log)")

    ev = g.click("askHost")
    got = g.settle()
    d = find(got, "set", "dialog")
    check(d is not None and d["dialog"].get("buttons") == "okcancel" and len(d["dialog"].get("fields", [])) == 3, "askHost sets a dialog: okcancel, 3 fields")
    sd = find(got, "showDialog")
    check(sd is not None and sd.get("ev") == ev, "and shows it, with the event's id")

    g.click("addHost", id="ok", fields=[{"id": "host", "value": ""}, {"id": "pin", "value": False}, {"id": "kind", "value": "ssh"}])
    got = g.settle()
    d = find(got, "set", "dialog")
    check(d is not None and d["dialog"].get("error") == "enter a host" and find(got, "closeDialog") is None, "an empty host: the dialog's error, left open")

    g.click("addHost", id="ok", fields=[{"id": "host", "value": "alpha"}, {"id": "pin", "value": True}, {"id": "kind", "value": "ssh"}])
    got = g.settle()
    check(g.files.get("hosts.txt") == b"alpha\n", "ok: hosts.txt written through storage (open, write, close)")
    chip = find(got, "set", "chip")
    check(chip is not None and text_of(chip["chip"].get("text")) == "alpha", "pinned: the chip shows the host")
    ep = find(got, "set", "epeek")
    lines = ep["epeek"].get("lines", []) if ep else []
    check(len(lines) == 1 and text_of(lines[0].get("text")) == "alpha" and lines[0].get("postButton", {}).get("dots") == "vertical", "the epeek lists alpha with a ⋮ menu")
    check(find(got, "closeDialog") is not None, "and closes the dialog")

    g.click("filter", id="filter", text="lp")
    got = g.settle()
    ep = find(got, "set", "epeek")
    parts = ep["epeek"]["lines"][0]["text"] if ep and ep["epeek"].get("lines") else []
    hit = [p for p in parts if isinstance(p, dict) and p.get("bk")]
    check(len(hit) == 1 and hit[0].get("string") == "lp", "a filter marks the matching letters")

    g.click("filter", id="filter", text="zz")
    got = g.settle()
    ep = find(got, "set", "epeek")
    check(ep is not None and ep["epeek"].get("lines") == [], "a filter that matches nothing: no lines")

    g.click("pick", data="alpha")
    got = g.settle()
    mode = find(got, "mode")
    check(mode is not None and mode["mode"] == "chip", "a pick closes the epeek (mode chip)")

    g.click("about")
    got = g.settle()
    d = find(got, "set", "dialog")
    label = text_of(d["dialog"]["fields"][0].get("label")) if d and d["dialog"].get("fields") else ""
    check("zsh" in label, "about: a dialog naming the shell (win.shell)")

    g.click("closeIt", id="kill")
    got = g.settle()
    check(find(got, "closeDialog") is None, "after kill it doesn't close the dialog again")

    g.send({"t": "windowClose", "win": WIN})
    g.settle(0.5)
    g.send({"t": "gttyClose"})
    g.sock.shutdown(socket.SHUT_WR)
    try:
        code = g.proc.wait(timeout=3)
        check(code == 0, "gttyClose: it exits with 0")
    except subprocess.TimeoutExpired:
        g.proc.kill()
        check(False, "gttyClose: it exits")

    dev_check(argv)

    print("all passed" if not failures else f"{len(failures)} failed")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
