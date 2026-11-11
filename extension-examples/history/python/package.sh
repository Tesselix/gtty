#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# The package, in build/history/ (and build/history.tar.gz): manifest,
# history.py and the SDK's gtty.py (GTTY_SDK: another SDK folder, such as
# an unpacked gtty-sdk-python-<v>.tar.gz).
set -eu
cd "$(dirname "$0")"
SDK=${GTTY_SDK:-../../../sdks/python}
rm -rf build && mkdir -p build/history
cp manifest.json history.py "$SDK/gtty.py" build/history/
cp ../../../LICENSE build/history/ 2>/dev/null || cp "$SDK/LICENSE" build/history/
COPYFILE_DISABLE=1 tar -C build -czf build/history.tar.gz history
echo "build/history  (gtty ext install build/history)"
