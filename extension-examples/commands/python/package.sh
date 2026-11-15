#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# The package, one file: build/<name>-<version>.tar.gz (name and version
# from manifest.json) with the manifest, commands.py and the SDK's
# gtty.py. GTTY_SDK: another SDK folder, such as an unpacked
# gtty-sdk-python-<v>.tar.gz.
set -eu
cd "$(dirname "$0")"
NAME=$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' manifest.json)
VERSION=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' manifest.json)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/$NAME"
mkdir -p "$PKG"
SDK=${GTTY_SDK:-../../../sdks/python}
cp manifest.json commands.py "$SDK/gtty.py" "$PKG/"
cp ../../../LICENSE "$PKG/" 2>/dev/null || cp "$SDK/LICENSE" "$PKG/"
rm -rf build && mkdir -p build
OUT="build/$NAME-$VERSION.tar.gz"
COPYFILE_DISABLE=1 tar -C "$STAGE" -czf "$OUT" "$NAME"
echo "$OUT  (gtty ext install $OUT, or Install… in gtty ▸ Extensions…)"
