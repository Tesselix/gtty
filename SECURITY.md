# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue:
[open a private report](https://github.com/gttyterm/gtty/security/advisories/new)
(GitHub's private vulnerability reporting, in the repository's Security
tab).

Say what you found, the gtty version (`gtty --version`) and your system,
and how to reproduce it.

## Disclosure process

1. You'll get an answer within 7 days confirming the report was received.
2. The problem is confirmed or rejected, and you're told which, as soon
   as it has been looked into (usually within 14 days).
3. A fix is prepared in a private fork (GitHub security advisory) and
   released in each supported channel.
4. Once the fix is out, the advisory is published (with a CVE when it
   applies), crediting you unless you prefer not to be named.

Please keep the problem private until the advisory is published, or for
at most **90 days** from your report, whichever comes first. If a fix
needs longer, we'll agree on a new date with you.

## Supported versions

Fixes go into the next release of each channel:

| Channel | Versions | Supported |
|---|---|---|
| stable | the latest even minor (`v1.8.x`, …) | yes |
| pre-release | the latest odd minor (`v1.9.x`, …) | yes |
| older releases | | no: please update |

## What gtty does to stay safe

- Release binaries for macOS are signed with a Developer ID and notarized
  by Apple; every release lists SHA-256 checksums (`SHA256SUMS`) and
  carries SLSA build provenance (`gtty.intoto.jsonl`, verify with
  `slsa-verifier`).
- CodeQL scans the C code and the CI workflows on every change; the
  OpenSSF Scorecard checks the repository's practices.
- gtty opens no network connections of its own, with two exceptions you
  start yourself: the optional AI prompt talks only to the provider you
  set up, with your own key (stored in the settings file, mode 0600); in
  an ssh window gtty opens a second connection with your own ssh command
  and options (to see the remote folder and files), never with others.
