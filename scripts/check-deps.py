#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Sagi Forbes Nagar
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Checks the packages gtty builds from (zig-pkg/, after `zig build
# --fetch=all`) against .github/deps.toml:
#   - every package fetched is listed there with the same hash (a changed
#     or new dependency must be reviewed first);
#   - its license files are the ones reviewed (sha256), and its licenses
#     (the entry's `licenses`, or every SPDX expression in its
#     REUSE.toml) can all be met with the allowed ones;
#   - known vulnerabilities (OSV.dev, by the upstream commit), each rated
#     from its CVSS vector (v4, else v3, else the database's rating;
#     the `cvss` package, scripts/requirements-deps.txt) and with a
#     suggested version to pin: the newest release with the fewest known.
# License / review problems always fail. Vulnerabilities fail only with
# --vulns fail (the weekly run), and only those rated at least
# `fail_severity` in deps.toml (default high; unrated ones count); the
# rest, and all of them with --vulns warn (pull requests), are warnings. A markdown report goes to $GITHUB_STEP_SUMMARY, and with
# --comment to the pull request (one comment, kept up to date).
#
# Python 3.11+ with `cvss` (without it every vulnerability is unrated);
# needs git and network access.
#   scripts/check-deps.py [--vulns warn|fail] [--comment] [--print]

import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tomllib
import urllib.error
import urllib.request

try:
    from cvss import CVSS2, CVSS3, CVSS4
except ImportError:  # every vulnerability counts as unrated
    CVSS2 = CVSS3 = CVSS4 = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, ".github", "deps.toml")
ZON = os.path.join(ROOT, "build.zig.zon")
PKG_DIR = os.path.join(ROOT, "zig-pkg")
OSV = "https://api.osv.dev/v1"
MARKER = "<!-- gtty-deps-report -->"
# Newer releases asked about per package, nearest first.
MAX_CANDIDATES = 40
SEVERITIES = ["none", "low", "medium", "high", "critical"]


def http_json(url, body=None, token=None, method=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------- SPDX

def spdx_tokens(expr):
    return re.findall(r"\(|\)|[A-Za-z0-9.+\-]+", expr)


def spdx_ok(expr, allowed, exceptions):
    """Can `expr` be met with the allowed licenses? WITH binds tightest,
    then AND, then OR."""
    toks = spdx_tokens(expr)
    pos = 0

    def peek():
        return toks[pos] if pos < len(toks) else None

    def take():
        nonlocal pos
        t = toks[pos]
        pos += 1
        return t

    def primary():
        if peek() == "(":
            take()
            v = disj()
            if peek() == ")":
                take()
            return v
        lic = take()
        if peek() == "WITH":
            take()
            exc = take()
            return lic in allowed and exc in exceptions
        return lic in allowed

    def conj():
        v = primary()
        while peek() == "AND":
            take()
            v = primary() and v
        return v

    def disj():
        v = conj()
        while peek() == "OR":
            take()
            v = conj() or v
        return v

    try:
        return disj() and pos == len(toks)
    except IndexError:
        return False


def reuse_expressions(pkg_path):
    """Every SPDX-License-Identifier in a package's REUSE.toml."""
    with open(os.path.join(pkg_path, "REUSE.toml"), "rb") as f:
        doc = tomllib.load(f)
    out = set()
    for a in doc.get("annotations", []):
        ids = a.get("SPDX-License-Identifier")
        if isinstance(ids, str):
            out.add(ids)
        elif isinstance(ids, list):
            out.update(ids)
    return sorted(out)


# ---------------------------------------------------------------- versions

def tag_shape(tag):
    """A regex for tags written like `tag` (v1.6.44 → ^v\\d+\\.\\d+\\.\\d+$)."""
    return re.compile("^" + re.sub(r"\\d\+|\d+", r"\\d+", re.escape(tag)) + "$")


def tag_key(tag):
    return tuple(int(n) for n in re.findall(r"\d+", tag))


def dotted(tag):
    return ".".join(re.findall(r"\d+", tag))


def remote_tags(repo):
    """{tag: commit} of the repository's tags (annotated ones peeled)."""
    out = subprocess.run(["git", "ls-remote", "--tags", repo], capture_output=True, text=True, timeout=60)
    if out.returncode != 0:
        return {}
    tags = {}
    for line in out.stdout.splitlines():
        sha, ref = line.split("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            tags[name[:-3]] = sha  # the commit wins over the tag object
        else:
            tags.setdefault(name, sha)
    return tags


def osv_batch(commits):
    """Known vulnerability ids for each commit."""
    res = http_json(f"{OSV}/querybatch", {"queries": [{"commit": c} for c in commits]})
    return [sorted({v["id"] for v in r.get("vulns", [])}) for r in res.get("results", [])]


def osv_details(vid):
    try:
        d = http_json(f"{OSV}/vulns/{vid}")
    except (urllib.error.URLError, TimeoutError):
        return {"id": vid}
    cve = next((a for a in d.get("aliases", []) if a.startswith("CVE-")), None)
    rating, score = rate(d)
    return {"id": vid, "cve": cve, "summary": (d.get("summary") or d.get("details", "")[:100]).strip(), "rating": rating, "score": score}


def rate(d):
    """(severity, base score) of an OSV entry: its CVSS vector (v4, else
    v3, else v2), else the database's own rating; ("unrated", None)."""
    vecs = {s.get("type"): s.get("score", "") for s in d.get("severity", []) or []}
    for kind, cls in (("CVSS_V4", CVSS4), ("CVSS_V3", CVSS3), ("CVSS_V2", CVSS2)):
        if kind in vecs and cls is not None:
            try:
                c = cls(vecs[kind])
                if kind == "CVSS_V4":
                    return c.severity.lower(), c.base_score
                if kind == "CVSS_V3":
                    return c.severities()[0].lower(), c.scores()[0]
                score = c.scores()[0]
                return ("high" if score >= 7 else "medium" if score >= 4 else "low"), score
            except Exception:
                pass
    db = str((d.get("database_specific") or {}).get("severity", "")).lower().replace("moderate", "medium")
    if db in SEVERITIES:
        return db, None
    return "unrated", None


def at_least(rating, threshold):
    """Does `rating` reach `threshold`? Unrated ones always do."""
    if rating not in SEVERITIES:
        return True
    return SEVERITIES.index(rating) >= SEVERITIES.index(threshold)


def zon_names():
    """hash → name of the dependencies in build.zig.zon."""
    with open(ZON) as f:
        text = f.read()
    return {h: n for n, h in re.findall(r'\.(\w+)\s*=\s*\.\{\s*\.url\s*=\s*"[^"]+",\s*\.hash\s*=\s*"([^"]+)"', text)}


def zon_urls():
    """name → url of the dependencies in build.zig.zon."""
    with open(ZON) as f:
        text = f.read()
    return dict(re.findall(r'\.(\w+)\s*=\s*\.\{\s*\.url\s*=\s*"([^"]+)"', text))


def suggest(name, osv, current_count, url):
    """The version to pin instead, or None."""
    tags = remote_tags(osv["repo"])
    shape = tag_shape(osv["tag"])
    here = tag_key(osv["tag"])
    newer = sorted((t for t in tags if shape.match(t) and tag_key(t) > here), key=tag_key)
    if not newer:
        return None
    # The nearest ones and the newest ones.
    cands = newer if len(newer) <= MAX_CANDIDATES else newer[: MAX_CANDIDATES // 2] + newer[-MAX_CANDIDATES // 2 :]
    counts = osv_batch([tags[t] for t in cands])
    scored = list(zip(cands, counts))
    clean = [t for t, v in scored if not v]
    latest, latest_v = scored[-1]
    # The newest release with the fewest known (a newer patch release
    # also carries the other fixes).
    pick = min(scored, key=lambda tv: (len(tv[1]), [-k for k in tag_key(tv[0])]))[0]
    pick_n = len(dict(scored)[pick])
    if not clean and pick_n >= current_count:
        return {"pick": None, "latest": latest, "latest_n": len(latest_v)}
    new_url = None
    if url and osv["tag"] in url:
        new_url = url.replace(osv["tag"], pick).replace(dotted(osv["tag"]), dotted(pick))
    elif url and dotted(osv["tag"]) in url:
        new_url = url.replace(dotted(osv["tag"]), dotted(pick))
    return {"pick": pick, "pick_n": pick_n, "latest": latest, "latest_n": len(latest_v), "url": new_url, "name": name}


# ---------------------------------------------------------------- report

def post_comment(body):
    """The pull request's report comment: updated, or made."""
    token = os.environ.get("GITHUB_TOKEN")
    repo = os.environ.get("GITHUB_REPOSITORY")
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if not (token and repo and event_path):
        return
    with open(event_path) as f:
        event = json.load(f)
    pr = (event.get("pull_request") or {}).get("number")
    if not pr:
        return
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    try:
        comments = http_json(f"{api}/repos/{repo}/issues/{pr}/comments?per_page=100", token=token) or []
        mine = next((c for c in comments if MARKER in (c.get("body") or "")), None)
        if mine:
            http_json(f"{api}/repos/{repo}/issues/comments/{mine['id']}", {"body": body}, token=token, method="PATCH")
        elif body is not None and "No known vulnerabilities" not in body:
            http_json(f"{api}/repos/{repo}/issues/{pr}/comments", {"body": body}, token=token, method="POST")
    except urllib.error.HTTPError as e:
        # A pull request from a fork gets a read-only token.
        print(f"::notice::could not comment on the pull request ({e.code}); the report is in the run summary")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vulns", choices=["warn", "fail"], default="fail")
    ap.add_argument("--comment", action="store_true", help="post the report on the pull request")
    ap.add_argument("--print", action="store_true", help="print what zig-pkg/ holds (to update deps.toml)")
    args = ap.parse_args()

    with open(MANIFEST, "rb") as f:
        man = tomllib.load(f)
    allowed = set(man["allowed"])
    threshold = man.get("fail_severity", "high")
    exceptions = set(man.get("allowed_exceptions", []))
    pkgs = man["packages"]
    by_hash = {p["hash"]: n for n, p in pkgs.items()}
    fetched = sorted(d for d in os.listdir(PKG_DIR) if os.path.isdir(os.path.join(PKG_DIR, d))) if os.path.isdir(PKG_DIR) else []

    if args.print:
        for d in fetched:
            path = os.path.join(PKG_DIR, d)
            print(f"{d}  ({by_hash.get(d, 'not in deps.toml')})")
            for f in sorted(os.listdir(path)):
                if re.match(r"(?i)^(licen[cs]e|copying|notice)(\.\w+)?$|^REUSE\.toml$", f):
                    print(f'    "{f}" = "{sha256(os.path.join(path, f))}"')
        return 0

    errors, warnings, lines = [], [], []

    def err(msg):
        errors.append(msg)
        print(f"::error title=dependencies::{msg}")

    if not fetched:
        err("zig-pkg/ is empty: run `zig build --fetch=all` first")
    zon = zon_names()
    for d in fetched:
        if d not in by_hash:
            known = f"{zon[d]} (`{d}`)" if d in zon else f"`{d}`"
            err(f"{known} is not reviewed: a dependency changed or a new one came in; check its license, then add / update its entry in .github/deps.toml")
    for name, p in pkgs.items():
        path = os.path.join(PKG_DIR, p["hash"])
        if p["hash"] not in fetched:
            if fetched:
                err(f"{name}: not fetched any more (hash {p['hash']}); remove or update its entry in .github/deps.toml")
            continue
        for f, want in p.get("license_files", {}).items():
            fp = os.path.join(path, f)
            if not os.path.isfile(fp):
                err(f"{name}: license file {f} is missing")
            elif sha256(fp) != want:
                err(f"{name}: {f} changed: review the license, then update its sha256 in .github/deps.toml")
        exprs = reuse_expressions(path) if p.get("reuse") else [p["licenses"]]
        for e in exprs:
            if not spdx_ok(e, allowed, exceptions):
                err(f"{name}: license `{e}` is not compatible with GPL-3.0-or-later (allowed: .github/deps.toml)")

    # Vulnerabilities.
    today = datetime.date.today()
    ignored = {}
    for ig in man.get("ignore", []):
        until = datetime.date.fromisoformat(ig["until"])
        if until < today:
            warnings.append(f"ignore entry {ig['id']} ({ig['package']}) expired on {ig['until']}")
        else:
            ignored[(ig["package"], ig["id"])] = ig
    with_osv = [(n, p) for n, p in pkgs.items() if p.get("osv") and p["hash"] in fetched]
    found = {}
    try:
        for (name, p), ids in zip(with_osv, osv_batch([p["osv"]["commit"] for _, p in with_osv])):
            found[name] = ids
    except (urllib.error.URLError, TimeoutError) as e:
        err(f"OSV.dev could not be asked: {e}")

    urls = zon_urls()
    vuln_total = 0
    sections = []
    for name, p in with_osv:
        ids = found.get(name, [])
        open_ids = [i for i in ids if (name, i) not in ignored]
        if not open_ids:
            continue
        vuln_total += len(open_ids)
        details = [osv_details(i) for i in open_ids]
        tip = suggest(name, p["osv"], len(open_ids), urls.get(name))
        details.sort(key=lambda d: (SEVERITIES.index(d["rating"]) if d["rating"] in SEVERITIES else 9, d.get("score") or 10), reverse=True)
        serious = [d for d in details if at_least(d["rating"], threshold)]
        sec = [f"### {name} — {p['what']}: {len(open_ids)} known, {len(serious)} {threshold} or worse"]
        for d in details:
            label = d["id"] + (f" ({d['cve']})" if d.get("cve") and d["cve"] != d["id"] else "")
            sev = d["rating"].capitalize() + (f" {d['score']}" if d.get("score") is not None else "")
            sec.append(f"- **{sev}** [{label}](https://osv.dev/vulnerability/{d['id']}): {d.get('summary', '')}")
        if tip and tip.get("pick"):
            what = "no known vulnerabilities" if tip["pick_n"] == 0 else f"{tip['pick_n']} known (fewest of the newer releases)"
            sec.append(f"\n**Suggested pin: `{tip['pick']}`** ({what}); latest is `{tip['latest']}` ({tip['latest_n']} known).")
            if tip.get("url"):
                sec.append(f"```sh\nzig fetch --save={name} {tip['url']}\n```")
                sec.append("then review its license and update its entry in `.github/deps.toml`.")
            else:
                sec.append("Its package URL doesn't name the version: update it by hand, then `.github/deps.toml`.")
        elif tip:
            sec.append(f"\nNo newer release has fewer known vulnerabilities (latest `{tip['latest']}`: {tip['latest_n']}). Accept them for now in `ignore` in `.github/deps.toml` (with a reason and an end date), or drop the dependency.")
        else:
            sec.append("\nNo newer release found upstream.")
        sections.append("\n".join(sec))
        worst = ", ".join(f"{d['id']} {d['rating']}" for d in details[:4]) + (", …" if len(details) > 4 else "")
        msg = f"{name}: {len(open_ids)} known vulnerabilities, {len(serious)} {threshold} or worse ({worst})"
        if tip and tip.get("pick"):
            msg += f"; pin {tip['pick']} instead"
        if args.vulns == "fail" and serious:
            err(msg)
        else:
            warnings.append(msg)
            print(f"::warning title=dependencies::{msg}")

    for w in warnings:
        if not w.startswith(tuple(n + ":" for n in pkgs)):
            print(f"::warning title=dependencies::{w}")

    # The report.
    lines.append(MARKER)
    lines.append("## Dependencies (build.zig.zon)\n")
    lines.append(f"{len(fetched)} packages checked: licenses {'✗' if any('license' in e for e in errors) else '✓'}, reviewed {'✗' if any('not reviewed' in e or 'not fetched' in e for e in errors) else '✓'}.\n")
    other = [e for e in errors if "known vulnerabilities" not in e]
    if other:
        lines.append("**Problems:**\n" + "\n".join(f"- {e}" for e in other) + "\n")
    if sections:
        lines.append(f"**{vuln_total} known vulnerabilities** in the pinned versions" + (f" (warnings on pull requests; the weekly run fails on {threshold} or worse)." if args.vulns == "warn" else f" (this run fails on {threshold} or worse).") + "\n")
        lines.extend(s + "\n" for s in sections)
    else:
        lines.append("No known vulnerabilities in the pinned versions (OSV.dev).\n")
    if ignored:
        lines.append("Accepted for now (`ignore` in .github/deps.toml): " + ", ".join(f"{i} ({p}, until {g['until']})" for (p, i), g in ignored.items()) + "\n")
    report = "\n".join(lines)
    print(report)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write(report + "\n")
    if args.comment:
        post_comment(report)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
