#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# The SDKs extensions import, into dist/: gtty-sdk-<language>-<v>.tar.gz
# for each folder in sdks/, with the LICENSE and, where the language
# has one (Zig's build.zig.zon), the version written in. The version as
# in package.sh (which runs this): build.zig.zon's, or GTTY_VERSION.
set -eu
cd "$(dirname "$0")/.."

VERSION=${GTTY_VERSION:-$(sed -n 's/^ *\.version = "\(.*\)",.*/\1/p' build.zig.zon)}
[ -n "$VERSION" ] || { echo "no .version in build.zig.zon" >&2; exit 1; }

STAGE=.zig-cache/package-sdks
rm -rf "$STAGE" && mkdir -p "$STAGE" dist
export COPYFILE_DISABLE=1 # no ._ files from macOS tar

for dir in sdks/*/; do
    lang=$(basename "$dir")
    name="gtty-sdk-$lang-$VERSION"
    mkdir "$STAGE/$name"
    tar -C "$dir" --exclude .zig-cache --exclude zig-out --exclude zig-pkg -cf - . | tar -C "$STAGE/$name" -xf -
    cp LICENSE "$STAGE/$name/"
    zon="$STAGE/$name/build.zig.zon"
    if [ -f "$zon" ]; then
        sed "s/^\( *\.version = \)\"[^\"]*\"/\1\"$VERSION\"/" "$zon" > "$zon.new"
        mv "$zon.new" "$zon"
        grep -q "^ *\.version = \"$VERSION\"," "$zon" || { echo "could not set the version in $zon" >&2; exit 1; }
    fi
    tar -C "$STAGE" -czf "dist/$name.tar.gz" "$name"
    echo "dist/$name.tar.gz"
done
