#!/bin/bash
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The apt and rpm repositories served at https://tesselix.github.io/gtty/
# (GitHub Pages; release.yml, job repo), built from scratch from a folder
# of packages: every gtty-<v>-{amd64,arm64}.deb and
# gtty-<v>-{x86_64,aarch64}.rpm in it.
#
#   scripts/build-repo.sh <packages folder> <site folder>
#
# Site layout:
#   gtty.asc                    the public key (apt Signed-By, rpm gpgkey)
#   apt/dists/stable/InRelease  (+ Release, Release.gpg) signed index
#   apt/dists/stable/main/binary-{amd64,arm64}/Packages(.gz)
#   apt/pool/main/g/gtty/*.deb
#   rpm/*.rpm, rpm/repodata/ (+ repomd.xml.asc), rpm/gtty.repo
#   index.html, .nojekyll
#
# Signing: the key in $GNUPGHOME whose fingerprint is REPO_GPG_FINGERPRINT,
# passphrase in the file REPO_GPG_PASSPHRASE_FILE (none: no passphrase).
# The rpms must already be signed with it (nfpm, package.sh): checked here.
#
# Needs apt-ftparchive (apt-utils), createrepo_c (createrepo-c), rpm,
# gpg, gpgv. SITE_URL: the address the site is served at (default the
# Pages one; local tests use http://…).
set -euo pipefail

[ $# = 2 ] || { echo "usage: $0 <packages folder> <site folder>" >&2; exit 2; }
PKGS=$(cd "$1" && pwd)
SITE=$2
: "${REPO_GPG_FINGERPRINT:?fingerprint of the signing key}"
SITE_URL=${SITE_URL:-https://tesselix.github.io/gtty}

for t in apt-ftparchive createrepo_c rpm gpg gpgv; do
    command -v "$t" >/dev/null || { echo "$t missing (apt install apt-utils createrepo-c rpm gnupg gpgv)" >&2; exit 1; }
done

GPG=(gpg --batch --yes --local-user "$REPO_GPG_FINGERPRINT")
if [ -n "${REPO_GPG_PASSPHRASE_FILE:-}" ]; then
    GPG+=(--pinentry-mode loopback --passphrase-file "$REPO_GPG_PASSPHRASE_FILE")
fi

shopt -s nullglob
debs=("$PKGS"/gtty-*-amd64.deb "$PKGS"/gtty-*-arm64.deb)
rpms=("$PKGS"/gtty-*-x86_64.rpm "$PKGS"/gtty-*-aarch64.rpm)
[ ${#debs[@]} -gt 0 ] && [ ${#rpms[@]} -gt 0 ] || { echo "no packages in $PKGS" >&2; exit 1; }

rm -rf "$SITE"
mkdir -p "$SITE/apt/pool/main/g/gtty" "$SITE/rpm"
SITE=$(cd "$SITE" && pwd)

# The public key, and a keyring to check against.
gpg --batch --armor --export "$REPO_GPG_FINGERPRINT" > "$SITE/gtty.asc"
[ -s "$SITE/gtty.asc" ] || { echo "key $REPO_GPG_FINGERPRINT not in the keyring" >&2; exit 1; }
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
gpg --batch --dearmor < "$SITE/gtty.asc" > "$CHECK/keyring.gpg"

# ---- rpm --------------------------------------------------------------------
echo "== rpm"
RPMDB=$CHECK/rpmdb
mkdir -p "$RPMDB"
rpmkeys --dbpath "$RPMDB" --import "$SITE/gtty.asc"
for f in "${rpms[@]}"; do
    # Signed by this key: "… digests signatures OK". An unsigned rpm passes
    # with "digests OK", another key's fails (NOKEY).
    out=$(rpmkeys --dbpath "$RPMDB" --checksig "$f" 2>&1) || true
    case $out in
        *" signatures OK") ;;
        *) echo "$out" >&2; echo "$(basename "$f"): not signed with the repository key" >&2; exit 1 ;;
    esac
    cp "$f" "$SITE/rpm/"
done
createrepo_c --quiet --general-compress-type=gz "$SITE/rpm"
"${GPG[@]}" --armor --detach-sign -o "$SITE/rpm/repodata/repomd.xml.asc" "$SITE/rpm/repodata/repomd.xml"
cat > "$SITE/rpm/gtty.repo" <<EOF
[gtty]
name=gtty
baseurl=$SITE_URL/rpm
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$SITE_URL/gtty.asc
EOF

# ---- apt --------------------------------------------------------------------
echo "== apt"
for f in "${debs[@]}"; do cp "$f" "$SITE/apt/pool/main/g/gtty/"; done
cd "$SITE/apt"
# One index of every .deb, split by each entry's Architecture field
# (apt-ftparchive --arch goes by file names, *_arm64.deb, and gtty's are
# gtty-<v>-arm64.deb).
apt-ftparchive packages pool > "$CHECK/Packages"
for a in amd64 arm64; do
    d=dists/stable/main/binary-$a
    mkdir -p "$d"
    awk -v a="$a" 'BEGIN {RS = ""; ORS = "\n\n"} $0 ~ "\nArchitecture: " a "\n" {print}' "$CHECK/Packages" > "$d/Packages"
    [ -s "$d/Packages" ] || { echo "no $a package in the apt index" >&2; exit 1; }
    gzip -9kn "$d/Packages"
done
apt-ftparchive \
    -o APT::FTPArchive::Release::Origin=gtty \
    -o APT::FTPArchive::Release::Label=gtty \
    -o APT::FTPArchive::Release::Suite=stable \
    -o APT::FTPArchive::Release::Codename=stable \
    -o APT::FTPArchive::Release::Architectures="amd64 arm64" \
    -o APT::FTPArchive::Release::Components=main \
    -o APT::FTPArchive::Release::Description="gtty, stable releases" \
    release dists/stable > "$CHECK/Release"
mv "$CHECK/Release" dists/stable/Release
"${GPG[@]}" --clearsign -o dists/stable/InRelease dists/stable/Release
"${GPG[@]}" --armor --detach-sign -o dists/stable/Release.gpg dists/stable/Release
gpgv --keyring "$CHECK/keyring.gpg" dists/stable/InRelease 2>/dev/null
gpgv --keyring "$CHECK/keyring.gpg" dists/stable/Release.gpg dists/stable/Release 2>/dev/null
cd "$SITE"

# ---- the page ---------------------------------------------------------------
versions=$(for f in "${debs[@]}" "${rpms[@]}"; do basename "$f"; done |
    sed -n 's/^gtty-\([0-9][0-9.]*\)-.*/\1/p' | sort -t. -k1,1nr -k2,2nr -k3,3nr | uniq | tr '\n' ' ')
cat > index.html <<EOF
<!doctype html>
<meta charset="utf-8">
<title>gtty package repositories</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:46em;margin:2em auto;padding:0 1em}pre{background:#f4f4f4;padding:.8em;overflow-x:auto}</style>
<h1>gtty package repositories</h1>
<p>apt and rpm repositories for <a href="https://github.com/tesselix/gtty">gtty</a>'s stable releases
(here: ${versions% }). How to add them: the
<a href="https://github.com/tesselix/gtty#linux">README</a>.</p>
<p>Signing key: <a href="gtty.asc">gtty.asc</a>, fingerprint <code>$REPO_GPG_FINGERPRINT</code>.</p>
<ul><li>apt: <code>$SITE_URL/apt</code>, suite <code>stable</code>, component <code>main</code></li>
<li>rpm: <code>$SITE_URL/rpm</code>, <a href="rpm/gtty.repo">gtty.repo</a></li></ul>
EOF
touch .nojekyll

echo "== $SITE: ${#debs[@]} deb, ${#rpms[@]} rpm; versions ${versions% }"
