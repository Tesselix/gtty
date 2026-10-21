# gtty — True Graphic Virtual Terminal

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/gttyterm/gtty/badge)](https://scorecard.dev/viewer/?uri=github.com/gttyterm/gtty)

A multi-window terminal: all your shells and commands on one screen, side
by side or one click away.

![Several terminal windows on one screen: finished ones turn green, a failed one red, the rest wait in the grid on the right](docs/images/hero.webp)

## Install

<!-- TODO: link the downloads once releases are published (codeberg.org/gttyterm/gtty, not created yet). -->

- **macOS** (Apple Silicon, 13+): download `gtty-<version>-macos.dmg` from
  the releases page *(TODO: link)* and drag gtty to Applications.
- **Linux** (x86_64): download `gtty-<version>-linux-x86_64.tar.gz` *(TODO:
  link)*, then `tar xzf gtty-*-linux-x86_64.tar.gz && sudo ./gtty-*/install.sh`
  (or `PREFIX=~/.local ./gtty-*/install.sh` for just you). `.deb` and
  `.rpm` packages are built too *(TODO: link)*.
- **Package managers:** *TODO* (no Homebrew tap or distro package yet).
- **From source:** see [HACKING.md](HACKING.md) (Zig 0.16 + SDL3).

## Features

### Edit long commands like text

![A command wrapped over two rows: double-click a word and type over it, drag over a word and delete it, click where the cursor should go, run it](docs/images/edit.webp)

A long command is text you can work on with the mouse, even when it
wraps over several rows: click to put the cursor anywhere, double-click a
word and type over it, drag to select and delete. From the keyboard,
⌥/Ctrl + arrows jump words and Shift selects (zsh and bash).

### Copy just the last output

![The title bar's copy button copies only the last command's output, then it is pasted back from the right-click menu's Paste history](docs/images/copy.webp)

One click on the copy button takes the last command's output: no prompt,
no command line, nothing from before. Your last copies wait under
**Paste ▸** in the right-click menu.

### Open files and change folders from the output

![Double-click a file name in ls output to open it; right-click for the file menu; double-click a folder to cd into it; History goes back](docs/images/files.webp)

The names in your `ls` output work like icons in Finder on a Mac or in
the GNOME / KDE file manager. Hover a name and it gets an outline:

- **Double-click** opens a file in its app, or `cd`s into a folder (and
  lists it).
- **Right-click** a file to open it with its app (or pick another one),
  a folder to `cd` into it or show it in Finder / Files, and either for
  Rename, Copy, Cut, Paste, Move to Trash and Delete (with the usual
  shortcuts).
- **Drag** a file into another app, or drop files on a window to copy
  them into its folder.
- **History ▸** in the right-click menu `cd`s back to the folders you left.

### Recent: the folders you actually work in

![After cd and ls in Downloads, the recent chip lists only folders where commands were run; typing filters the list and Enter cds there](docs/images/recent.webp)

The **recent** chip at the bottom of every window lists the folders you
did real work in lately (ran a build, git, an editor, a script), most
used first. Just looking around doesn't count: `cd`, `ls`, `pwd` and the
like leave no trace, so the list stays short and useful. Click it (or
⌘3), type a few letters, press Enter, and you're there. Shared by every
gtty window, kept between sessions.

### Chips: folder and git branch

![The git chip's peek switches to another branch; the folder chip jumps to a parent folder](docs/images/chips.webp)

The **folder** chip shows where the window's shell is: click it for any
folder above, or right-click to copy its path or open it in Finder /
Files. The **git** chip shows the branch: hover to see it in full, expand
it to filter the branches and switch with Enter.

### Many windows, one screen

![Four windows side by side; a click on a window in the grid brings it in](docs/images/windows.webp)

Open as many shells and commands as you like. As many windows as fit sit
side by side; the rest wait in the grid on the right, one click away. A
window turns green when its command worked, red with the exit code when it
didn't.

### Type into several terminals at once

![Sync typing: commands typed in one shell run in the two other shells too](docs/images/sync.webp)

Tick **sync** on one window and everything you type there is typed into
every other window on screen as well: the same command on several
machines or folders at once.

### And also

- Readable colors on any theme: unreadable colors are lightened, and
  colors can be turned off per window.
- Emoji and wide characters (CJK) drawn in full; copy gives back exactly
  what was printed.
- Text reflows when you resize.
- Paste history and folder history (`cd` back) in the right-click menu.

More in the [user guide](docs/guide.md).

## What it doesn't do

- No account, no login, no telemetry.
- Your shell stays your shell: bash, zsh or fish, with your own config.
- Programs get a real terminal: ssh, git, build tools and REPLs work as
  usual. Full-screen programs (vim, htop, tmux) aren't fully supported
  yet.

## Source & license

Source and issues: codeberg.org/gttyterm/gtty *(TODO: the repository
doesn't exist yet)*.

Copyright 2026 Sagi Forbes Nagar. gtty is free software, licensed under the
GNU General Public License v3.0 or later — see [LICENSE](LICENSE).
Third-party components: [THIRD_PARTY.md](THIRD_PARTY.md). Contributing:
[CONTRIBUTING.md](CONTRIBUTING.md).

## About

gtty is designed and maintained by Sagi Forbes Nagar. The concept, UX and
architecture are my own; much of the code was written with AI assistance
(Claude) and reviewed, tested and shaped by me.
