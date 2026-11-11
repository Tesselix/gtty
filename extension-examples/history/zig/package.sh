#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# The package, in build/history/ (and build/history.tar.gz): manifest and
# the program for each platform it names.
set -eu
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/history/bin
cp manifest.json build/history/
cp ../../../LICENSE build/history/
for t in aarch64-macos:macos-aarch64 x86_64-linux-gnu:linux-x86_64; do
    zig build -Dtarget="${t%%:*}" -Doptimize=ReleaseSafe --prefix "build/zig-${t#*:}"
    cp "build/zig-${t#*:}/bin/history" "build/history/bin/history-${t#*:}"
done
rm -rf build/zig-*
COPYFILE_DISABLE=1 tar -C build -czf build/history.tar.gz history
echo "build/history  (gtty ext install build/history)"
