#!/bin/bash
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The apt / rpm repositories end to end, on a Linux machine with Docker
# (`make vm-repo-test` runs it in the multipass VM): a throwaway key (made
# here, deleted after), the packages of bin/linux* (SKIP_BUILD) as
# GTTY_VERSION and as the next patch version, signed rpms, the site
# (scripts/build-repo.sh) served on 127.0.0.1:$PORT. In each container
# (CLIENTS) the README's setup lines, `install gtty` (the first version
# only on the site), then the next version published and gtty upgraded as
# the update line says. Only this machine's architecture is tested. Not
# RHEL / Rocky 8: its glibc is 2.28, gtty needs 2.31.
#
# Needs: docker, python3, and build-repo.sh's tools (apt-utils, createrepo-c,
# rpm, gnupg). Work folder: REPO_TEST_DIR (default ~/gtty-repo-test).
set -euo pipefail
cd "$(dirname "$0")/.."

V1=${GTTY_VERSION:?GTTY_VERSION: the version to package}
V2=${V1%.*}.$((${V1##*.} + 1))
PORT=${PORT:-8765}
URL=http://127.0.0.1:$PORT
W=${REPO_TEST_DIR:-$HOME/gtty-repo-test}
CLIENTS=${CLIENTS:-debian:12 ubuntu:20.04 ubuntu:24.04 fedora:latest rockylinux/rockylinux:9 opensuse/leap:15}

rm -rf "$W"
mkdir -p "$W/gnupg" "$W/www"
chmod 700 "$W/gnupg"
export GNUPGHOME=$W/gnupg
containers=()
server=
cleanup() {
    [ -n "$server" ] && kill "$server" 2>/dev/null || true
    [ ${#containers[@]} -gt 0 ] && docker rm -f "${containers[@]}" >/dev/null 2>&1 || true
    gpgconf --kill gpg-agent 2>/dev/null || true
    rm -rf "$W/gnupg" "$W/secret.asc" "$W/pass"
}
trap cleanup EXIT

echo "== throwaway key"
head -c 24 /dev/urandom | base64 > "$W/pass"
gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$W/pass" \
    --quick-gen-key "gtty repository TEST key (throwaway)" rsa4096 sign 1d
FPR=$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr/ {print $10; exit}')
gpg --batch --armor --export "$FPR" > "$W/pub.asc"
gpg --batch --armor --pinentry-mode loopback --passphrase-file "$W/pass" \
    --export-secret-keys "$FPR" > "$W/secret.asc"
export REPO_GPG_FINGERPRINT=$FPR REPO_GPG_PASSPHRASE_FILE=$W/pass SITE_URL=$URL

for v in "$V1" "$V2"; do
    echo "== packages $v"
    GTTY_VERSION=$v SKIP_BUILD=1 GTTY_DIST="$W/pkgs-$v" GTTY_REPO_PUBKEY="$W/pub.asc" \
        NFPM_RPM_KEY_FILE="$W/secret.asc" NFPM_RPM_PASSPHRASE=$(cat "$W/pass") \
        scripts/package.sh >"$W/package-$v.log" 2>&1 || { tail -20 "$W/package-$v.log"; exit 1; }
done
mkdir -p "$W/only1" "$W/both"
cp "$W/pkgs-$V1"/*.deb "$W/pkgs-$V1"/*.rpm "$W/only1/"
cp "$W/only1"/* "$W/pkgs-$V2"/*.deb "$W/pkgs-$V2"/*.rpm "$W/both/"

echo "== site with $V1"
scripts/build-repo.sh "$W/only1" "$W/www/site"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$W/www/site" >"$W/http.log" 2>&1 &
server=$!
sleep 1
curl -fsS "$URL/apt/dists/stable/InRelease" >/dev/null

# The README's lines, as root (no sudo in the containers), without
# recommends (speed); then the update line's command.
apt_setup='set -e
apt-get update -qq && apt-get install -y -qq --no-install-recommends curl ca-certificates >/dev/null
curl -fsSLo /usr/share/keyrings/gtty.asc URL/gtty.asc
cat > /etc/apt/sources.list.d/gtty.sources <<EOF
Types: deb
URIs: URL/apt
Suites: stable
Components: main
Signed-By: /usr/share/keyrings/gtty.asc
EOF
apt-get update -qq && apt-get install -y -qq --no-install-recommends gtty >/dev/null'
apt_update='set -e; apt-get update -qq && apt-get install -y -qq --no-install-recommends gtty >/dev/null'
dnf_setup='set -e
curl -fsSLo /etc/yum.repos.d/gtty.repo URL/rpm/gtty.repo
dnf install -y -q --setopt=install_weak_deps=False gtty'
dnf_update='set -e; dnf upgrade -y -q --refresh gtty'
# The image's own repositories off first: one of their mirrors hung for
# an hour (seen), and gtty needs nothing from them.
zypper_setup='set -e
zypper -n -q modifyrepo --disable --all
zypper -n -q addrepo URL/rpm/gtty.repo
zypper -n -q --gpg-auto-import-keys refresh
zypper -n -q install --no-recommends gtty'
zypper_update='set -e; zypper -n -q refresh gtty && zypper -n -q update --no-recommends gtty'

kind() {
    case $1 in
        debian* | ubuntu*) echo apt ;;
        opensuse*) echo zypper ;;
        *) echo dnf ;;
    esac
}
version_of() { # container
    docker exec "$1" sh -c 'dpkg-query -W -f "\${Version}" gtty 2>/dev/null || rpm -q --qf "%{VERSION}" gtty'
}
run() { # container script
    docker exec "$1" sh -c "${2//URL/$URL}" >"$W/$1.log" 2>&1
}

declare -A result
for img in $CLIENTS; do
    name=gtty-repo-test-$(echo "$img" | tr -c 'a-z0-9\n' -)
    echo "== $img: setup + install"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network host "$img" sleep 3600 >/dev/null
    containers+=("$name")
    k=$(kind "$img")
    setup=${k}_setup
    if run "$name" "${!setup}" && [ "$(version_of "$name")" = "$V1" ] &&
        docker exec "$name" gtty --version >/dev/null; then
        result[$img]="installed $V1"
    else
        result[$img]="FAILED install (see $W/$name.log)"
        tail -15 "$W/$name.log"
    fi
done

echo "== site with $V1 + $V2"
scripts/build-repo.sh "$W/both" "$W/www/site"
for img in $CLIENTS; do
    name=gtty-repo-test-$(echo "$img" | tr -c 'a-z0-9\n' -)
    case ${result[$img]} in FAILED*) continue ;; esac
    echo "== $img: update"
    k=$(kind "$img")
    update=${k}_update
    if run "$name" "${!update}" && [ "$(version_of "$name")" = "$V2" ]; then
        result[$img]="installed $V1, updated to $V2"
        if [ "$k" = apt ]; then
            docker exec "$name" cmp -s /usr/share/gtty/gtty.asc /usr/share/keyrings/gtty.asc ||
                result[$img]="${result[$img]}; FAILED: keyring differs from the shipped key"
        fi
    else
        result[$img]="FAILED update (see $W/$name.log)"
        tail -15 "$W/$name.log"
    fi
done

echo
echo "== results ($(uname -m))"
fail=0
for img in $CLIENTS; do
    printf '  %-28s %s\n' "$img" "${result[$img]}"
    case ${result[$img]} in *FAILED*) fail=1 ;; esac
done
exit $fail
