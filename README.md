# gtty — True Graphic Virtual Terminal

[![Stable release](https://img.shields.io/github/v/release/Tesselix/gtty?sort=semver&label=stable&color=2ea44f)](https://github.com/Tesselix/gtty/releases/latest)
[![Edge release](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2FTesselix%2Fgtty%2Fbadges%2Fedge.json)](https://github.com/Tesselix/gtty/releases)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Tesselix/gtty/badge)](https://scorecard.dev/viewer/?uri=github.com/Tesselix/gtty)

A multi-window terminal: all your shells and commands on one screen, side
by side or one click away.

![A shell opened from the gtty prompt, two more from the right-click menu's New Shell; one is minimized into the job grid and clicked back; the last output (five lines of git log) is copied from a title bar and pasted into another shell as an echo; with sync typing on, one ls runs in all three](docs/images/hero.webp)

## Install

### macOS

Apple Silicon, macOS 13 or later. With [Homebrew](https://brew.sh):

```sh
brew install --cask tesselix/tap/gtty
```

`brew upgrade` updates it.

### Linux

x86_64 or arm64 (aarch64), glibc 2.31 or later. Add gtty's package
repository once; your package manager then installs gtty and keeps it up
to date with the rest of the system. The repositories carry the stable
releases, signed with gtty's key.

Debian / Ubuntu:

```sh
sudo curl -fsSLo /usr/share/keyrings/gtty.asc https://tesselix.github.io/gtty/gtty.asc
sudo tee /etc/apt/sources.list.d/gtty.sources >/dev/null <<'EOF'
Types: deb
URIs: https://tesselix.github.io/gtty/apt
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/gtty.asc
EOF
sudo apt update && sudo apt install gtty
```

Fedora / RHEL 9 or later:

```sh
sudo curl -fsSLo /etc/yum.repos.d/gtty.repo https://tesselix.github.io/gtty/rpm/gtty.repo
sudo dnf install gtty
```

openSUSE:

```sh
sudo zypper addrepo https://tesselix.github.io/gtty/rpm/gtty.repo
sudo zypper refresh && sudo zypper install gtty
```

After that, gtty updates with the rest of your system: `sudo apt upgrade`,
`sudo dnf upgrade` or `sudo zypper update` (gtty's update line shows the
command too).

dnf and zypper ask you once to trust gtty's signing key. Its fingerprint
must be:

```text
17EA C2FE C529 6DED 5304  74D8 4044 11AA 0E72 B09F
```

It is also on [tesselix.github.io/gtty](https://tesselix.github.io/gtty/).

### More installation methods

Straight from GitHub, without Homebrew or the repositories. These don't
update by themselves: run the same again for a new release.

**macOS**, the latest stable release:

```sh
curl -fLO https://github.com/Tesselix/gtty/releases/latest/download/gtty-macos.dmg && open gtty-macos.dmg
```

1. In the window that opens, drag the **gtty** icon onto the
   **Applications** folder.
2. Eject the disk image (the ⏏ next to "gtty" in Finder's sidebar). You
   can delete `gtty-macos.dmg`.
3. Open gtty from Applications (or Spotlight: ⌘Space, type `gtty`). The
   first time, macOS may ask whether to open an app downloaded from the
   internet: click **Open**. gtty is signed and notarized by Apple.
4. If macOS still won't open it, go to **System Settings → Privacy &
   Security**, scroll down to the message about gtty and click **Open
   Anyway**.

To update, do the same again and let Finder replace the old copy.

**Linux**, the latest stable release in one line (it picks your machine's
package):

```sh
# Debian / Ubuntu
a=$(dpkg --print-architecture) && curl -fLO https://github.com/tesselix/gtty/releases/latest/download/gtty-$a.deb && sudo apt install ./gtty-$a.deb
# Fedora / RHEL (openSUSE: zypper install, other rpm systems: rpm -U)
sudo dnf install https://github.com/tesselix/gtty/releases/latest/download/gtty-$(uname -m).rpm
```

**From the release page**: download from the
**[latest release](https://github.com/Tesselix/gtty/releases/latest)**
(each release lists its files and a `SHA256SUMS`):

- **macOS** (Apple Silicon, 13+): `gtty-<version>-macos.dmg`; open it and
  drag gtty to Applications.
- **Debian / Ubuntu**: `gtty-<version>-amd64.deb` (x86_64) or
  `gtty-<version>-arm64.deb`, then `sudo apt install ./gtty-*.deb`
- **Fedora / RHEL / openSUSE**: `gtty-<version>-x86_64.rpm` or
  `gtty-<version>-aarch64.rpm` (arm64), then `sudo dnf install ./gtty-*.rpm`
  (openSUSE: `sudo zypper install …`)
- **Other Linux:** `gtty-<version>-linux-x86_64.tar.gz` or
  `gtty-<version>-linux-aarch64.tar.gz`, then `./install.sh` inside it.
- **From source:** see [HACKING.md](HACKING.md) (Zig 0.16 + SDL3).

To check a download: `shasum -a 256 -c SHA256SUMS --ignore-missing`
(Linux: `sha256sum -c SHA256SUMS --ignore-missing`).

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

### Find where a variable or alias was set

![Env & Aliases from the right-click menu: EDITOR set in .zshrc over .zshenv; PATH's history through .zshrc, .zprofile and /etc/zprofile, where it was first set; the alias ll from .aliases over .zshrc](docs/images/env.webp)

Right-click a zsh or bash window and pick **Env & Aliases…**: every
environment variable and alias, its value, and the full path of the file
and line that set it. Type to filter by name or value. A ▸ opens a key's
history: each earlier value and the script that set it, down to the
first one. A value counts as inherited only when no file explains it.
Double-click a value to change it for that shell only, right-click a row
to unset or copy it, double-click the source file to open it at that
line in your editor.
gtty reads your startup files in the order your shell runs
them, on macOS and the usual Linux distributions; nothing is run.

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

### Focus: the folders you actually work in

![After cd and ls in Downloads, the focus chip lists only folders where commands were run; typing filters the list and Enter cds there](docs/images/focus.webp)

The **focus** chip at the bottom of every window lists the folders you
did real work in lately (ran a build, git, an editor, a script): the
last seven at most, the newest at the bottom, right above the chip. Just looking around doesn't count: `cd`, `ls`, `pwd` and the
like leave no trace, so the list stays short and useful. Click it (or
⌘3), type a few letters, press Enter, and you're there. Shared by every
gtty window, kept between sessions.

### Sessions: save your screen, bring it back

![Three shells in shop, api and blog run pwd; the session chip's save button saves them; all closed, one fresh shell; the session chip's list brings the three back in their folders and places, and pwd says so](docs/images/sessions.webp)

The **session** chip's **save** button saves the shells on your screen:
each one's folder, where it sat, and for an ssh window the connection and the
folder on the other side. Later, pick the session from the **session**
chip (or ⌘4) and they're all back at once: the
same shells in the same folders, side by side as before; an ssh window
connects again (a password is still yours to type) and goes back to its
folder. Its **manage** button shows each saved
session as a picture of its screen. Sessions are shared by every gtty
on the machine.

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

More in the [user guide](docs/guide.md). Extensions (chips of your own,
in Zig, Python, JavaScript or Go): see the
[developer guide](docs/extensions.md).

## What it doesn't do

- No account, no login, no telemetry.
- Your shell stays your shell, with your own config. zsh and bash get
  the full set (last-output copy, folder history, Env & Aliases, …);
  fish and other shells run as plain shells, without those.
- Programs get a real terminal: ssh, git, build tools, REPLs and
  full-screen programs (vim, less) work as usual, the mouse included
  (hold Shift to select text yourself).

## Source & license

Source and issues: [github.com/Tesselix/gtty](https://github.com/Tesselix/gtty)
([report an issue](https://github.com/Tesselix/gtty/issues)).

Copyright 2026 Sagi Forbes Nagar. gtty is free software, licensed under the
GNU General Public License v3.0 or later — see [LICENSE](LICENSE).
Third-party components: [THIRD_PARTY.md](THIRD_PARTY.md). Contributing:
[CONTRIBUTING.md](CONTRIBUTING.md).

## About

gtty is designed and maintained by Sagi Forbes Nagar. The concept, UX and
architecture are my own; much of the code was written with AI assistance
(Claude) and reviewed, tested and shaped by me.
