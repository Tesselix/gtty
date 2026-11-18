# gtty, for an AI writing an extension

Read this first, then `AGENTS.md` (every rule and every function of this
SDK) before writing or changing a gtty extension. `AGENTS.md` lists only
what exists: if something isn't there, it doesn't exist, so tell the user
instead of inventing it.

## What gtty is

gtty ("True Graphic Virtual Terminal") is a terminal app for macOS and
Linux that shows many terminals on one screen. Each **window** inside gtty
runs the user's own shell (zsh, bash, fish) with their own config, or one
command. gtty is the terminal, not the shell: users expect it to behave
exactly like a shell in a normal terminal, and ssh, git, build tools and
REPLs run in it as usual.

## What the user sees

- **Windows area:** the current window, full size, and next to it as many
  other windows as fit side by side.
- **Job grid:** a column on the right with every other window as a small
  live picture ("running" above "history"); a click brings one back.
- **Prompt:** two lines at the bottom where gtty commands are typed (`s`
  opens a new shell). The keyboard goes to the current window or to the
  prompt.
- **Status bar:** under the prompt, short notices.
- **A window:** a title bar (actions on the left, the command as title,
  minimize / maximize / × on the right), the terminal text, and at the
  bottom a **footer strip** with the window's **chips**. Its border says its
  state: blue = has the keyboard, gray = running, green = done, red =
  failed.

## Chips: where extensions live

A **chip** is a short text in a window's footer, about that window. gtty's
own chips come first: **folder** (where the shell is), **git** (the
branch), **focus** (folders the user worked in lately), **session** (saved
screens). They open with ⌘1–⌘4 (Linux Ctrl+Shift+1–4). Extension chips
follow them, in every window.

A chip can open, over itself:

- a **peek**: one line with more detail and up to two buttons;
- an **epeek** (expanded peek): a list with an optional title, filter box,
  buttons and status line, driven by the keyboard (↑ ↓ Enter Esc) and the
  mouse;
- a **dialog**: a small form, modal to that window only.

Only one peek or epeek is open on the screen at a time. Your extension
describes these; gtty draws them, in gtty's look, and reports the user's
clicks back to you.

## What an extension is

- **Its own program**, in Zig, Python, JavaScript or Go, that gtty starts
  as a child process and stops when gtty closes. It talks to gtty over a
  socket; the SDK hides that.
- **One process per gtty, serving every window.** Your window-start
  callback runs once per window (the open ones, then each new one); that
  per-window connection is called an **instance**. Keep state by the
  window's id.
- **It learns about a window only through events:** the window's folder,
  git branch and ssh state changing, a command starting (its command line
  and folder), a key pressed, and clicks on your own chip, peek, epeek or
  dialog. Nothing else: it can't read the window's text or output, can't
  type into the shell, can't draw, and can't see other extensions.
- **It can keep files:** per instance (gone with the window) or shared by
  all its instances in every gtty, through the SDK's storage, not the file
  system paths of its own choosing.
- **It logs** to `gtty ext logs`, which is where every mistake shows up:
  gtty doesn't stop for a wrong update, it logs it.
- Installed with `gtty ext install <folder | .zip | .tar.gz>` or gtty ▸
  Extensions…; while developing, run it from the IDE's debugger and it
  connects to the running gtty.

## What makes a good gtty extension

- **Quiet and fast.** The user is working in a terminal: never steal the
  keyboard, never pop things up unasked, return from callbacks at once
  (slow work on your own thread or goroutine). Events wait in a queue and
  gtty drops some when you fall behind.
- **A short chip** (a word or two, a count, a state), details in the peek,
  choices in the epeek. Dim the chip when there's nothing to say, or set no
  text to hide it.
- **The user's click decides.** A peek or dialog you open in answer to a
  click, hover or key gets the keyboard; one you open on your own doesn't.
  Close your epeek after a pick, and close every dialog you handle.
- **Treat what you see as private.** Command lines and keys can hold
  secrets (a password typed into ssh can't always be told apart): don't
  keep, log or send them anywhere they aren't needed.
- **Words the user reads:** "window", never "job window"; "folder", not
  "directory".

## Words

| Word | Meaning |
|---|---|
| window | one terminal inside gtty (the code calls it a job window) |
| windows area | where the current window and those next to it are shown |
| job grid | the column of small windows on the right |
| prompt | gtty's command line at the bottom, not the shell's prompt |
| chip | a short text in a window's footer |
| peek / epeek | the line / the list a chip opens |
| dialog | a small form a chip opens, modal to its window |
| instance | your extension in one window |
| shell prompt | where the window's shell waits for a command |
