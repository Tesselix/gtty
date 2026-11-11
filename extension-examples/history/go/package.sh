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
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o build/history/bin/history-macos-aarch64 .
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -o build/history/bin/history-linux-x86_64 .
COPYFILE_DISABLE=1 tar -C build -czf build/history.tar.gz history
echo "build/history  (gtty ext install build/history)"
