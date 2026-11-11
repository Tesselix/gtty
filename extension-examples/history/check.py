#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
"""Runs one history extension through a conversation with a stand-in gtty
(the SDKs' conformance check, sdks/conformance/fake_gtty.py) and checks
what it does:

    python3 ../check.py -- <command that starts it>

Exit code 0: it behaved. --verbose prints every message. The clipboard
isn't touched: HISTORY_CLIP_FILE takes the copy instead.
"""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "sdks", "conformance"))
import fake_gtty as fg  # noqa: E402
from fake_gtty import WIN, check, find, text_of  # noqa: E402


def command(g, eid, cmd):
    g.send({"t": "event", "win": WIN, "event": {"eventId": eid, "kind": "command_started",
                                                "command": cmd, "folder": "/tmp", "remote": False}})
    return g.settle()


def stored(g):
    """The commands in history.tsv, with their counts."""
    out = {}
    for line in g.files.get("history.tsv", b"").decode().split("\n"):
        f = line.split("\t", 2)
        if len(f) == 3:
            out[f[2]] = int(f[0])
    return out


def last_epeek(msgs):
    eps = [m["epeek"] for m in msgs if m["t"] == "set" and "epeek" in m]
    return eps[-1] if eps else None


def main():
    if "--" not in sys.argv:
        print(__doc__)
        return 2
    argv = sys.argv[sys.argv.index("--") + 1:]
    clip = tempfile.NamedTemporaryFile(prefix="history-clip-", delete=False).name
    os.environ["HISTORY_CLIP_FILE"] = clip
    g = fg.Fake(argv)
    try:
        g.send({"t": "hello", "api": 1, "name": "history"})
        g.send({"t": "gttyStart"})
        g.send({"t": "windowStart", "win": WIN})
        got = g.settle(5)
        regs = [m["event"] for m in got if m["t"] == "register" and m.get("win") == WIN]
        check(regs == ["command_started"], "registers command_started only")
        chip = find(got, "set", "chip")
        check(chip is not None and text_of(chip["chip"].get("text")) == "history"
              and chip["chip"].get("onclick") == "open" and chip["chip"].get("onhover") == "open",
              "sets its chip: history, onclick and onhover open")
        ep = last_epeek(got)
        check(ep is not None and ep.get("lines") == [] and "filter" in ep.get("frame", {}),
              "sets an empty list with a filter (nothing kept yet)")

        for i, cmd in enumerate(["ls -la", "cp -r a b", "git status", "cd /tmp", "cp -r a b",
                                 "cp a.txt b.txt", "kill -9 1234", " ssh -p 22 secret"]):
            command(g, 200 + i, cmd)
        check(stored(g) == {"cp -r a b": 2, "kill -9 1234": 1},
              "keeps only the commands with a flag, counted: %s" % stored(g))

        ev = g.click("open")
        got = g.settle()
        mode = find(got, "mode")
        check(mode is not None and mode["mode"] == "epeek" and mode.get("ev") == ev, "open: mode epeek")
        ep = last_epeek(got)
        lines = ep.get("lines", []) if ep else []
        texts = sorted(text_of(l.get("text")) for l in lines)
        check(texts == ["cp -r a b  ×2", "kill -9 1234"], "open: the list, with the count: %s" % texts)
        check(ep is not None and ep.get("selected") == len(lines) - 1, "open: the newest (last) line selected")
        check(all(l.get("onclick") == "pick" and l.get("data") for l in lines), "each line: onclick pick, data the command")

        g.click("filter", id="filter", text="KILL")
        ep = last_epeek(g.settle())
        lines = ep.get("lines", []) if ep else []
        check(len(lines) == 1 and text_of(lines[0].get("text")) == "kill -9 1234", "filter (any case): one line")
        parts = lines[0].get("text") if lines else None
        check(isinstance(parts, list) and any(isinstance(p, dict) and p.get("string") == "kill" and p.get("bk") for p in parts),
              "filter: the matching letters marked")
        g.click("filter", id="filter", text="")

        g.settle()
        g.click("pick", data="cp -r a b")
        ep = last_epeek(g.settle())
        with open(clip) as f:
            check(f.read() == "cp -r a b", "pick: copies the command")
        check(ep is not None and ep.get("state") == "ok", "pick: state ok (closes the list)")

        g.click("rowMenu", id="forget", data="kill -9 1234")
        ep = last_epeek(g.settle())
        check(stored(g) == {"cp -r a b": 2}, "⋮ Forget: removed from the file")
        check(ep is not None and len(ep.get("lines", [])) == 1, "⋮ Forget: and from the list")

        g.send({"t": "windowClose", "win": WIN})
        g.send({"t": "gttyClose"})
        g.sock.close()
        try:
            code = g.proc.wait(timeout=5)
            check(code == 0, "ends with exit code 0 when gtty closes")
        except Exception:
            check(False, "ends when gtty closes")
    finally:
        if g.proc.poll() is None:
            g.proc.kill()
        os.unlink(clip)
    print("%d failed" % len(fg.failures) if fg.failures else "all good")
    return 1 if fg.failures else 0


if __name__ == "__main__":
    sys.exit(main())
