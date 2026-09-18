#!/usr/bin/env python3
"""The detector behind check-public-assets.sh: unreferenced served assets and oversized images.

    public-assets.py --repo <dir> [--head <rev>] [--base <rev>] [--cap-bytes <n>]
                     [--allowlist <path relative to the repo>] [--verbose]

Reads COMMITTED trees through git, never the working tree, because a push carries commits: an
uncommitted file cannot be pushed and a modified tracked file that was not committed is not going
anywhere either (claude-config#350 is the style gate learning that the hard way).

Two questions, answered against the same asset directories (`public/`, `static/`, `assets/` at the
repo root, whichever exist):

1. Is every file under them referenced by some tracked text file OUTSIDE them? A reference is the
   asset's path relative to its directory (`brand/x.svg`, which is how Next serves `public/brand/x.svg`
   at `/brand/x.svg`) or its bare basename (`x.svg`), as a whole token: the character before it may not
   be part of a filename and the character after it may not continue one. The verdict is a comparison
   with the merge-base tree, not a stored baseline: an asset that is unreferenced at HEAD FAILS only
   when this push introduced that state, either by adding the asset or by removing the last reference
   to it. An asset that was already unreferenced at the base is counted and left alone, so a repo's
   existing dead assets never block a push (Slate deletes its own in Try-Pennie/slate#2561).

   Files that do NOT count as a reference, each for a reason:
   - anything under the asset directory itself: an asset naming another asset says nothing about
     whether either is loaded, and a dead HTML page would keep the image it names alive;
   - `.claude/`: instructions and planning notes for agents. Measured on Slate main 2026-09-18, its
     brand redesign orchestration docs name every one of the three SVGs the dev team review found
     dead (`public/brand/logo-mark.svg`, `logo-pennie-lg-charcoal.svg`, `logo-pennie-lg-cream.svg`),
     so with `.claude/` counted this detector finds NOTHING on the very case it was built for. A plan
     that says "copy logo-mark.svg" is not a load;
   - build output and dependencies (`.next/`, `.open-next/`, `dist/`, `build/`, `out/`, `coverage/`,
     any `node_modules/`), lock files, and binaries (a NUL in the first 8 KB, or a known binary
     extension).
   Docs, scripts, config and source all count, as the issue asks (claude-config#429). A dead asset
   that a document still mentions is therefore missed, and that is accepted over flagging assets
   that documentation legitimately describes.

   Names a browser or crawler fetches WITHOUT any reference in the repo are exempt by construction
   (`favicon.ico`, `robots.txt`, `sitemap.xml`, the web manifests, `apple-touch-icon*.png`,
   `browserconfig.xml`, `humans.txt`, anything under `.well-known/`). Flagging those in every repo
   would teach the override before the rule (L36).

2. Is any RASTER image (png, jpg, jpeg, gif, webp, avif) under those directories that this push ADDS
   or MODIFIES over the cap? Only under the asset directories, because that is what a browser
   downloads. Measured on Slate main 2026-09-18: 186 tracked raster images in the whole tree, of
   which the two under `public/` are 14 KB (`brand/checkmark-still.webp`) and 594 KB
   (`brand/login-art.jpg`, the review's finding). Outside `public/` sit six 1.6 to 1.9 MB review
   screenshots under `.claude/` and a 1.2 MB icon master under `Slate_Master_Icon_Pack/`, none of
   them served, which is why the cap is scoped to the asset directories rather than the tree.

The allowlist is `.claude/hygiene-allow.txt` in the repo (read from the working tree, so a line can
be added in the same change as the asset), one path or glob per line with a reason after a `#`. An
entry WITHOUT a reason does not exempt anything and is said so (L233: an exclusion with no written
reason is one nobody reasoned about). The file's absence is the normal state, not a skip.

Output is plain language, one finding per line, each starting with the asset's path, then one
summary line starting with "Checked". Exit codes, so the hook can tell the outcomes apart (L11, L184):
  0  judged and clean
  1  judged and at least one finding
  2  nothing to judge: no asset directory at the root (one line saying so)
  3  could not measure (one line saying what failed)
"""
import argparse
import fnmatch
import os
import re
import subprocess
import sys

ASSET_DIRS = ("public", "static", "assets")
RASTER_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif"}
DEFAULT_CAP_BYTES = 250 * 1000
DEFAULT_ALLOWLIST = os.path.join(".claude", "hygiene-allow.txt")

# Reference sources this never reads, as path prefixes (any depth for node_modules).
EXCLUDED_TOP = (".claude", ".git", ".next", ".open-next", "dist", "build", "out", "coverage")
LOCK_NAMES = {
    "pnpm-lock.yaml", "package-lock.json", "yarn.lock", "bun.lockb", "Cargo.lock", "poetry.lock",
    "Pipfile.lock", "Gemfile.lock", "composer.lock", "Package.resolved",
}
BINARY_EXT = RASTER_EXT | {
    ".ico", ".woff", ".woff2", ".ttf", ".otf", ".eot", ".pdf", ".mp4", ".mov", ".webm", ".mp3",
    ".wav", ".zip", ".gz", ".tgz", ".tar", ".jar", ".class", ".pyc", ".wasm", ".psd", ".ai",
    ".sketch", ".fig", ".bin", ".so", ".dylib", ".dll", ".exe", ".DS_Store",
}
# Fetched by name with no reference anywhere in a repo. Compared against the path relative to the
# asset directory.
FETCHED_BY_NAME = {
    "favicon.ico", "robots.txt", "sitemap.xml", "manifest.json", "site.webmanifest",
    "manifest.webmanifest", "browserconfig.xml", "humans.txt", "apple-touch-icon.png",
    "apple-touch-icon-precomposed.png",
}
FETCHED_BY_NAME_DIRS = (".well-known/",)
MAX_SOURCE_BYTES = 5 * 1024 * 1024
# Filenames may hold these, so a needle preceded or followed by one is part of a longer name.
NAME_CHARS = rb"A-Za-z0-9_\-"


class Measure(Exception):
    """Something this needed could not be read; the message says what."""


def git(repo, *args, binary=False, stdin=None):
    try:
        p = subprocess.run(
            ["git", "-C", repo, *args], input=stdin, capture_output=True, check=False,
        )
    except OSError as e:
        raise Measure(f"could not run git: {e}")
    if p.returncode != 0:
        err = p.stderr.decode("utf-8", "replace").strip().splitlines()
        raise Measure(f"git {' '.join(args[:2])} failed: {err[0] if err else 'no message'}")
    return p.stdout if binary else p.stdout.decode("utf-8", "surrogateescape")


def ls_tree(repo, rev):
    """{path: (sha, size)} for every blob in the tree at rev."""
    out = git(repo, "ls-tree", "-r", "-l", "-z", rev, binary=True)
    entries = {}
    for rec in out.split(b"\0"):
        if not rec:
            continue
        meta, _, path = rec.partition(b"\t")
        parts = meta.split()
        if len(parts) < 4 or parts[1] != b"blob":
            continue
        size = int(parts[3]) if parts[3].isdigit() else 0
        entries[path.decode("utf-8", "surrogateescape")] = (parts[2].decode(), size)
    return entries


def cat_blobs(repo, specs):
    """Contents for a list of `<sha>` or `<rev>:<path>` specs, in order; None for a missing one."""
    if not specs:
        return []
    out = git(repo, "cat-file", "--batch", binary=True, stdin=("\n".join(specs) + "\n").encode())
    blobs, pos = [], 0
    for _ in specs:
        nl = out.find(b"\n", pos)
        if nl < 0:
            blobs.append(None)
            continue
        header = out[pos:nl].split()
        if len(header) >= 3 and header[1] == b"blob":
            size = int(header[2])
            blobs.append(out[nl + 1:nl + 1 + size])
            pos = nl + 1 + size + 1
        else:
            blobs.append(None)
            pos = nl + 1
    return blobs


def under(path, top):
    return path == top or path.startswith(top + "/")


def asset_dirs_in(paths):
    return [d for d in ASSET_DIRS if any(under(p, d) for p in paths)]


def is_reference_source(path, dirs):
    if any(under(path, d) for d in dirs):
        return False
    if any(under(path, t) for t in EXCLUDED_TOP):
        return False
    if "node_modules" in path.split("/"):
        return False
    name = os.path.basename(path)
    if name in LOCK_NAMES or name.endswith(".lock"):
        return False
    _, ext = os.path.splitext(name)
    if ext.lower() in BINARY_EXT or name in BINARY_EXT:
        return False
    return True


def looks_binary(blob):
    return b"\0" in blob[:8192]


def fetched_by_name(rel):
    return rel in FETCHED_BY_NAME or any(rel.startswith(d) for d in FETCHED_BY_NAME_DIRS)


def rel_of(path, dirs):
    """The asset's path relative to its asset directory, which is how it is served."""
    d = next(x for x in dirs if under(path, x))
    return path[len(d) + 1:]


def needles_for(path, dirs):
    """The tokens that count as a reference to this asset: its served path, then its bare name
    when that differs."""
    rel = rel_of(path, dirs)
    base = os.path.basename(path)
    return [rel] if rel == base else [rel, base]


def compile_needles(needle_to_assets):
    alts = sorted(needle_to_assets, key=len, reverse=True)
    pat = (rb"(?<![" + NAME_CHARS + rb".])(?:" + b"|".join(re.escape(n.encode("utf-8", "surrogateescape")) for n in alts)
           + rb")(?![" + NAME_CHARS + rb"])")
    return re.compile(pat)


def find_references(rx, needle_to_assets, sources):
    """{asset: (source path, line)} for the first reference found to each asset.

    sources is an iterable of (path, blob)."""
    hits = {}
    want = set(a for assets in needle_to_assets.values() for a in assets)
    for path, blob in sources:
        if blob is None or len(blob) > MAX_SOURCE_BYTES or looks_binary(blob):
            continue
        for m in rx.finditer(blob):
            needle = m.group(0).decode("utf-8", "surrogateescape")
            for asset in needle_to_assets.get(needle, ()):
                if asset not in hits:
                    hits[asset] = (path, blob.count(b"\n", 0, m.start()) + 1)
                    want.discard(asset)
            if not want:
                return hits
    return hits


def read_allowlist(repo, rel):
    """[(pattern, reason)] from the allowlist, or [] when there is none."""
    full = os.path.join(repo, rel)
    if not os.path.isfile(full):
        return []
    entries = []
    with open(full, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            pattern, _, reason = line.partition("#")
            pattern = pattern.strip()
            if pattern:
                entries.append((pattern, reason.strip()))
    return entries


def allow_status(path, entries):
    """'reasoned' when a reasoned entry matches, 'unreasoned' when only an entry without a reason
    does, None when nothing matches."""
    status = None
    for pattern, reason in entries:
        if path == pattern or fnmatch.fnmatchcase(path, pattern):
            if reason:
                return "reasoned"
            status = "unreasoned"
    return status


def kb(n):
    # Decimal kilobytes, floored, which is what Finder and the review that reported 594 KB both say.
    return f"{max(1, n // 1000)} KB"


def changed_paths(repo, base, head, filt, pathspecs=()):
    args = ["diff", "-z", "--name-only", f"--diff-filter={filt}", base, head]
    if pathspecs:
        args += ["--", *pathspecs]
    out = git(repo, *args, binary=True)
    return [p.decode("utf-8", "surrogateescape") for p in out.split(b"\0") if p]


def run(repo, head, base, cap, allow_rel, verbose):
    lines = []
    tree = ls_tree(repo, head)
    dirs = asset_dirs_in(tree)
    if not dirs:
        print(f"No {', '.join(d + '/' for d in ASSET_DIRS[:-1])} or {ASSET_DIRS[-1]}/ directory at the "
              f"root of this repo, so there were no assets to judge.")
        return 2

    have_base = False
    if base:
        try:
            git(repo, "rev-parse", "--verify", "--quiet", f"{base}^{{commit}}")
            have_base = True
        except Measure:
            have_base = False

    allow = read_allowlist(repo, allow_rel)
    allow_name = allow_rel.replace(os.sep, "/")

    assets = sorted(p for p in tree if any(under(p, d) for d in dirs))
    needle_to_assets = {}
    for a in assets:
        for n in needles_for(a, dirs):
            needle_to_assets.setdefault(n, []).append(a)
    rx = compile_needles(needle_to_assets)

    source_paths = sorted(p for p in tree if is_reference_source(p, dirs))
    blobs = cat_blobs(repo, [tree[p][0] for p in source_paths])
    head_refs = find_references(rx, needle_to_assets, zip(source_paths, blobs))

    unreferenced = [a for a in assets if a not in head_refs and not fetched_by_name(rel_of(a, dirs))]

    # ---- half one: the base's view of every asset unreferenced now ----
    findings = 0
    already_dead = []
    if unreferenced:
        base_assets = set()
        base_refs = {}
        if have_base:
            listed = git(repo, "ls-tree", "-r", "-z", "--name-only", base, "--", *dirs, binary=True)
            base_assets = set(p.decode("utf-8", "surrogateescape") for p in listed.split(b"\0") if p)
            # Only files that differ between base and head can hold a reference that is gone now:
            # an unchanged file has the same content on both sides, and none of those reference
            # these assets (or they would not be unreferenced at head).
            changed = [p for p in changed_paths(repo, base, head, "DM") if is_reference_source(p, dirs)]
            sub = {n: [a for a in v if a in unreferenced] for n, v in needle_to_assets.items()}
            sub = {n: v for n, v in sub.items() if v}
            if sub and changed:
                base_blobs = cat_blobs(repo, [f"{base}:{p}" for p in changed])
                base_refs = find_references(compile_needles(sub), sub, zip(changed, base_blobs))
        for a in unreferenced:
            status = allow_status(a, allow)
            if status == "reasoned":
                continue
            names = needles_for(a, dirs)
            how = f'not by path "{names[0]}"' + (f' and not by name "{names[-1]}"' if len(names) > 1 else "")
            if not have_base:
                msg = f"{a}: nothing in the repo references it ({how}), and there is no earlier commit to compare with."
            elif a not in base_assets:
                msg = f"{a}: added in this push, and nothing in the repo references it ({how})."
            elif a in base_refs:
                src, ln = base_refs[a]
                msg = (f"{a}: nothing references it now ({how}); before this push it was referenced "
                       f"by {src}:{ln}.")
            else:
                already_dead.append(a)
                continue
            lines.append(msg)
            if status == "unreasoned":
                lines.append(f"{a}: its {allow_name} line has no reason after a #, so it does not exempt it.")
            findings += 1

    # ---- half two: raster images this push adds or changes ----
    if have_base:
        touched = changed_paths(repo, base, head, "AM", dirs)
    else:
        touched = list(assets)
    images = sorted(p for p in touched if p in tree and os.path.splitext(p)[1].lower() in RASTER_EXT)
    for p in images:
        size = tree[p][1]
        if size <= cap:
            continue
        status = allow_status(p, allow)
        if status == "reasoned":
            continue
        lines.append(f"{p}: {kb(size)}, over the {kb(cap)} cap for a raster image under {p.split('/', 1)[0]}/.")
        if status == "unreasoned":
            lines.append(f"{p}: its {allow_name} line has no reason after a #, so it does not exempt it.")
        findings += 1

    for ln in lines:
        print(ln)
    dead_note = ""
    if already_dead:
        dead_note = f"; {len(already_dead)} already unreferenced before this push and left alone"
        if verbose:
            dead_note += " (" + ", ".join(already_dead) + ")"
    base_note = "" if have_base else "; no base commit, so every asset counts as added"
    print(f"Checked {len(assets)} assets under {', '.join(d + '/' for d in dirs)} against {len(source_paths)} "
          f"files; {len(images)} raster images added or changed in this push{dead_note}{base_note}.")
    return 1 if findings else 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--repo", required=True)
    ap.add_argument("--head", default="HEAD")
    ap.add_argument("--base", default="")
    ap.add_argument("--cap-bytes", type=int, default=DEFAULT_CAP_BYTES)
    ap.add_argument("--allowlist", default=DEFAULT_ALLOWLIST)
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args(argv)
    try:
        return run(a.repo, a.head, a.base, a.cap_bytes, a.allowlist, a.verbose)
    except Measure as e:
        print(f"Could not measure: {e}")
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
