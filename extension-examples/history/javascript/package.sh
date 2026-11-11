#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# The package, in build/history/ (and build/history.tar.gz): manifest,
# history.js and the SDK's gtty.js (GTTY_SDK: another SDK folder, such as
# an unpacked gtty-sdk-javascript-<v>.tar.gz).
set -eu
cd "$(dirname "$0")"
SDK=${GTTY_SDK:-../../../sdks/javascript}
rm -rf build && mkdir -p build/history
cp manifest.json history.js "$SDK/gtty.js" build/history/
cp ../../../LICENSE build/history/ 2>/dev/null || cp "$SDK/LICENSE" build/history/
COPYFILE_DISABLE=1 tar -C build -czf build/history.tar.gz history
echo "build/history  (gtty ext install build/history)"
