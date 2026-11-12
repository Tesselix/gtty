// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// commands: a chip that keeps the commands you run (all but the
// very common ones: cd, ls, pwd, …). A click on one copies it. See ../README.md.

"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
// gtty.js beside this file in a package; the SDK's own in this repository.
const gtty = require(fs.existsSync(path.join(__dirname, "gtty.js")) ? "./gtty.js" : "../../../sdks/javascript/gtty.js");

const FILE = "commands.tsv";
const KEEP = 500; // commands kept, the ones used last
const SHOWN = 200; // lines in the list at most
const WAIT_MS = 300; // storage timeout

// Never kept: the look-arounds, in any part of the line.
const EXCLUDED = new Set(["cd", "pushd", "popd", "ls", "ll", "la", "l", "lsd", "exa", "eza", "gls", "dir", "vdir", "pwd", "clear", "exit"]);
// Skipped in front of the command, with their own options.
const WRAPPERS = new Set(["sudo", "doas", "env", "time", "nohup", "nice", "command", "builtin", "exec"]);
// Wrapper options that take the next word.
const WRAPPER_ARG = {
  sudo: ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"],
  doas: ["-u", "-C"],
  env: ["-u", "-C", "-S", "-P"],
  nice: ["-n"],
};
const SEPARATORS = "|&;\n()";

// ---- which commands are kept (pure, tested by commands.test.js) ----

/** The line's parts, each a list of [raw, value] words: raw as typed,
 * value with the quotes and backslashes taken off. */
function segments(line) {
  const parts = [];
  let words = [];
  let raw = "";
  let val = "";
  let quote = null;
  let inWord = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (quote) {
      raw += ch;
      if (ch === quote) quote = null;
      else if (ch === "\\" && quote === '"' && i + 1 < line.length) {
        i++;
        raw += line[i];
        val += line[i];
      } else val += ch;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      raw += ch;
      inWord = true;
    } else if (ch === "\\" && i + 1 < line.length) {
      i++;
      raw += ch + line[i];
      if (line[i] !== "\n") val += line[i];
      inWord = true;
    } else if (ch === " " || ch === "\t" || SEPARATORS.includes(ch)) {
      if (inWord) {
        words.push([raw, val]);
        raw = "";
        val = "";
        inWord = false;
      }
      if (SEPARATORS.includes(ch) && words.length) {
        parts.push(words);
        words = [];
      }
    } else {
      raw += ch;
      val += ch;
      inWord = true;
    }
  }
  if (inWord) words.push([raw, val]);
  if (words.length) parts.push(words);
  return parts;
}

const isAssignment = (raw) => /^[A-Za-z_][A-Za-z0-9_]*=/.test(raw);
const isFlag = (raw) => raw.length >= 2 && raw[0] === "-" && raw !== "--";
const baseName = (s) => s.slice(s.lastIndexOf("/") + 1);

/** Is this command line worth keeping? See ../README.md. */
function worth(line) {
  if (!line.trim() || line[0] === " " || line[0] === "\t") return false;
  let found = false; // a part runs a command worth keeping
  for (const words of segments(line)) {
    let i = 0;
    // Assignments and wrappers in front, with the wrappers' options.
    while (i < words.length) {
      const [raw, val] = words[i];
      if (isAssignment(raw)) {
        i++;
        continue;
      }
      const name = baseName(val);
      if (!WRAPPERS.has(name)) break;
      i++;
      while (i < words.length && isFlag(words[i][0])) i += (WRAPPER_ARG[name] || []).includes(words[i][0]) ? 2 : 1;
    }
    if (i >= words.length) continue;
    if (!EXCLUDED.has(baseName(words[i][1]))) found = true;
  }
  return found;
}

// ---- the file: lines "count<TAB>last<TAB>command", escaped ----

const escape = (s) => s.replace(/\\/g, "\\\\").replace(/\t/g, "\\t").replace(/\n/g, "\\n").replace(/\r/g, "\\r");
const unescape = (s) => s.replace(/\\(.)/g, (_, c) => ({ t: "\t", n: "\n", r: "\r" })[c] || c);
const byUse = (a, b) => a[1] - b[1] || a[0] - b[0];

/** Entries [count, last, command], oldest use first. */
function parse(text) {
  const entries = [];
  for (const line of text.split("\n")) {
    const m = /^(\d+)\t(\d+)\t(.*)$/.exec(line);
    if (m) entries.push([Number(m[1]), Number(m[2]), unescape(m[3])]);
  }
  return entries.sort(byUse);
}

const formatEntries = (entries) => entries.map(([n, last, cmd]) => `${n}\t${last}\t${escape(cmd)}\n`).join("");

/** One more use of cmd; keeps the KEEP used last. */
function record(entries, cmd, now) {
  const e = entries.find((x) => x[2] === cmd);
  if (e) {
    e[0]++;
    e[1] = Math.max(e[1], now);
  } else entries.push([1, now, cmd]);
  entries.sort(byUse);
  return entries.slice(-KEEP);
}

// ---- storage ----

async function load(win) {
  let f;
  try {
    f = await win.stateful.openRead(FILE, WAIT_MS);
  } catch (e) {
    if (e.name === "NoFile") return [];
    throw e;
  }
  try {
    return parse((await f.readAll()).toString("utf8"));
  } finally {
    await f.close();
  }
}

async function save(win, entries) {
  const f = await win.stateful.openWrite(FILE, WAIT_MS);
  await f.write(formatEntries(entries));
  await f.close();
}

// ---- the clipboard: the SDK can't type into a window ----

/** null when copied, else why not. */
function copy(text) {
  const tools = [];
  if (process.platform === "darwin") tools.push(["pbcopy"]);
  else {
    if (process.env.WAYLAND_DISPLAY) tools.push(["wl-copy"]);
    tools.push(["xclip", "-selection", "clipboard"], ["xsel", "--clipboard", "--input"]);
  }
  for (const [cmd, ...args] of tools) {
    const r = spawnSync(cmd, args, { input: text, stdio: ["pipe", "ignore", "ignore"], timeout: 2000 });
    if (!r.error && r.status === 0) return null;
  }
  return "no clipboard tool (pbcopy, wl-copy, xclip, xsel)";
}

const PASTE = process.platform === "darwin" ? "⌘V" : "Ctrl+Shift+V";

// ---- the extension ----

const filters = new Map(); // win.id -> the filter's text

const oneLine = (cmd) => cmd.replace(/\r\n/g, "\n").replace(/\n/g, " ⏎ ").replace(/\t/g, " ");

function setList(win, entries) {
  const flt = (filters.get(win.id) || "").toLowerCase();
  let rows = [];
  for (const [n, , cmd] of entries) {
    const shown = oneLine(cmd);
    const at = flt ? shown.toLowerCase().indexOf(flt) : 0;
    if (at < 0) continue;
    let parts = [[shown]];
    // Mark the letters that match.
    if (flt) parts = [[shown.slice(0, at)], [shown.slice(at, at + flt.length), { fg: 0x202020, bk: 0xe0b040 }], [shown.slice(at + flt.length)]];
    if (n > 1) parts.push([`  ×${n}`, { fg: 0x8a8a8a }]);
    rows.push({
      id: String(rows.length),
      text: gtty.newText(...parts),
      onclick: "pick",
      data: cmd,
      postButton: {
        dots: "vertical",
        onclick: "rowMenu",
        items: [
          { id: "copy", text: "Copy", data: cmd },
          { id: "forget", text: "Forget", data: cmd },
        ],
      },
    });
  }
  rows = rows.slice(-SHOWN);
  win.ui.set({
    epeek: {
      frame: { text: "commands", filter: { hint: "filter commands", onclick: "filter" } },
      lines: rows,
      selected: Math.max(rows.length - 1, 0), // the newest, next to the chip
      empty: flt ? "no commands match" : "no commands yet: run one",
      footer: `a click copies it, ${PASTE} pastes it`,
      state: "idle",
      message: [],
    },
  });
}

function copyIt(win, cmd) {
  const why = copy(cmd);
  if (why) {
    win.log("warn", why);
    win.ui.set({ epeek: { state: "err", message: [why] } });
  } else win.ui.set({ epeek: { state: "ok", message: [`copied: ${PASTE} pastes it`] } });
}

// Every onclick / onhover name is a function here.
const actions = {
  async open(win) {
    setList(win, await load(win)); // other windows may have added commands
    win.ui.setDisplayMode("epeek");
  },
  async filter(win, b) {
    filters.set(win.id, b.text);
    setList(win, await load(win));
  },
  pick(win, b) {
    copyIt(win, b.data);
  },
  async rowMenu(win, b) {
    if (b.id === "copy") copyIt(win, b.data);
    else if (b.id === "forget") {
      const entries = (await load(win)).filter((e) => e[2] !== b.data);
      await save(win, entries);
      setList(win, entries);
    }
  },
};

if (require.main === module) {
  gtty.run({
    async onWindowStart(win) {
      filters.set(win.id, "");
      win.events.register("command_started");
      // A click and the mouse resting on the chip both open the list.
      win.ui.set({ chip: { text: "commands", onclick: "open", onhover: "open" } });
      setList(win, await load(win));
    },
    onWindowClose(win) {
      filters.delete(win.id);
    },
    async onEvent(win, ev) {
      if (ev.kind === "button_click") await gtty.dispatch(actions, win, ev);
      else if (ev.kind === "command_started" && worth(ev.command)) {
        try {
          await save(win, record(await load(win), ev.command.trim(), Math.floor(Date.now() / 1000)));
        } catch (e) {
          if (e.name !== "FileInUse") throw e;
          win.log("warn", "commands.tsv busy: a command not kept");
        }
      }
    },
  });
}

module.exports = { worth, segments, parse, formatEntries, record, KEEP };
