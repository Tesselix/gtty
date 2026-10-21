# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue:
[open a private report](https://github.com/gttyterm/gtty/security/advisories/new)
(GitHub's private vulnerability reporting, in the repository's Security
tab).

Say what you found, the gtty version (`gtty --version`) and your system,
and how to reproduce it. You'll get an answer within 7 days. Once a fix
is released, the advisory is published with credit to you (unless you
prefer not to be named).

## Supported versions

Fixes go into the next release of each channel:

| Channel | Versions | Supported |
|---|---|---|
| stable | the latest even minor (`v1.8.x`, …) | yes |
| edge | the latest odd minor (`v1.9.x`, …) | yes |
| older releases | | no: please update |

## What gtty does to stay safe

- Release binaries for macOS are signed with a Developer ID and notarized
  by Apple; every release lists SHA-256 checksums (`SHA256SUMS`).
- CodeQL scans the C code and the CI workflows on every change; the
  OpenSSF Scorecard checks the repository's practices.
- gtty opens no network connections of its own, with two exceptions you
  start yourself: the optional AI prompt talks only to the provider you
  set up, with your own key (stored in the settings file, mode 0600); in
  an ssh window gtty opens a second connection with your own ssh command
  and options (to see the remote folder and files), never with others.
