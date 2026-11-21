#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
#
# gtty's check run for a Linux machine (works on macOS too): runs the
# scripts in test/linux/ against an installed gtty (or one you built),
# in a scratch world of its own, and packs what it saw into one archive
# to send back: screenshots, a trace of every event and of the bytes sent
# to each job, gtty's own output, and facts about the system.
#
#   git clone https://github.com/Tesselix/gtty && cd gtty
#   scripts/linux-check.sh                  # the gtty on $PATH (the package)
#   scripts/linux-check.sh --gtty zig-out/bin/gtty
#   zig build linux-check                   # builds, then runs it on zig-out
#   gtty --self-test                        # pre-releases carry this suite inside
#
# Options:
#   --gtty PATH     gtty to test (default: `gtty` on $PATH, else zig-out/bin/gtty)
#   --only NAME     run only the tests whose name holds NAME (repeatable)
#   --no-manual     skip the manual step at the end
#   --out DIR       where to put the results (default: ./gtty-check-<host>-<time>)
#
# Keep the mouse off gtty's window while the automatic tests run: the real
# mouse sends its own events. Nothing outside the scratch world is touched,
# except the clipboard. No network.

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
SUITE="$REPO/test/linux"
GTTY=""
ONLY=()
MANUAL=1
OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --gtty) GTTY=$2; shift 2 ;;
        --only) ONLY+=("$2"); shift 2 ;;
        --no-manual) MANUAL=0; shift ;;
        --out) OUT=$2; shift 2 ;;
        -h|--help) sed -n '4,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
    esac
done

if [ -z "$GTTY" ]; then
    GTTY=$(command -v gtty || true)
    [ -z "$GTTY" ] && [ -x "$REPO/zig-out/bin/gtty" ] && GTTY="$REPO/zig-out/bin/gtty"
fi
if [ -z "$GTTY" ] || [ ! -x "$GTTY" ]; then
    echo "no gtty found: install the package, or pass --gtty PATH" >&2
    exit 2
fi
GTTY=$(cd "$(dirname "$GTTY")" && pwd)/$(basename "$GTTY")

HOST=$(hostname -s 2>/dev/null || echo host)
STAMP=$(date +%Y%m%d-%H%M%S)
[ -z "$OUT" ] && OUT="$PWD/gtty-check-$HOST-$STAMP"
mkdir -p "$OUT"/{shots,traces,logs,scripts}
OUT=$(cd "$OUT" && pwd)
REPORT="$OUT/report.txt"
WORLD=$(mktemp -d "${TMPDIR:-/tmp}/gtty-check.XXXXXX")
REAL_HOME=$HOME
trap 'rm -rf "$WORLD"' EXIT

say() { echo "$*" | tee -a "$REPORT"; }
section() { printf '\n== %s\n' "$*" >> "$REPORT"; }
run() { # a command and its output into the report
    printf '$ %s\n' "$*" >> "$REPORT"
    "$@" >> "$REPORT" 2>&1 || printf '(exit %d)\n' "$?" >> "$REPORT"
}
have() { command -v "$1" > /dev/null 2>&1; }

# On macOS the drawn menu bar too, so the screen (and the scripts'
# coordinates) are laid out as on Linux.
case "$(uname -s)" in
    Darwin) MOD=cmd; export GTTY_MENU_BAR=1 ;;
    *) MOD=ctrl+shift ;;
esac
TIMEOUT=""
if have timeout; then TIMEOUT="timeout 180"; elif have gtimeout; then TIMEOUT="gtimeout 180"; fi

# ---------------------------------------------------------------- system

say "gtty check $STAMP on $HOST"
say "gtty: $GTTY"
section "gtty"
run "$GTTY" --version
run ls -l "$GTTY"
have file && run file "$GTTY"
have ldd && run ldd "$GTTY"
have dpkg && run sh -c 'dpkg -S "$1" 2>&1; dpkg -s gtty 2>&1 | head -5' sh "$GTTY"
have rpm && run sh -c 'rpm -qf "$1" 2>&1' sh "$GTTY"
[ -d "$REPO/.git" ] && have git && run git -C "$REPO" log -1 --format='repo: %h %s (%ci)'

section "system"
run uname -a
[ -r /etc/os-release ] && run cat /etc/os-release
have sw_vers && run sw_vers
section "session"
for v in XDG_SESSION_TYPE XDG_CURRENT_DESKTOP DESKTOP_SESSION WAYLAND_DISPLAY DISPLAY \
         XDG_RUNTIME_DIR GDK_SCALE GDK_DPI_SCALE QT_SCALE_FACTOR SDL_VIDEODRIVER \
         SDL_VIDEO_DRIVER LANG LC_ALL LC_CTYPE SHELL TERM; do
    printf '%s=%s\n' "$v" "${!v-<unset>}" >> "$REPORT"
done
have loginctl && [ -n "${XDG_SESSION_ID-}" ] && run loginctl show-session "$XDG_SESSION_ID" -p Type -p Desktop
have xrandr && [ -n "${DISPLAY-}" ] && run sh -c 'xrandr --current | head -5'
have gsettings && run gsettings get org.gnome.desktop.interface scaling-factor
have gsettings && run gsettings get org.gnome.desktop.interface text-scaling-factor
have setxkbmap && [ -n "${DISPLAY-}" ] && run setxkbmap -query
have localectl && run localectl status

section "shells"
for sh in zsh bash fish; do
    if have $sh; then run $sh --version; else echo "$sh: not installed" >> "$REPORT"; fi
done
printf 'login shell: %s\n' "$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f7)" >> "$REPORT"

section "fonts"
if have fc-match; then
    run fc-match monospace
    run fc-match 'emoji:color=true'
    run fc-match 'sans:lang=zh'
fi
for f in /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf \
         /usr/share/fonts/truetype/noto/NotoColorEmoji.ttf \
         /usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc \
         /usr/share/fonts/google-noto-emoji/NotoColorEmoji.ttf \
         /usr/share/fonts/noto/NotoColorEmoji.ttf; do
    [ -e "$f" ] && echo "found $f" >> "$REPORT"
done

section "tools gtty uses"
for t in xdg-open xdg-mime gio gtk-launch gdbus trash-put kioclient6 kioclient5 \
         wl-copy wl-paste xclip xsel curl git vim nvim less htop tmux ssh mosh; do
    printf '%-12s %s\n' "$t" "$(command -v $t || echo -)" >> "$REPORT"
done

# ----------------------------------------------------------------- world

# A scratch home with neutral prompts, a git project with branches, names
# with blanks, a link, so every run looks the same.
H="$WORLD/home"
P="$H/proj"
mkdir -p "$H" "$P/src" "$P/My Dir" "$P/docs" "$H/Downloads" "$WORLD/state"
cat > "$H/.zshrc" <<'EOF'
PROMPT='%1~ %# '
HISTFILE=/dev/null
autoload -Uz compinit && compinit -u
alias ll='ls -l'
EOF
: > "$H/.zshenv"
cat > "$H/.bashrc" <<'EOF'
PS1='\W \$ '
HISTFILE=/dev/null
alias ll='ls -l'
EOF
cp "$H/.bashrc" "$H/.bash_profile"
printf 'one\ntwo\nthree\n' > "$P/notes.txt"
printf '# plan\n' > "$P/My Dir/Big Plan.md"
printf 'fn main() {}\n' > "$P/src/main.zig"
for f in file-alpha.txt file-beta.txt file-gamma.log fig.png 'My File.txt'; do : > "$P/$f"; done
ln -s notes.txt "$P/link-to-notes"
ln -s src "$P/link-to-src"
seq 1 300 > "$P/numbers.txt"
if have git; then
    (cd "$P" && git init -q -b main 2>/dev/null || git init -q
     git -c user.name=check -c user.email=check@example.invalid add -A
     git -c user.name=check -c user.email=check@example.invalid commit -qm init
     git branch feature/login; git branch fix/typo) > /dev/null 2>&1
fi
printf '3\t%s\t%s\n' "$(date +%s)" "$P/src" > "$WORLD/state/focus"
printf '2\t%s\t%s\n' "$(date +%s)" "$P/docs" >> "$WORLD/state/focus"
cp "$REPO/test/keys-read.sh" "$REPO/test/mouse-read.sh" "$P/"
cp "$SUITE"/*.sh "$P/"
cat > "$WORLD/config" <<'EOF'
check-updates = off
quit-on-last-shell = off
prompt-pinned = on
EOF

# ----------------------------------------------------------------- tests

# Each test/linux/*.gt: "# needs: zsh vim" lines skip it when a program is
# missing; @OUT@ (the shots folder), @MOD@ (cmd on macOS, ctrl+shift on
# Linux), @PROJ@, @HOME@ are filled in.
section "tests"
pass=0; fail=0; skipped=0
for gt in "$SUITE"/*.gt; do
    name=$(basename "$gt" .gt)
    if [ ${#ONLY[@]} -gt 0 ]; then
        hit=0; for o in "${ONLY[@]}"; do [[ $name == *"$o"* ]] && hit=1; done
        [ $hit = 0 ] && continue
    fi
    missing=""
    for need in $(sed -n 's/^# needs: //p' "$gt"); do have "$need" || missing="$missing $need"; done
    if [ -n "$missing" ]; then
        say "skip  $name (not installed:$missing)"; skipped=$((skipped + 1)); continue
    fi
    script="$OUT/scripts/$name.gt"
    sed -e "s|@OUT@|$OUT/shots|g" -e "s|@MOD@|$MOD|g" -e "s|@PROJ@|$P|g" -e "s|@HOME@|$H|g" "$gt" > "$script"
    printf '%s ... ' "$name"
    start=$(date +%s)
    (cd "$P" && env HOME="$H" ZDOTDIR="$H" XDG_CACHE_HOME="$REAL_HOME/.cache" \
        XDG_CONFIG_HOME="$WORLD/xdg-config" XDG_STATE_HOME="$WORLD/state" XDG_DATA_HOME="$WORLD/data" \
        GTTY_CONFIG="$WORLD/config" GTTY_FOCUS="$WORLD/state/focus" GTTY_SESSIONS="$WORLD/state/sessions" \
        GTTY_AI_MEMORY="$WORLD/state/ai-memory" GTTY_EXTENSIONS="$WORLD/data/ext" GTTY_LOCKS="$WORLD/state/locks" \
        GTTY_SHOW_DRY=1 GTTY_DRAG_DRY=1 GTTY_ANIM_MS=0 GIT_PAGER=cat PAGER=less \
        GTTY_TRACE="$OUT/traces/$name.txt" \
        $TIMEOUT "$GTTY" --script "$script" > "$OUT/logs/$name.log" 2>&1)
    code=$?
    secs=$(( $(date +%s) - start ))
    if [ $code = 0 ]; then
        echo "ok (${secs}s)"; echo "ok    $name (${secs}s)" >> "$REPORT"; pass=$((pass + 1))
    else
        why="exit $code"; [ $code = 124 ] && why="hung, stopped after 180 s"
        echo "FAILED: $why"; echo "FAIL  $name ($why, ${secs}s)" >> "$REPORT"; fail=$((fail + 1))
    fi
done
say ""
say "$pass ran, $fail failed, $skipped skipped"

# --------------------------------------------------------------- manual

# Real key events (key up, auto-repeat, focus) can't be sent from a
# script: the Tab-completion list that vanished on Linux needs these.
if [ $MANUAL = 1 ] && [ -t 0 ]; then
    cat <<EOF

Manual step (about a minute): a gtty window opens with a zsh shell in the
scratch project, recording every event. In it:
  1. type   ls fi   and press Tab twice: does the list of names stay?
  2. type   cd   (with a space) and press Tab twice
  3. click the gtty prompt at the bottom, type   ls fi   and press Tab
  4. press Alt+B and Alt+F in the shell, hold a letter key down a moment
  5. quit gtty (close its window)
Then answer two questions here.
EOF
    printf 'Start it? [Y/n] '
    read -r ans
    if [ "${ans:-y}" != n ] && [ "${ans:-y}" != N ]; then
        shell=zsh; have zsh || shell=bash
        (cd "$P" && env HOME="$H" ZDOTDIR="$H" XDG_CACHE_HOME="$REAL_HOME/.cache" \
            XDG_CONFIG_HOME="$WORLD/xdg-config" XDG_STATE_HOME="$WORLD/state" XDG_DATA_HOME="$WORLD/data" \
            GTTY_CONFIG="$WORLD/config" GTTY_FOCUS="$WORLD/state/focus" GTTY_SESSIONS="$WORLD/state/sessions" \
            GTTY_TRACE="$OUT/traces/manual.txt" \
            "$GTTY" -c "s $shell" > "$OUT/logs/manual.log" 2>&1)
        section "manual"
        printf 'Did the Tab list stay on screen in the shell window? [y/n/?] '
        read -r a1; echo "tab list stayed (shell window): $a1" >> "$REPORT"
        printf 'Anything else odd? (one line, Enter for none) '
        read -r a2; echo "notes: ${a2:-none}" >> "$REPORT"
    fi
fi

# ----------------------------------------------------------------- pack

# Screenshots as PNG when a converter works (BMPs are 3 MB each); the
# first one that does is kept for the rest.
to_png() { # $1 tool, $2 bmp, $3 png
    case $1 in
        magick) magick "$2" "$3" ;;
        convert) convert "$2" "$3" ;;
        ffmpeg) ffmpeg -loglevel quiet -y -i "$2" "$3" ;;
        sips) sips -s format png "$2" --out "$3" ;;
        python3) python3 -c 'import sys; from PIL import Image; Image.open(sys.argv[1]).save(sys.argv[2])' "$2" "$3" ;;
    esac > /dev/null 2>&1 && [ -s "$3" ]
}
tools=""
for t in sips magick convert ffmpeg python3; do have $t && tools="$tools $t"; done
for b in "$OUT"/shots/*.bmp; do
    [ -e "$b" ] || continue
    for t in $tools; do
        if to_png "$t" "$b" "${b%.bmp}.png"; then rm -f "$b"; tools="$t"; break; fi
        rm -f "${b%.bmp}.png"
    done
done

ARCHIVE="$OUT.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")"
echo
echo "Results: $OUT"
echo "Send this file: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
[ $fail = 0 ]
