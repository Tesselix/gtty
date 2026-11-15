#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# The package, one file: build/<name>-<version>.tar.gz (name and version
# from manifest.json) with the manifest and the program for each platform
# it names (macOS arm64, Linux x86_64).
set -eu
cd "$(dirname "$0")"
NAME=$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' manifest.json)
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' manifest.json)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$NAME"
mkdir -p "$PKG"
mkdir -p "$PKG/bin"
cp manifest.json ../../../LICENSE "$PKG/"
for t in aarch64-macos:macos-aarch64 x86_64-linux-gnu:linux-x86_64; do
    zig build -Dtarget="${t%%:*}" -Doptimize=ReleaseSafe --prefix "$STAGE/zig-${t#*:}"
    cp "$STAGE/zig-${t#*:}/bin/commands" "$PKG/bin/commands-${t#*:}"
done
rm -rf build && mkdir -p build
OUT="build/$NAME-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$OUT" "$NAME"
echo "$OUT  (gtty ext install $OUT, or Install… in gtty ▸ Extensions…)"
