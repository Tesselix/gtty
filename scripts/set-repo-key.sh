#!/bin/bash
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The signing key of gtty's apt / rpm repositories (scripts/build-repo.sh,
# release.yml job repo) and of the stable rpms (nfpm): RSA 4096, signing
# only, valid 3 years.
#
#   scripts/set-repo-key.sh            make the key, load it into GitHub
#   scripts/set-repo-key.sh --extend   3 more years for the same key (same
#                                      fingerprint: users keep trusting it)
#   scripts/set-repo-key.sh --upload   load the files into GitHub again
#   scripts/set-repo-key.sh --check    what GitHub has (names, dates) and
#                                      when the key expires
#
# Files, outside the repo in $GTTY_SIGNING_DIR (default $HOME/tmp, next to
# gtty.p12), 0600, never printed:
#   gtty-repo-key.asc   the private key (passphrase-protected)
#   gtty-repo-key.pass  its passphrase
#   gtty-repo-key.rev   revocation certificate (if the key leaks: publish
#                       it in packaging/linux/gtty.asc and the site)
# In the repo: packaging/linux/gtty.asc, the public key (commit it: the
# packages ship it, the site serves it).
# GitHub (tesselix/gtty, GTTY_GITHUB_REPO; the environment "release"
# only): secrets REPO_GPG_KEY, REPO_GPG_PASSPHRASE (stdin only), variable
# REPO_GPG_FINGERPRINT (public).
#
# Needs gpg (brew install gnupg) and gh, logged in. The key is made in a
# temporary GnuPG home, removed at the end: your own keyring isn't touched.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=${GTTY_GITHUB_REPO:-tesselix/gtty}
ENV_NAME=release
DIR=${GTTY_SIGNING_DIR:-$HOME/tmp}
KEY=$DIR/gtty-repo-key.asc
PASS=$DIR/gtty-repo-key.pass
REV=$DIR/gtty-repo-key.rev
PUB=${GTTY_REPO_PUBKEY:-packaging/linux/gtty.asc}
# GTTY_DRY=1 (tests): no GitHub, only says what it would set.
DRY=${GTTY_DRY:-}
UID_NAME="gtty release signing (github.com/tesselix/gtty)"
VALID=3y

fail() {
    echo "set-repo-key: $*" >&2
    exit 1
}

mode=${1:-create}
case $mode in create | --extend | --upload | --check) ;; *) fail "unknown option $mode (--extend, --upload, --check)" ;; esac

command -v gpg >/dev/null || fail "gpg is not installed (brew install gnupg)"
if [ -z "$DRY" ]; then
    command -v gh >/dev/null || fail "gh is not installed (brew install gh)"
    gh auth status >/dev/null 2>&1 || fail "gh is not logged in: run gh auth login"
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill gpg-agent >/dev/null 2>&1 || true; rm -rf "$GNUPGHOME"' EXIT
GPG=(gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$PASS")

fingerprint() {
    gpg --batch --quiet --with-colons --show-keys "$1" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}'
}
# The primary key's expiry, as a date (empty: none).
expiry() {
    local t
    t=$(gpg --batch --quiet --with-colons --show-keys "$1" 2>/dev/null | awk -F: '/^pub/ {print $7; exit}')
    [ -n "$t" ] || { echo never; return; }
    date -r "$t" +%F 2>/dev/null || date -d "@$t" +%F # macOS, GNU
}

upload() {
    local fpr
    fpr=$(fingerprint "$PUB")
    if [ -n "$DRY" ]; then
        echo "dry: would set secrets REPO_GPG_KEY, REPO_GPG_PASSPHRASE and variable REPO_GPG_FINGERPRINT=$fpr in $REPO ($ENV_NAME)"
        return
    fi
    gh secret set REPO_GPG_KEY --env "$ENV_NAME" -R "$REPO" < "$KEY"
    gh secret set REPO_GPG_PASSPHRASE --env "$ENV_NAME" -R "$REPO" < "$PASS"
    gh variable set REPO_GPG_FINGERPRINT --env "$ENV_NAME" -R "$REPO" --body "$fpr"
    echo "set in $REPO, environment $ENV_NAME: secrets REPO_GPG_KEY, REPO_GPG_PASSPHRASE; variable REPO_GPG_FINGERPRINT"
}

export_files() { # fingerprint
    umask 077
    "${GPG[@]}" --armor --export-secret-keys "$1" > "$KEY.new"
    mv "$KEY.new" "$KEY"
    umask 022
    gpg --batch --armor --export "$1" > "$PUB"
}

case $mode in
--check)
    [ -f "$PUB" ] && echo "key: $(fingerprint "$PUB"), expires $(expiry "$PUB") ($PUB)" || echo "no $PUB yet"
    echo "files in $DIR:"
    for f in "$KEY" "$PASS" "$REV"; do
        [ -f "$f" ] && echo "  ${f##*/}  $(date -r "$f" +%F)" || echo "  ${f##*/}  missing"
    done
    [ -n "$DRY" ] && exit 0
    echo "GitHub $REPO, environment $ENV_NAME:"
    gh secret list --env "$ENV_NAME" -R "$REPO" | awk '$1 ~ /^REPO_GPG_/ {print "  secret " $1 "  " $2}'
    gh variable list --env "$ENV_NAME" -R "$REPO" | awk '$1 == "REPO_GPG_FINGERPRINT" {print "  variable " $1 "  " $2}'
    ;;
--upload)
    for f in "$KEY" "$PASS" "$PUB"; do [ -f "$f" ] || fail "$f missing"; done
    upload
    ;;
--extend)
    for f in "$KEY" "$PASS"; do [ -f "$f" ] || fail "$f missing"; done
    "${GPG[@]}" --import "$KEY"
    fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/ {print $10; exit}')
    "${GPG[@]}" --quick-set-expire "$fpr" "$VALID"
    export_files "$fpr"
    echo "key $fpr now expires $(expiry "$PUB")"
    upload
    echo "next: commit $PUB (the packages ship it; apt users get it with the next update)"
    ;;
create)
    [ -e "$KEY" ] && fail "$KEY exists: --extend renews it, --upload loads it again (a new key: move the old files away first)"
    mkdir -p "$DIR"
    umask 077
    head -c 32 /dev/urandom | base64 | tr -d '\n' > "$PASS"
    "${GPG[@]}" --quick-gen-key "$UID_NAME" rsa4096 sign "$VALID"
    fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/ {print $10; exit}')
    cp "$GNUPGHOME/openpgp-revocs.d/$fpr.rev" "$REV"
    umask 022
    export_files "$fpr"
    echo "key $fpr, expires $(expiry "$PUB"); files in $DIR, public key in $PUB"
    upload
    echo "next: commit $PUB; keep $DIR's three gtty-repo-key.* files safe (a backup off this Mac)"
    ;;
esac
