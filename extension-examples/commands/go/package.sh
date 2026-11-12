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
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "$PKG/bin/commands-macos-aarch64" .
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o "$PKG/bin/commands-linux-x86_64" .
rm -rf build && mkdir -p build
OUT="build/$NAME-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$OUT" "$NAME"
echo "$OUT  (gtty ext install $OUT, or Install… in gtty ▸ Extensions…)"
