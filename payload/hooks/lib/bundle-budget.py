#!/usr/bin/env python3
"""Weigh a repository's client bundle and judge it against the recorded budget (claude-config#432).

    bundle-budget.py --repo DIR --head-time SECONDS --remote URL --state-dir DIR
                     [--accept] [--pct 3] [--abs 10240]

Driven by check-bundle-budget.sh, and directly by test-check-bundle-budget.sh. It prints what it
found on stdout, one thought per line, and exits:

    0  nothing to block: recorded a first total, within the margin, lowered the record, accepted
       growth, or could not judge (no build output, an unrecognised shape, a stale build, an
       unreadable record). Every one of those says so in its own words, because a skip that prints
       nothing is indistinguishable from a pass (L98, L11).
    2  the total grew past BOTH margins over the recorded total.
    3  the arguments could not be used; the hook fails open on this and says so.

WHAT IS MEASURED. The summed gzipped size of the client chunks, in exactly two build shapes:

    Next.js     .next/static/chunks/**/*.js
                (or the OpenNext copy of it, .open-next/assets/_next/static/chunks/**/*.js,
                 which holds the same files and is read as the Next shape)
    Vite        dist/assets/*.js

Anything else that looks like build output (build/, .svelte-kit/, .nuxt/, .output/, out/, a dist/
with no assets/*.js, a .next/ with no static/chunks) is REFUSED BY NAME rather than guessed at: a
guess that read the wrong directory would report a number and nobody would know it was about
nothing. When both Next directories exist the newer one is read, never both, because summing two
copies of one bundle reads as the bundle doubling (L467).

WHEN IT MEANS SOMETHING. Only when the build is newer than the commit being pushed. A build tree
has two verdicts, before and after a build (L461), and a build from last week says nothing about
this push, so a build whose newest chunk is older than HEAD's commit time is reported as stale and
not judged.

THE RECORD. One file per repository under the state directory, named by the sha256 of the origin
remote URL, in the shared ratchet's `<path>: <count>` shape (lib/ratchet.py) so it is read by the
one reader every count ratchet in this config uses rather than a second parser (L41, L370):

    # bundle-budget record for <remote url>
    # recorded: <date> (<why>)
    # source: <chunks directory>
    total: <bytes gzipped>

The record only ever goes DOWN on its own (a smaller total replaces it, so a saving is kept) or is
raised by an explicit acceptance (--accept, the ACCEPT_BUNDLE_GROWTH=1 hatch). Growth inside the
margin passes without moving the record, so ten small additions cannot ratchet the budget up one
step at a time: each is judged against the last total somebody actually accepted.

THE MARGINS. Growth blocks only when it exceeds BOTH the percentage and the absolute amount, and
they were set from the Slate build on 2026-09-18 (see check-bundle-budget.sh's header).
"""
import argparse
import datetime
import glob
import gzip
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ratchet  # noqa: E402  (the shared record reader, beside this file)

DEFAULT_PCT = 3.0
DEFAULT_ABS = 10240

# The two shapes this reads, in the order they are tried, each as (label, directory, glob under it).
SHAPES = [
    ("Next.js", ".next/static/chunks", "**/*.js"),
    ("Next.js (OpenNext copy)", ".open-next/assets/_next/static/chunks", "**/*.js"),
    ("Vite", "dist/assets", "*.js"),
]

# Build output this deliberately does NOT read. Each is named so the refusal can say what it saw.
REFUSED = [
    ("build", "build/ (Create React App, Remix or a hand rolled build)"),
    (".svelte-kit", ".svelte-kit/ (SvelteKit)"),
    (".nuxt", ".nuxt/ (Nuxt)"),
    (".output", ".output/ (Nitro or Nuxt)"),
    ("out", "out/ (a Next.js static export)"),
    (".vercel/output", ".vercel/output/ (Vercel build output)"),
]

SUPPORTED_TEXT = "Next.js .next/static/chunks, its OpenNext copy, or Vite dist/assets"


def fmt(n):
    return f"{n:,}"


def find_chunks(repo):
    """-> (label, relative directory, [(gzipped, raw, relative path)]) for the newest shape, or None.

    Every shape present is measured and the one whose newest chunk is most recent wins, so a stale
    .next/ left beside a fresh .open-next/ cannot answer for it.
    """
    found = []
    for label, rel, pattern in SHAPES:
        base = os.path.join(repo, rel)
        if not os.path.isdir(base):
            continue
        files = [f for f in glob.glob(os.path.join(base, pattern), recursive=True)
                 if os.path.isfile(f) and f.endswith(".js")]
        if not files:
            continue
        rows = []
        newest = 0.0
        for f in sorted(files):
            with open(f, "rb") as fh:
                data = fh.read()
            rows.append((len(gzip.compress(data, compresslevel=9)), len(data),
                         os.path.relpath(f, repo)))
            newest = max(newest, os.stat(f).st_mtime)
        found.append((newest, label, rel, rows))
    if not found:
        return None
    found.sort(key=lambda t: t[0], reverse=True)
    _, label, rel, rows = found[0]
    return label, rel, rows


def refused_shape(repo):
    """The name of build output this guard does not read, when some is present, else None."""
    for rel, name in REFUSED:
        if os.path.isdir(os.path.join(repo, rel)):
            return name
    if os.path.isdir(os.path.join(repo, "dist")):
        return "dist/ with no assets/*.js (not a Vite build)"
    if os.path.isdir(os.path.join(repo, ".next")):
        return ".next/ with no static/chunks (not a completed next build)"
    if os.path.isdir(os.path.join(repo, ".open-next")):
        return ".open-next/ with no assets/_next/static/chunks (not a completed OpenNext build)"
    return None


def state_path(state_dir, remote):
    return os.path.join(state_dir, hashlib.sha256(remote.encode("utf-8")).hexdigest() + ".txt")


def read_record(path):
    """-> ("none", None) | ("ok", total) | ("unreadable", None)."""
    if not os.path.exists(path):
        return "none", None
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return "unreadable", None
    counts = ratchet.read_baseline(text)
    if "total" not in counts:
        return "unreadable", None
    return "ok", counts["total"]


def write_record(path, remote, total, source, why):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    today = datetime.date.today().isoformat()
    body = (f"# bundle-budget record for {remote}\n"
            f"# recorded: {today} ({why})\n"
            f"# source: {source}\n"
            f"total: {total}\n")
    tmp = f"{path}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, path)


def largest(rows, n=5):
    return sorted(rows, key=lambda r: r[0], reverse=True)[:n]


def print_largest(rows):
    print("The five largest chunks (gzipped bytes):")
    for gz, _raw, rel in largest(rows):
        print(f"    {fmt(gz):>10}  {rel}")


# Exit 4 says the bundle was NOT weighed, as distinct from weighed and found acceptable. Both let
# a push through, and a caller that cannot tell them apart cannot say how often this guard has ever
# reached a verdict, which is the whole question in claude-config#526 (L98, L557).
NOT_WEIGHED = 4


def main(argv):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head-time", required=True, type=int)
    ap.add_argument("--remote", required=True)
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--accept", action="store_true")
    ap.add_argument("--pct", type=float, default=DEFAULT_PCT)
    ap.add_argument("--abs", dest="abs_", type=int, default=DEFAULT_ABS)
    try:
        a = ap.parse_args(argv)
    except SystemExit:
        print("bundle-budget: the arguments could not be read, so the bundle was not judged.")
        return 3
    if not os.path.isdir(a.repo):
        print(f"bundle-budget: {a.repo} is not a directory, so the bundle was not judged.")
        return 3

    hit = find_chunks(a.repo)
    if hit is None:
        name = refused_shape(a.repo)
        if name:
            print(f"bundle-budget: found {name}, which is not a build shape this guard reads "
                  f"({SUPPORTED_TEXT}), so the bundle weight was not measured.")
        else:
            print(f"bundle-budget: no client build output here ({SUPPORTED_TEXT}), so the bundle "
                  "weight was not measured. Run the build before pushing for this check to mean "
                  "anything.")
        return NOT_WEIGHED

    label, source, rows = hit
    newest = max(os.stat(os.path.join(a.repo, r[2])).st_mtime for r in rows)
    built = datetime.datetime.fromtimestamp(newest).strftime("%Y-%m-%d %H:%M")
    if newest <= a.head_time:
        committed = datetime.datetime.fromtimestamp(a.head_time).strftime("%Y-%m-%d %H:%M")
        print(f"bundle-budget: the {label} build in {source} is stale (built {built}, HEAD "
              f"committed {committed}), so nothing was judged. Rebuild and push again for this "
              "check to mean anything.")
        return NOT_WEIGHED

    total = sum(r[0] for r in rows)
    path = state_path(a.state_dir, a.remote)
    status, recorded = read_record(path)

    if status == "unreadable":
        print(f"bundle-budget: the recorded budget at {path} could not be read (it needs a "
              f"`total: <bytes>` line), so this push was not judged. Delete that file and the next "
              "push records afresh.")
        return NOT_WEIGHED

    if status == "none":
        write_record(path, a.remote, total, source, "first measurement")
        print(f"bundle-budget: first measurement, recorded {fmt(total)} bytes gzipped from {source} "
              f"({len(rows)} chunks, built {built}). Later pushes are judged against it.")
        return 0

    grown, stale = ratchet.verdict({"total": recorded}, {"total": total})

    if stale:
        write_record(path, a.remote, total, source, "lowered: a smaller build replaced the record")
        print(f"bundle-budget: the client bundle shrank from {fmt(recorded)} to {fmt(total)} bytes "
              f"gzipped ({source}, {len(rows)} chunks). Recorded the smaller total.")
        return 0

    if not grown:
        print(f"bundle-budget: the client bundle is unchanged at {fmt(total)} bytes gzipped "
              f"({source}, {len(rows)} chunks).")
        return 0

    growth = total - recorded
    pct = (growth / recorded * 100.0) if recorded > 0 else float("inf")
    pct_text = "more than any margin" if pct == float("inf") else f"+{pct:.1f}%"
    past_both = growth > a.abs_ and pct > a.pct

    if a.accept:
        write_record(path, a.remote, total, source, "accepted growth (ACCEPT_BUNDLE_GROWTH=1)")
        print(f"bundle-budget: accepted growth from {fmt(recorded)} to {fmt(total)} bytes gzipped "
              f"(+{fmt(growth)}, {pct_text}) and recorded the new total.")
        print_largest(rows)
        return 0

    if not past_both:
        print(f"bundle-budget: the client bundle grew from {fmt(recorded)} to {fmt(total)} bytes "
              f"gzipped (+{fmt(growth)}, {pct_text}), inside the margin ({a.pct:g}% and "
              f"{fmt(a.abs_)} bytes, both must be exceeded). The record stays at "
              f"{fmt(recorded)}.")
        return 0

    print(f"PUSH BLOCKED: the client bundle grew from {fmt(recorded)} to {fmt(total)} bytes "
          f"gzipped (+{fmt(growth)}, {pct_text}), past the budget margin ({a.pct:g}% and "
          f"{fmt(a.abs_)} bytes, both exceeded).")
    print("")
    print(f"Measured from {source} ({label}, {len(rows)} chunks, built {built}, after HEAD's "
          "commit).")
    print_largest(rows)
    print(f"The recorded budget is in {path}.")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
