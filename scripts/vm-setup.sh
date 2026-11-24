#!/bin/sh
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
# What a Debian / Ubuntu machine (the multipass VM of `make mac-pack`)
# needs to run scripts/package.sh's Linux part: Zig (build.zig.zon's
# minimum_zig_version, from ziglang.org, sha256 from its index.json), nfpm
# (NFPM_VERSION, the GitHub release's .deb, sha256 from its checksums.txt)
# ImageMagick (the launcher icons) and the repository tools (apt-utils,
# createrepo-c, rpm, gpgv; Docker for vm-repo-test is the user's). Run as the user (root can't read a
# multipass mount): sudo for the installs only. Does only what is missing,
# so running it again is cheap.
set -eu
cd "$(dirname "$0")/.."

NFPM_VERSION=${NFPM_VERSION:-2.49.0}
ZIG_VERSION=$(sed -n 's/^ *\.minimum_zig_version = "\(.*\)",.*/\1/p' build.zig.zon)
[ -n "$ZIG_VERSION" ] || { echo "no .minimum_zig_version in build.zig.zon" >&2; exit 1; }
SUDO=; [ "$(id -u)" = 0 ] || SUDO=sudo

case $(uname -m) in
    x86_64) zarch=x86_64 darch=amd64 ;;
    aarch64 | arm64) zarch=aarch64 darch=arm64 ;;
    *) echo "unsupported machine: $(uname -m)" >&2; exit 1 ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

missing=
command -v curl >/dev/null || missing="$missing curl"
command -v xz >/dev/null || missing="$missing xz-utils"
command -v magick >/dev/null || command -v convert >/dev/null || missing="$missing imagemagick"
command -v file >/dev/null || missing="$missing file"
command -v make >/dev/null || missing="$missing make"
# scripts/build-repo.sh / test-repo.sh (vm-repo-test)
command -v apt-ftparchive >/dev/null || missing="$missing apt-utils"
command -v createrepo_c >/dev/null || missing="$missing createrepo-c"
command -v rpmkeys >/dev/null || missing="$missing rpm"
command -v gpgv >/dev/null || missing="$missing gpgv"
if [ -n "$missing" ]; then
    echo "== apt:$missing"
    $SUDO apt-get update -q
    # shellcheck disable=SC2086 # one word per package
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q $missing
fi

if [ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]; then
    echo "== zig $ZIG_VERSION"
    # The tarball's sha256 from ziglang.org's index (python3: every Ubuntu has it).
    curl -fsSL https://ziglang.org/download/index.json -o "$TMP/index.json"
    set -- $(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]]; print(d["tarball"], d["shasum"])' \
        "$TMP/index.json" "$ZIG_VERSION" "$zarch-linux")
    curl -fL --progress-bar "$1" -o "$TMP/zig.tar.xz"
    echo "$2  $TMP/zig.tar.xz" | sha256sum -c --quiet
    $SUDO rm -rf "/usr/local/lib/zig-$ZIG_VERSION"
    $SUDO mkdir -p "/usr/local/lib/zig-$ZIG_VERSION"
    $SUDO tar -C "/usr/local/lib/zig-$ZIG_VERSION" --strip-components=1 -xJf "$TMP/zig.tar.xz"
    $SUDO ln -sf "/usr/local/lib/zig-$ZIG_VERSION/zig" /usr/local/bin/zig
fi

if ! nfpm --version 2>/dev/null | grep -qE "^GitVersion: *v?$NFPM_VERSION\$"; then
    echo "== nfpm $NFPM_VERSION"
    base=https://github.com/goreleaser/nfpm/releases/download/v$NFPM_VERSION
    deb=nfpm_${NFPM_VERSION}_$darch.deb
    curl -fsSL "$base/checksums.txt" -o "$TMP/checksums.txt"
    curl -fL --progress-bar "$base/$deb" -o "$TMP/$deb"
    (cd "$TMP" && grep " $deb\$" checksums.txt | sha256sum -c --quiet)
    $SUDO dpkg -i "$TMP/$deb"
fi

echo "zig $(zig version), nfpm $(nfpm --version 2>/dev/null | sed -n 's/^GitVersion: *//p')"
