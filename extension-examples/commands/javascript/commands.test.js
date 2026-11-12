// SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
// SPDX-License-Identifier: GPL-3.0-or-later

// The rules (../cases.tsv) and the file. Run: node --test

"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");
const h = require("./commands.js");

function cases() {
  const out = [];
  for (const line of fs.readFileSync(path.join(__dirname, "..", "cases.tsv"), "utf8").split("\n")) {
    if (!line || line.startsWith("#")) continue;
    const tab = line.indexOf("\t");
    out.push([line.slice(0, tab) === "keep", line.slice(tab + 1).replace(/\\n/g, "\n").replace(/\\t/g, "\t").replace(/\\s/g, " ")]);
  }
  return out;
}

test("the cases", () => {
  const all = cases();
  assert.ok(all.length > 30);
  for (const [keep, cmd] of all) assert.strictEqual(h.worth(cmd), keep, JSON.stringify(cmd));
});

test("the file round trip", () => {
  const entries = [
    [1, 10, "a -x"],
    [3, 20, "printf -v x 'a\tb\\n'\necho -n done"],
  ];
  assert.deepStrictEqual(h.parse(h.formatEntries(entries)), entries);
});

test("bad lines skipped", () => {
  assert.deepStrictEqual(h.parse("x\t1\ta\n2\t5\tb -c\n\n"), [[2, 5, "b -c"]]);
});

test("record", () => {
  let e = h.record([], "a -x", 10);
  e = h.record(e, "b -y", 11);
  e = h.record(e, "a -x", 12);
  assert.deepStrictEqual(e, [
    [1, 11, "b -y"],
    [2, 12, "a -x"],
  ]);
});

test("keeps the used last", () => {
  let e = [];
  for (let i = 0; i < h.KEEP + 5; i++) e = h.record(e, `c -${i}`, i);
  assert.strictEqual(e.length, h.KEEP);
  assert.strictEqual(e[0][2], "c -5");
});
