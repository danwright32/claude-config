#!/usr/bin/env bash
# check-description-commits.sh: say whether every commit a pull request's description names is still
# the one it should be, before a sign off question is put or a count prompt is handed over
# (claude-config#3579).
#
#   check-description-commits.sh <owner/repo> <pull request number>
#
# Why it exists. A pull request that waits on a count from the work MacBook carries the prompt for
# that count in its description, naming the exact commit to count. A fix round pushes new commits
# and appends a "## The review" section, and nothing rereads the rest. On 2026-11-24 a description
# still named a commit from before a fix round and said later commits changed no rule, after two
# rules had changed; it was caught by reading, minutes before the prompt was handed over.
#
# What it does. It reads the description, the head and the base branch with gh, finds every full or
# abbreviated commit id in the description (7 to 40 lowercase hex characters standing alone), and
# asks GitHub's compare endpoint where each one sits:
#   the head;
#   the base side: an ancestor of the merge base of the base branch and the head, which is what a
#     prompt rightly names as the commit to compare against;
#   an earlier commit of this branch: an ancestor of the head that is not on the base side, with
#     how many commits followed it and the files changed since, so a claim like "later commits change
#     no rule" can be read against them;
#   not in the head's history; or no commit at all.
# A run of digits that is no commit is a number, and is left out. Every id is listed, the prose ones
# too, because a claim made in prose about a commit is checked by reading it against its line here.
#
# A fenced block (``` or ~~~) that names the head or an earlier commit of this branch is a prompt
# handed to another session. Such a block fails when it names anything but the head and the base side,
# or does not name the head. A fenced block naming no commit of this branch is pasted output or a log
# (measured on 2026-11-25 over the last 150 pull requests: three carried an id in a fence, and one of
# them was test output naming the base and an unrelated commit), so it is reported with the prose.
# Prose never fails: a review section rightly names the commit it reviewed.
#
# Exit codes: 0 every prompt names the head and nothing else of the branch; 1 at least one does not
# (each problem is printed); 2 could not check, or bad arguments; 3 no fenced block names a commit
# of this branch, so there was no prompt to check. A failed read is never taken as a pass.
#
# Read only: it changes nothing on GitHub or on disk.
set -uo pipefail

if [ $# -ne 2 ] || ! [[ "$2" =~ ^[0-9]+$ ]] || ! [[ "$1" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "usage: check-description-commits.sh <owner/repo> <pull request number>" >&2
  exit 2
fi

pr_json="$(gh pr view "$2" --repo "$1" --json body,headRefOid,baseRefName 2>&1)" || {
  echo "Could not read pull request $1#$2, so nothing was checked: $pr_json" >&2
  exit 2
}

PR_JSON="$pr_json" exec python3 - "$1" "$2" <<'PY'
import json, os, re, subprocess, sys

repo, number = sys.argv[1], sys.argv[2]

def couldnot(msg):
    print("Could not check pull request %s#%s: %s" % (repo, number, msg))
    sys.exit(2)

try:
    pr = json.loads(os.environ["PR_JSON"])
    body = pr.get("body") or ""
    head = pr["headRefOid"]
    base_ref = pr["baseRefName"]
except Exception as e:  # a reply of the wrong shape is a failed read, never an empty description
    couldnot("the reply to gh pr view was not what was expected (%s)" % e)

def compare(left, right):
    """GitHub's compare of left...right: the parsed body, or None for a 404. Any other failure stops."""
    p = subprocess.run(["gh", "api", "repos/%s/compare/%s...%s" % (repo, left, right)],
                       capture_output=True, text=True)
    if p.returncode == 0:
        try:
            return json.loads(p.stdout)
        except ValueError:
            couldnot("the compare of %s and %s did not return JSON" % (left, right))
    if "HTTP 404" in p.stderr or '"status":"404"' in p.stdout.replace(" ", ""):
        return None
    couldnot("the compare of %s and %s failed: %s" % (left, right, (p.stderr or p.stdout).strip()))

mb_reply = compare(base_ref, head)
if mb_reply is None or not (mb_reply.get("merge_base_commit") or {}).get("sha"):
    couldnot("no merge base of %s and the head %s" % (base_ref, head))
merge_base = mb_reply["merge_base_commit"]["sha"]

TOKEN = re.compile(r"(?<![0-9A-Za-z_])[0-9a-f]{7,40}(?![0-9A-Za-z_])")

# Where each id sits, asked once per id.
seen = {}
def where(tok):
    if tok in seen:
        return seen[tok]
    r = compare(tok, head)
    if r is None:
        kind, info = ("number", None) if tok.isdigit() else ("nocommit", None)
    else:
        status = r.get("status")
        if status == "identical":
            kind, info = "head", None
        elif status == "ahead":
            b = compare(tok, merge_base)
            if b is None:
                couldnot("the compare of %s and the merge base %s found no commit" % (tok, merge_base))
            if b.get("status") in ("identical", "ahead"):
                kind, info = "base", r
            else:
                kind, info = "earlier", r
        else:
            kind, info = "outside", r
    seen[tok] = (kind, info)
    return seen[tok]

def since(info):
    n = info.get("ahead_by", 0)
    return "%d commit%s before the head" % (n, "" if n == 1 else "s")

def files_since(info):
    files = [f.get("filename", "?") for f in info.get("files") or []]
    if not files:
        return "no files changed since"
    more = " (GitHub lists at most 300)" if len(files) >= 300 else ""
    return "files changed since%s: %s" % (more, ", ".join(files))

def describe(tok):
    kind, info = where(tok)
    if kind == "head":
        return "the head"
    if kind == "base":
        return "the base side, a commit the branch was cut from (%s)" % since(info)
    if kind == "earlier":
        return "an earlier commit of this branch, %s; %s" % (since(info), files_since(info))
    if kind == "outside":
        return "not in the head's history (GitHub compares it as %s)" % info.get("status")
    return "no commit in %s" % repo

# Split the description into prose and fenced blocks, keeping each block's first line number.
blocks = []   # (start line, first text line, [tokens])
prose = []
fence = None
for i, line in enumerate(body.splitlines(), 1):
    m = re.match(r"\s*(```+|~~~+)", line)
    if fence is None and m:
        fence = m.group(1)[:3]
        blocks.append([i, "", []])
        continue
    if fence is not None and line.strip().startswith(fence):
        fence = None
        continue
    toks = TOKEN.findall(line)
    if fence is not None:
        if not blocks[-1][1] and line.strip():
            blocks[-1][1] = line.strip()
        blocks[-1][2].extend(toks)
    else:
        prose.extend(toks)

def uniq(xs):
    out = []
    for x in xs:
        if x not in out:
            out.append(x)
    return out

print("Pull request %s#%s: head %s, base branch %s, merge base %s." % (repo, number, head, base_ref, merge_base))

problems = []
prompts = 0
other = []
for start, first, toks in blocks:
    toks = [t for t in uniq(toks) if where(t)[0] != "number"]
    if not any(where(t)[0] in ("head", "earlier") for t in toks):
        # Names no commit of this branch: pasted output or a log, not a prompt about this change.
        other.extend(toks)
        continue
    prompts += 1
    label = "the fenced block at line %d (%s)" % (start, (first[:70] + "...") if len(first) > 70 else first)
    print("")
    print("In %s:" % label)
    for t in toks:
        print("  %s: %s" % (t, describe(t)))
        kind = where(t)[0]
        if kind not in ("head", "base"):
            problems.append("%s names %s, %s." % (label, t, describe(t)))
    if not any(where(t)[0] == "head" for t in toks):
        problems.append("%s does not name the head, %s." % (label, head))

prose_toks = [t for t in uniq(prose + other) if where(t)[0] != "number"]
if prose_toks:
    print("")
    print("In the prose, and in fenced blocks naming no commit of this branch (reported, never failed; "
          "check each claim made about it):")
    for t in prose_toks:
        print("  %s: %s" % (t, describe(t)))

print("")
if prompts == 0:
    print("No fenced block in the description names the head or another commit of this branch, so no "
          "count prompt was checked. "
          "If this pull request waits on a count, its prompt is missing or not in a fenced block.")
    sys.exit(3)
if problems:
    print("PROBLEMS (%d). A count prompt names the head, %s, and every claim about later commits is "
          "read against the files changed since:" % (len(problems), head))
    for p in problems:
        print("- " + p)
    sys.exit(1)
print("Every fenced block naming a commit names the head, %s, and nothing else of this branch." % head)
sys.exit(0)
PY
