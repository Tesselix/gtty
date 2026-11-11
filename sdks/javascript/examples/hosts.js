// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// A complete extension: a chip that keeps a list of hosts. It uses every
// part of the SDK and is checked by sdks/conformance/fake_gtty.py, so it
// can't fall behind. Start a new extension from a copy of this file,
// gtty.js and manifest.json.

"use strict";

const fs = require("fs");
const path = require("path");
// gtty.js beside this file in a package; the SDK's own in its tree.
const gtty = require(fs.existsSync(path.join(__dirname, "gtty.js")) ? "./gtty.js" : "../gtty.js");

const FILE = "hosts.txt";

// onWindowStart runs once per window: state goes by win.id.
const filters = new Map();

async function readHosts(win) {
  let f;
  try {
    f = await win.stateful.openRead(FILE, 200);
  } catch (e) {
    if (e.name === "NoFile") return ""; // no file yet: an empty list
    throw e;
  }
  try {
    return (await f.readAll()).toString();
  } finally {
    await f.close();
  }
}

const ROW_MENU = [{ id: "connect", text: "Connect" }, { id: "remove", text: "Remove" }];

async function setList(win) {
  const flt = filters.get(win.id) || "";
  const rows = [];
  for (const host of (await readHosts(win)).split("\n")) {
    if (!host) continue;
    // gtty doesn't filter: the extension decides what the text means.
    const at = flt ? host.toLowerCase().indexOf(flt.toLowerCase()) : 0;
    if (at < 0) continue;
    let text = host;
    if (flt) {
      // Mark the letters that match.
      text = gtty.newText([host.slice(0, at)], [host.slice(at, at + flt.length), { fg: 0x202020, bk: 0xe0b040 }], [host.slice(at + flt.length)]);
    }
    rows.push({ id: host, text, onclick: "pick", data: host, postButton: { dots: "vertical", onclick: "rowMenu", items: ROW_MENU } });
  }
  win.ui.set({
    epeek: {
      frame: { text: "hosts", filter: { hint: "filter hosts", onclick: "filter" }, right: [{ icon: "save", text: "add", onclick: "askHost" }] },
      lines: rows,
      selected: 0,
      empty: "no hosts",
    },
  });
}

// Every onclick / onhover / onexpand name is a function here.
const actions = {
  open(win) {
    win.log("debug", "opening the peek");
    win.ui.setDisplayMode("peek");
  },
  // Other windows may have added hosts.
  refresh: (win) => setList(win),
  filter(win, b) {
    filters.set(win.id, b.text);
    return setList(win);
  },
  pick(win, b) {
    win.ui.set({ chip: { text: b.data } });
    win.ui.setDisplayMode("chip"); // gtty only reports: close it here
  },
  // A ⋮ pick: b.id is the item's.
  rowMenu(win, b) {
    if (b.id === "connect") win.ui.setDisplayMode("chip");
  },
  async about(win) {
    win.ui.set({
      dialog: {
        title: "About hosts", layout: "form", timeout: 20, buttons: "ok", onclick: "closeIt",
        fields: [{ id: "info", type: "label", label: "running under " + (await win.shell()) }],
      },
    });
    win.ui.showDialog();
  },
  closeIt(win, b) {
    // After kill and timeout the dialog is already gone.
    if (b.id !== "kill" && b.id !== "timeout") win.ui.closeDialog();
  },
  askHost(win) {
    win.ui.set({
      dialog: {
        title: "Add a host", layout: "form", timeout: 30, buttons: "okcancel", onclick: "addHost",
        fields: [
          { id: "host", type: "text", label: "Host", value: "" },
          { id: "pin", type: "checkbox", label: "Show on the chip", value: false },
          { id: "kind", type: "dropdown", label: "Kind", value: "ssh", options: ["ssh", "mosh"], filter: false },
        ],
      },
    });
    win.ui.showDialog();
  },
  async addHost(win, b) {
    if (b.id === "kill" || b.id === "timeout") return;
    if (b.id === "ok") {
      const host = b.field("host") || "";
      // To reject input, update the dialog and leave it open.
      if (!host) return win.ui.set({ dialog: { error: "enter a host" } });
      const old = await readHosts(win);
      // A write replaces the whole file, at close.
      const f = await win.stateful.openWrite(FILE, 200);
      await f.write(old + host + "\n");
      await f.close();
      if (b.checked("pin")) win.ui.set({ chip: { text: host } });
      await setList(win);
    }
    win.ui.closeDialog(); // the buttons only report
  },
};

gtty.run({
  async onWindowStart(win) {
    filters.set(win.id, "");
    win.events.register("window_changed");
    // Keys: F6 opens the list. The key still reaches the program too.
    win.events.register("key");
    // A UI needs a chip. Hover opens nothing by itself: onhover does.
    win.ui.set({ chip: { text: "hosts", onhover: "open" } });
    win.ui.set({
      peek: { expand: true, onexpand: "refresh", text: gtty.newText("hosts", { bold: true }), postButton: { dots: "horizontal", onclick: "about" } },
    });
    await setList(win);
  },
  onWindowClose(win) {
    filters.delete(win.id);
  },
  async onEvent(win, ev) {
    if (ev.kind === "button_click") await gtty.dispatch(actions, win, ev);
    else if (ev.kind === "window_changed") win.ui.set({ chip: { dimmed: ev.remote } });
    else if (ev.kind === "key" && ev.key === "f6" && !(ev.ctrl || ev.shift || ev.alt || ev.cmd)) win.ui.setDisplayMode("epeek");
  },
});
