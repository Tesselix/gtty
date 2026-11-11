// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

/**
 * The gtty SDK for JavaScript (Node.js 18 or later, no packages).
 *
 * Copy this file (and gtty.d.ts for editors and TypeScript) next to your
 * extension's main file. AI assistants: read AGENTS.md first;
 * examples/hosts.js is a complete extension.
 *
 * An extension is an object with any of these functions, each may be async:
 *
 *   onGttyStart(ext)      once, when it starts
 *   onWindowStart(win)    each window: the open ones, then new ones
 *   onWindowClose(win)    a notice: the window is gone
 *   onGttyClose(ext)      a notice: gtty is closing
 *   onEvent(win, ev)      registered events and clicks
 *
 * and `require("./gtty").run(extension)`. gtty starts it
 * (docs/protocol.md). Callbacks run one at a time, each to its end (an
 * async one until it settles). Calls that answer (shell, storage) return
 * promises.
 */

"use strict";

const net = require("net");
const fs = require("fs");

const API_VERSION = 1;

class GttyError extends Error {
  constructor(name, message) {
    super(message || name);
    this.name = name;
  }
}

const ERRORS = ["WindowClosed", "NoChip", "BadName", "NoFile", "FileInUse", "FileClosed", "StorageFull", "StorageFailed"];

function color(v) {
  return typeof v === "number" ? "#" + (v & 0xffffff).toString(16).padStart(6, "0") : v;
}

function part(string, attr) {
  const p = { string };
  for (const [k, v] of Object.entries(attr || {})) {
    if (!["fg", "bk", "size", "bold", "stroke"].includes(k)) throw new TypeError("unknown text attribute: " + k);
    if (v === undefined || v === null || v === false) continue;
    p[k] = k === "fg" || k === "bk" ? color(v) : v;
  }
  return p;
}

/**
 * A text: newText("main"), newText("main", { bold: true, fg: 0xe0b040 }),
 * or parts: newText(["feature/"], ["login", { bold: true }]). Colors are
 * 0xrrggbb or "#rrggbb"; size is percent (50-200); at most 8 parts. A
 * plain string works wherever a text goes, too.
 */
function newText(...args) {
  if (args.length <= 2 && typeof args[0] === "string" && (args.length === 1 || !Array.isArray(args[1]))) {
    return args.length === 1 ? args[0] : [part(args[0], args[1])];
  }
  return args.slice(0, 8).map((a) => (typeof a === "string" ? part(a) : part(a[0], a[1])));
}

class ButtonClick {
  constructor(d) {
    /** For a dialog: ok, cancel, yes, no, or kill / timeout (already closed). */
    this.id = d.id || "";
    this.text = d.text || "";
    this.data = d.data || "";
    this.function = d.function || "";
    this.fields = d.fields || [];
    this.command = !!d.command;
  }
  /** A text box's or drop box's value, or null. */
  field(id) {
    const f = this.fields.find((x) => x.id === id && typeof x.value === "string");
    return f ? f.value : null;
  }
  /** A check box's value. */
  checked(id) {
    const f = this.fields.find((x) => x.id === id && typeof x.value === "boolean");
    return f ? f.value : false;
  }
}

class Event {
  constructor(d) {
    this.eventId = d.eventId || 0;
    /** window_changed, command_started, key or button_click */
    this.kind = d.kind || "";
    this.folder = d.folder || "";
    this.branch = d.branch || "";
    this.remote = !!d.remote;
    this.command = d.command || "";
    // key: its name, what it typed, the modifier keys (cmd: ⌘ / Super)
    this.key = d.key || "";
    this.text = d.text || "";
    this.ctrl = !!d.ctrl;
    this.shift = !!d.shift;
    this.alt = !!d.alt;
    this.cmd = !!d.cmd;
    this.button = d.button ? new ButtonClick(d.button) : null;
  }
}

/** The central on-click: calls actions[button.function](win, button). */
function dispatch(actions, win, ev) {
  const b = ev.button;
  if (!b) return undefined;
  const f = Object.prototype.hasOwnProperty.call(actions, b.function) ? actions[b.function] : undefined;
  if (typeof f !== "function") throw new Error("no function " + JSON.stringify(b.function) + " in actions");
  return f(win, b);
}

class Conn {
  constructor(sock) {
    this.sock = sock;
    this.buf = "";
    this.nextId = 0;
    this.waiting = new Map();
    this.queue = [];
    this.busy = false;
    this.currentEv = 0;
    this.onMessage = null;
    this.onEnd = null;
    sock.setEncoding("utf8");
    sock.on("data", (chunk) => this.data(chunk));
    sock.on("end", () => this.end());
    sock.on("close", () => this.end());
    sock.on("error", () => this.end());
  }
  send(msg) {
    if (!this.sock.destroyed) this.sock.write(JSON.stringify(msg) + "\n");
  }
  data(chunk) {
    this.buf += chunk;
    let nl;
    while ((nl = this.buf.indexOf("\n")) >= 0) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      let m;
      try {
        m = JSON.parse(line);
      } catch {
        continue;
      }
      // A reply goes to its call at once; the rest in turn.
      if (m.t === "reply") {
        const w = this.waiting.get(m.id);
        if (w) {
          this.waiting.delete(m.id);
          if (m.error !== undefined) w.reject(new GttyError(ERRORS.includes(m.error) ? m.error : "StorageFailed"));
          else w.resolve(m.value);
        }
        continue;
      }
      this.queue.push(m);
    }
    this.drain();
  }
  async drain() {
    if (this.busy) return;
    this.busy = true;
    try {
      while (this.queue.length > 0) await this.onMessage(this.queue.shift());
    } finally {
      this.busy = false;
    }
  }
  end() {
    if (this.ended) return;
    this.ended = true;
    for (const w of this.waiting.values()) w.reject(new GttyError("WindowClosed", "gtty is gone"));
    this.waiting.clear();
    if (this.onEnd) this.onEnd();
  }
  call(win, op, fields) {
    if (this.ended) return Promise.reject(new GttyError("WindowClosed", "gtty is gone"));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.waiting.set(id, { resolve, reject });
      this.send({ t: "call", id, win, op, ...fields });
    });
  }
}

let conn = null;

const LEVELS = ["debug", "info", "warn", "err"];

function log(win, level, message) {
  if (!LEVELS.includes(level)) throw new TypeError("level: debug, info, warn or err");
  conn.send({ t: "log", win, level, message: String(message).slice(0, 4096) });
}

class Ui {
  constructor(win) {
    this.win = win;
  }
  /**
   * Set one of chip, peek, epeek or dialog: win.ui.set({ chip: { text: "main" } }).
   * A key left out stays, null clears it; { peek: null } or { epeek: null }
   * removes it. Errors go to `gtty ext logs`.
   */
  set(update) {
    const keys = Object.keys(update || {});
    if (keys.length !== 1 || !["chip", "peek", "epeek", "dialog"].includes(keys[0])) {
      throw new TypeError("win.ui.set: one of chip, peek, epeek or dialog");
    }
    this.win.post("set", update);
  }
  /** "chip" (closes this extension's peek or epeek), "peek" or "epeek". */
  setDisplayMode(mode) {
    if (!["chip", "peek", "epeek"].includes(mode)) throw new TypeError("mode: chip, peek or epeek");
    this.win.post("mode", { mode, ev: conn.currentEv });
  }
  showDialog() {
    this.win.post("showDialog", { ev: conn.currentEv });
  }
  /** The buttons only report: close it yourself (not after kill or timeout). */
  closeDialog() {
    this.win.post("closeDialog", {});
  }
}

class Events {
  constructor(win) {
    this.win = win;
  }
  /** "window_changed", "command_started" or "key"; clicks come without. */
  register(kind) {
    if (kind === "button_click") return;
    if (!["window_changed", "command_started", "key"].includes(kind)) throw new TypeError("unknown event: " + kind);
    this.win.post("register", { event: kind });
  }
  unregister(kind) {
    if (kind === "button_click") return;
    this.win.post("unregister", { event: kind });
  }
}

class File {
  constructor(win, handle) {
    this.win = win;
    this.handle = handle;
  }
  /** Up to `size` bytes (a Buffer); empty at the end. */
  async read(size = 65536) {
    const v = await conn.call(this.win.id, "read", { handle: this.handle, max: Math.max(1, Math.min(size, 1 << 20)) });
    return Buffer.from(v || "", "base64");
  }
  async readAll() {
    const parts = [];
    for (;;) {
      const p = await this.read(1 << 20);
      if (p.length === 0) return Buffer.concat(parts);
      parts.push(p);
    }
  }
  /** A Buffer or a string (UTF-8). */
  async write(data) {
    const b = Buffer.isBuffer(data) ? data : Buffer.from(String(data));
    for (let i = 0; i < Math.max(b.length, 1); i += 1 << 20) {
      await conn.call(this.win.id, "write", { handle: this.handle, data: b.subarray(i, i + (1 << 20)).toString("base64") });
    }
  }
  /** A file opened for writing takes the old one's place now. */
  async close() {
    if (this.handle === null) return;
    const h = this.handle;
    this.handle = null;
    await conn.call(this.win.id, "close", { handle: h });
  }
}

class Storage {
  constructor(win, kind) {
    this.win = win;
    this.kind = kind;
  }
  /** Waits up to timeoutMs (0: tries once). Replaces the whole file at close. */
  async openWrite(name, timeoutMs = 0) {
    return new File(this.win, await conn.call(this.win.id, "open", { storage: this.kind, name, mode: "write", timeout: timeoutMs }));
  }
  /** Waits up to timeoutMs while someone writes it. No such file: NoFile. */
  async openRead(name, timeoutMs = 0) {
    return new File(this.win, await conn.call(this.win.id, "open", { storage: this.kind, name, mode: "read", timeout: timeoutMs }));
  }
  async delete(name, timeoutMs = 0) {
    await conn.call(this.win.id, "delete", { storage: this.kind, name, timeout: timeoutMs });
  }
  async list() {
    return (await conn.call(this.win.id, "list", { storage: this.kind })) || [];
  }
}

class Window {
  constructor(id) {
    this.id = id;
    this.ui = new Ui(this);
    this.events = new Events(this);
    /** This instance's files, gone with the window. */
    this.ephemeral = new Storage(this, "ephemeral");
    /** The extension's files, shared by all its instances. */
    this.stateful = new Storage(this, "stateful");
    this.closed = false;
  }
  post(t, fields) {
    if (this.closed) throw new GttyError("WindowClosed");
    conn.send({ t, win: this.id, ...fields });
  }
  /** The shell in front; if something else is in front, the window's own. */
  shell() {
    return conn.call(this.id, "shell", {});
  }
  /** A line in `gtty ext logs`, with this window's id. */
  log(level, message) {
    log(this.id, level, message);
  }
}

class Extension {
  constructor(name) {
    this.name = name;
  }
  log(level, message) {
    log(0, level, message);
  }
}

/** Where an extension gtty didn't start connects: GTTY_EXT_SOCKET, else
 * the newest gtty's shared address (only when the folder is this user's
 * alone). */
function devSocket() {
  if (process.env.GTTY_EXT_SOCKET) return process.env.GTTY_EXT_SOCKET;
  const folder = `${(process.env.TMPDIR || "/tmp").replace(/\/+$/, "")}/gtty-dev-${process.getuid()}`;
  try {
    const st = fs.lstatSync(folder);
    if (st.uid !== process.getuid() || (st.mode & 0o077) !== 0) return null;
  } catch {
    return null;
  }
  return folder + "/ext.sock";
}

/** [socket, debugging]: gtty's socket on GTTY_EXT_FD, or the developer
 * socket when an IDE started it. */
function connect() {
  if (process.env.GTTY_EXT_FD) return [new net.Socket({ fd: Number(process.env.GTTY_EXT_FD), readable: true, writable: true }), false];
  const path = devSocket();
  let ok = false;
  try {
    ok = path !== null && fs.statSync(path).isSocket();
  } catch {}
  if (!ok) {
    process.stderr.write("No gtty to connect to: start gtty first (or set GTTY_EXT_SOCKET, see `gtty ext socket`).\n");
    process.exit(2);
  }
  return [net.createConnection(path), true];
}

/** Run the extension; the promise settles when gtty closes. */
function run(ext) {
  return new Promise((resolve) => {
    const [sock, debugging] = connect();
    conn = new Conn(sock);
    // Started by an IDE: say which extension this is.
    if (debugging) conn.send({ t: "attach", api: API_VERSION, name: process.env.GTTY_EXT_NAME || "", dir: process.cwd() });
    let name = process.env.GTTY_EXT_NAME || "extension";
    const windows = new Map();
    const report = (win, callback, e) => {
      if (e instanceof GttyError && e.name === "WindowClosed") return;
      log(win, "err", callback + " threw " + (e && e.stack ? e.stack.split("\n").slice(0, 3).join(" | ") : String(e)));
    };
    const call = async (win, callback, ...args) => {
      const f = ext[callback];
      if (typeof f !== "function") return;
      try {
        await f.apply(ext, args);
      } catch (e) {
        report(win, callback, e);
      }
    };
    const finish = () => {
      conn.sock.end();
      resolve();
    };
    conn.onEnd = resolve;
    conn.onMessage = async (m) => {
      const win = m.win || 0;
      switch (m.t) {
        case "refused":
          process.stderr.write(`gtty refused the connection: ${m.reason || ""}\n`);
          process.exit(1);
          return;
        case "hello":
          if (m.api !== API_VERSION) {
            process.stderr.write(`gtty speaks extension API ${m.api}, this SDK ${API_VERSION}\n`);
            return finish();
          }
          name = m.name || name;
          return;
        case "gttyStart":
          return call(0, "onGttyStart", new Extension(name));
        case "gttyClose":
          await call(0, "onGttyClose", new Extension(name));
          return finish();
        case "windowStart": {
          const w = new Window(win);
          windows.set(win, w);
          return call(win, "onWindowStart", w);
        }
        case "windowClose": {
          const w = windows.get(win);
          if (!w) return;
          windows.delete(win);
          w.closed = true;
          return call(win, "onWindowClose", w);
        }
        case "event": {
          const w = windows.get(win);
          if (!w) return;
          const ev = new Event(m.event || {});
          conn.currentEv = ev.eventId;
          try {
            await call(win, "onEvent", w, ev);
          } finally {
            conn.currentEv = 0;
          }
          return;
        }
        default:
      }
    };
  });
}

module.exports = { run, dispatch, newText, GttyError, Window, Extension, Event, ButtonClick, API_VERSION };
