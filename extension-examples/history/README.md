# history: commands worth running again

An example gtty extension, written four times, once per SDK: [python](python/),
[javascript](javascript/), [go](go/) and [zig](zig/). All four do the same
thing, keep the same file and pass the same tests, so they also check the
SDKs against each other.

A **history** chip in each window's footer. It keeps the commands you run
that are worth running again, and a click (or the mouse resting on it)
opens the list:

- The oldest at the top, the newest at the bottom, next to the chip, and
  selected. A command run several times shows `×N` and moves down.
- Type to filter (any case; the matching letters are marked).
- A click on a command copies it to the clipboard; ⌘V (Linux Ctrl+Shift+V)
  pastes it. The SDK has no way to type into a window, so the clipboard is
  the way in: the extension runs `pbcopy` (macOS), else `wl-copy`
  (Wayland), `xclip` or `xsel` (X11).
- Its ⋮: Copy, Forget (removes it from the list).

The list is shared by every window and every gtty (the extension's
stateful storage, `history.tsv`). It keeps 500 commands; past that the
ones used longest ago go.

## Which commands are kept

A command is kept when it has a flag and isn't a look around:

1. It has at least one **flag**: a word that starts with `-` as typed
   (`-r`, `-9`, `--force`, `-Doptimize=ReleaseFast`). `-` and `--` alone
   aren't flags, nor is a quoted `"-x"` (that is data).
   `cp a.txt b.txt` and `open folder-name` only name files: dropped.
   `cp -r a b` and `open -e a.txt` are kept.
2. No part of it runs **cd** or **ls** or **find** (`cd`, `pushd`, `popd`,
   `ls`, `ll`, `la`, `l`, `lsd`, `exa`, `eza`, `gls`, `dir`, `vdir`,
   `find`, by name or path: `/bin/ls`). The parts are what `|`, `&&`,
   `||`, `;`, `&`, a line break and `( )` separate, so `cd build && make
   -j8` and `find . | xargs wc -l` are dropped.
3. A flag counts only when it belongs to the command, not to a wrapper in
   front: `sudo`, `doas`, `env`, `time`, `nohup`, `nice`, `command`,
   `builtin`, `exec`, and `NAME=value` before the command, are skipped
   with their own options (`sudo -u postgres psql` has no flag of its
   own: dropped; `sudo -u postgres psql -c '…'` is kept).
4. A line that starts with a blank is never kept: the shells' way to say
   "don't remember this" (zsh `HIST_IGNORE_SPACE`, bash
   `HISTCONTROL=ignorespace`).

[cases.tsv](cases.tsv) lists examples; every language's tests run them.
Change the rules in all four, and the table, together.

Only what gtty reports as a command started in the window's own shell
(`command_started`) is seen: commands typed inside ssh, or in a program
such as python, are not.

## Build, test, install

All four packages are named `history`: installing one replaces the other.
To run two side by side, change one's `name` in its `manifest.json`.

In each language's folder:

| Language | Test | Whole conversation |
|---|---|---|
| Python 3.8+ | `python3 test_history.py` | `python3 ../check.py -- python3 history.py` |
| JavaScript (Node 18+) | `node --test` | `python3 ../check.py -- node history.js` |
| Go 1.21+ | `go test ./...` | `go build -o history . && python3 ../check.py -- ./history` |
| Zig 0.16 | `zig build test` | `zig build && python3 ../check.py -- zig-out/bin/history` |

`check.py` talks to the extension as gtty would (the SDKs' conformance
stand-in): commands started, a click on the chip, a filter, a pick, ⋮
Forget. CI runs both columns for all four.

`./package.sh` makes the package in `build/history/` (and
`build/history.tar.gz`): Go and Zig for macOS arm64 and Linux x86_64.
Then `gtty ext install build/history`, and `gtty ext logs -f history` for
its log.

Each project takes the SDK from this repository (`../../../sdks/…`);
`package.sh` copies what the package needs, so the package stands alone.
Outside this repository, use the SDK's release archive
(`gtty-sdk-<language>-<version>.tar.gz`):

- Python, JavaScript: `GTTY_SDK=<the unpacked archive> ./package.sh`.
- Go: point the `replace` line in `go.mod` at the unpacked archive.
- Zig: `zig fetch --save=gtty <the archive's URL>` in place of the
  `.path` dependency in `build.zig.zon`.

## Debug

Run it from the IDE (each folder has a `.vscode/launch.json`) while gtty
runs: it connects to the newest gtty, and an installed `history` steps
aside until it ends. See the SDK's `AGENTS.md`, "Debug".
