# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue:
[open a private report](https://github.com/Tesselix/gtty/security/advisories/new)
(GitHub's private vulnerability reporting, in the repository's Security
tab).

Say what you found, the gtty version (`gtty --version`) and your system,
and how to reproduce it. You'll get an answer within 7 days.

Accepted vulnerabilities are fixed within 90 days, usually much sooner for
serious ones. Please keep the details private until the fix is released
and the advisory is published (coordinated disclosure); if you need a
different timeline, say so in the report and we'll agree on one. Once a
fix is released, the advisory is published with credit to you (unless you
prefer not to be named).

## Supported versions

gtty has two release channels, told apart by the minor version:

| Channel | Minor version | Example | Supported |
|---|---|---|---|
| stable | even | `v1.10.x` | the latest stable release: yes |
| edge | odd | `v1.9.x` | the latest edge release: yes |
| older releases | | | no: please update |

New work is released on the edge channel first. When an edge release has
proven stable, the same commit is tagged as the next stable release (for
example `v1.9.6` becomes `v1.10.2`); the stable release notes say which
edge release it was promoted from. A security fix is released on both
channels.

## What gtty does to stay safe

- Release binaries for macOS are signed with a Developer ID and notarized
  by Apple; every release lists SHA-256 checksums (`SHA256SUMS`) and SLSA
  build provenance (`*.intoto.jsonl`) showing it was built by GitHub
  Actions from this repository.
- CodeQL scans the C code and the CI workflows on every change; the
  OpenSSF Scorecard checks the repository's practices.
- gtty opens no network connections of its own, with two exceptions you
  start yourself: the optional AI prompt talks only to the provider you
  set up, with your own key (stored in the settings file, mode 0600); in
  an ssh window gtty opens a second connection with your own ssh command
  and options (to see the remote folder and files), never with others.