# commands: commands worth running again

An example gtty extension, written once per SDK: [python](python/),
[javascript](javascript/), [go](go/) and [zig](zig/). All four do the
same thing and pass the same tests, so they also check the SDKs against
each other.

A **commands** chip in each window's footer. It keeps the commands you
run, and a click (or the mouse resting on it) opens the list:

- The oldest at the top, the newest at the bottom, next to the chip, and
  selected. A command run several times shows `×N` and moves down.
- Type to filter (any case; the matching letters are marked).
- A click on a command copies it to the clipboard; ⌘V (Linux Ctrl+Shift+V)
  pastes it. The SDK has no way to type into a window, so the clipboard is
  the way in: the extension runs `pbcopy` (macOS), else `wl-copy`
  (Wayland), `xclip` or `xsel` (X11).
- Its ⋮: Copy, Forget (removes it from the list).

The list is shared by every window and every gtty (the extension's
stateful storage, `commands.tsv`; each language's extension keeps its
own). It keeps 500 commands; past that the
ones used longest ago go.

## Which commands are kept

Every command that starts in the window's shell, except the very common
ones:

1. A line is dropped when every part of it is **cd**, **ls**, **pwd**,
   **clear** or **exit** (`cd`, `pushd`, `popd`, `ls`, `ll`, `la`, `l`,
   `lsd`, `exa`, `eza`, `gls`, `dir`, `vdir`, `pwd`, `clear`, `exit`, by
   name or path: `/bin/ls`). The parts are what `|`, `&&`, `||`, `;`,
   `&`, a line break and `( )` separate: `cd src; ls` is dropped, `cd
   build && make -j8` is kept.
2. The command is the first word after `sudo`, `doas`, `env`, `time`,
   `nohup`, `nice`, `command`, `builtin`, `exec` and their options, and
   `NAME=value` in front: `sudo ls -la /root` is dropped, `FOO=1` alone (no
   command) too.
3. A line that starts with a blank is never kept: the shells' way to say
   "don't remember this" (zsh `HIST_IGNORE_SPACE`, bash
   `HISTCONTROL=ignorespace`).

gtty reports a command when it starts, not how it ended, so a command
that failed is kept too.

[cases.tsv](cases.tsv) lists examples; every language's tests run them.
Change the rules in all four, and the table, together.

Only what gtty reports as a command started in the window's own shell
(`command_started`) is seen: commands typed inside ssh, or in a program
such as python, are not.

## Build, test, install

Each language's extension has its own name (`commands-python`,
`commands-javascript`, `commands-go`, `commands-zig`), so all four can be
installed side by side.

Tests, in each language's folder:

| Language | Test |
|---|---|
| Python 3.8+ | `python3 test_commands.py` |
| JavaScript (Node 18+) | `node --test` |
| Go 1.21+ | `go test ./...` |
| Zig 0.16 | `zig build test` |

CI runs them for all four.

`./package.sh` packs the extension into one file, gtty's jar:
`build/<name>-<version>.tar.gz` (from `manifest.json`), e.g.
`build/commands-javascript-1.0.0.tar.gz`. Python and JavaScript: the
script, the SDK's `gtty.py` / `gtty.js`, the manifest and the LICENSE;
the runtime (`python3`, `node`) comes from the machine. Go and Zig: the
programs for macOS arm64 and Linux x86_64. Install it with **Install…** in gtty ▸
Extensions… (or drop it on that window), or `gtty ext install <file>`;
`gtty ext logs -f commands-javascript` follows its log.

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
runs: it connects to the newest gtty, and the installed copy steps
aside until it ends. See the SDK's `AGENTS.md`, "Debug".
