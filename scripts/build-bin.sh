#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# Build self-contained release binaries into bin/macos/gtty and
# bin/linux/gtty + bin/linux-arm64/gtty (from macOS or Linux; Zig
# cross-compiles; on Linux only the Linux ones: no macOS SDK there).
#
# SDL3, SDL3_ttf and freetype are compiled from source and linked in
# (-Dbundled-sdl), so nothing needs installing on the machine that runs them:
# - macOS: Apple system frameworks only (arm64; MACOS_TARGET to change).
# - Linux: glibc 2.31+ only, x86_64 and arm64 (LINUX_TARGET /
#   LINUX_ARM_TARGET to change). SDL picks up X11 / Wayland, GL / Vulkan
#   and audio from the desktop at run time.
# The version gtty reports is build.zig.zon's .version (releases write
# the tag's there first), or GTTY_VERSION when set (`make mac-pack`).
set -eu
cd "$(dirname "$0")/.."

MACOS_TARGET=${MACOS_TARGET:-aarch64-macos.13.0}
MACOS_SDK=${MACOS_SDK:-$(xcrun --show-sdk-path 2>/dev/null || true)}
LINUX_TARGET=${LINUX_TARGET:-x86_64-linux-gnu.2.31}
LINUX_ARM_TARGET=${LINUX_ARM_TARGET:-aarch64-linux-gnu.2.31}
WORK=.zig-cache/bin
mkdir -p bin/linux bin/linux-arm64

build() { # build <target> <out folder> [zig build options]
    echo "== $1"
    t=$1 out=$2; shift 2
    zig build -Dbundled-sdl -Dstrip -Doptimize=ReleaseSafe -Dtarget="$t" --prefix "$WORK/$out" \
        ${GTTY_VERSION:+-Dversion="$GTTY_VERSION"} "$@"
    cp "$WORK/$out/bin/gtty" "bin/$out/gtty"
}
if [ "$(uname)" = Darwin ]; then
    [ -n "$MACOS_SDK" ] || { echo "macOS SDK not found: install Xcode command line tools or set MACOS_SDK" >&2; exit 1; }
    mkdir -p bin/macos
    build "$MACOS_TARGET" macos -Dmacos-sdk="$MACOS_SDK"
    file bin/macos/gtty
fi
build "$LINUX_TARGET" linux
build "$LINUX_ARM_TARGET" linux-arm64

file bin/linux/gtty bin/linux-arm64/gtty
