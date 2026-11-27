#!/usr/bin/env python3
"""The merge check's judgment (claude-config#1529): does every area a pull request touches have a
passing verification run at the head being merged?

hooks/require-verification-run.sh gathers a BUNDLE from GitHub and this file judges it. Every
verification format it reads goes through verification.py, the one reader (L370, L655): areas.json
and its ownership buckets, guides, run records, receipts and their drive logs, a PR body's done when
list, and the warn tally. Only GitHub's own answers are read here, as gh prints them.

The bundle is a folder the hook writes:

  view.json                    gh pr view: number, url, headRefOid, baseRefOid, baseRefName, body,
                               changedFiles
  slug                         owner/name
  pin                          "required <sha>" for a merge that must pin its head (gh pr merge, the
                               API routes), "required " for one that pins nothing, "not-required" for
                               a repository's own merge tool, which pins for itself and asks the gates
                               again with the exact pinned command (merge-when-ready.sh does)
  areas.json                   .claude/verification/areas.json as the BASE commit holds it, so a pull
                               request cannot edit what judges it
  files.json | files.err       the pull request's changed files (gh api --paginate pages), or why
                               GitHub could not be read for them
  comments.json | comments.err its comments, oldest first
  guides/<area>.md | .absent | .err      each touched area's guide at BASE
  compare/<sha>.json | .err    GitHub's compare of an older record's commit with the head (or with
                               the head a screenshots block was rendered at)
  compare/<from>...<to>.json | .err      GitHub's compare of two commits the judge named (#3574): the
                               base commit with an older record's commit and with the head, then the
                               two merge bases those answers name. Asked only when a file of the
                               record's area, which the pull request touches, changed since the
                               record and a merge commit came between, or may have: GitHub's list
                               of the commits between was cut short
  modes.json | modes.err       GitHub's answer to the one GraphQL read the judge wrote (#3574): the
                               mode of each file those compares would let a record outlive, at the
                               four commits compared, since a compare shows no change of mode
  repo.json | repo.err        gh api repos/<slug>, read only when a screenshots block links images,
                               for whether the repository is public (#2516)
  shots/<commit>.json | .err   the folder of pictures a screenshots block links, listed at that commit
  allow-no-screenshots         present when the merge command carries ALLOW_NO_SCREENSHOTS=1

CLI: merge_check.py verdict <bundle> [--final]
  Prints {"need": {"guides": [{area, path}], "compares": [sha], "diffs": [{from, to}], "modes":
  null or {query, variables}, "listings": [{commit, folder}], "repo": true or false}} while the
  bundle lacks something a verdict needs; the hook fetches those (diffs into
  compare/<from>...<to>.json, the modes by sending that GraphQL query as it is and keeping the answer
  in modes.json, listings into shots/<commit>.json, the repository into repo.json) and asks again,
  since one answer can call for another, and the last time
  with --final, where anything still missing is GitHub unreadable. Otherwise the verdict: {"mode", "passed",
  "decision" (allow or refuse), "text", "problems" [{kind, area, message}], "touched_areas",
  "head_sha", "say" (hand the text to the session on an allow), "screenshots" {mode, problems,
  note, overridden}}. The bundle may also hold allow-no-screenshots. In mode warn the verdict is also
  appended to the warn tally. Exit 0 whenever it printed an answer, 2 on usage; a crash prints no
  JSON, and the hook refuses on that.

Every problem has its own kind, so distinct causes never share a message (L11): github-unreadable,
base-areas-invalid, base-guide-missing, base-guide-invalid, files-incomplete, unowned-file,
ambiguous-file, no-record, malformed-record, failing-record, record-not-base-guide,
done-when-changed, stale-record, receipt-other-machine, receipt-missing, receipt-unreadable,
receipt-mismatch, receipt-not-stopped, record-not-rendered, record-edited, egress-unmeasured,
egress-not-clean, stamp-missing, stamp-failed, stamp-mismatch, no-drive, merge-unpinned,
merge-pinned-elsewhere. The screenshots check (#2516, screenshots.py) has its own, judged under
screenshots.mode and reported under "screenshots": screenshots-missing, screenshots-malformed,
screenshots-receipt-unreadable, screenshots-edited, screenshots-stale, screenshots-missing-shot,
screenshots-bad-link, screenshots-github-unreadable, screenshots-public-not-synthetic,
screenshots-link-unresolved.
"""

import json
import os
import re
import sys

sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verification as v  # noqa: E402
import screenshots as shots  # noqa: E402

# GitHub's documented list limits: a pull request's files endpoint returns at most 3000 files, and a
# compare at most 300. A list at the cap may be cut short, so it cannot show a file is absent.
PR_FILES_CAP = 3000
COMPARE_FILES_CAP = 300
LIST_MAX = 8   # files named in one message before "and N more"
# A hunk's header in a patch: where it starts and how many lines it spans, old file then new. A
# count left out is one line.
HUNK_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
# The two modes git gives a regular file, as GitHub's GraphQL API reports a tree entry's mode: a
# number (measured 33188 and 33261 either side of a commit that only made a file executable). Any
# other is a symbolic link (120000), a submodule (160000) or a folder.
REGULAR_MODES = (0o100644, 0o100755)


def _read(path):
    try:
        with open(path, errors="strict") as f:
            return f.read()
    except FileNotFoundError:
        return None


def _pages(text):
    """gh api --paginate prints each page's JSON one after another: every page, as one list."""
    dec, out, i, text = json.JSONDecoder(), [], 0, text.strip()
    while i < len(text):
        obj, i = dec.raw_decode(text, i)
        out.extend(obj if isinstance(obj, list) else [obj])
        while i < len(text) and text[i].isspace():
            i += 1
    return out


def _paths(entries):
    """Every path a list of GitHub file entries names, a rename's old path included."""
    out = []
    for e in entries:
        if not isinstance(e, dict):
            continue
        for p in (e.get("filename"), e.get("previous_filename")):
            if isinstance(p, str) and p and p not in out:
                out.append(p)
    return out


def _named(paths):
    shown = ", ".join(paths[:LIST_MAX])
    return shown + (" and %d more" % (len(paths) - LIST_MAX) if len(paths) > LIST_MAX else "")


def _hunks(patch):
    """A patch as GitHub gives it for one file, as its hunks: where each starts and how many lines it
    spans in the old file and in the new, and its lines. None for anything that is not a whole patch
    (no text, a line that belongs to no hunk, a hunk shorter or longer than its header says), so a
    patch GitHub cut short is never read as a smaller change."""
    if not isinstance(patch, str) or not patch:
        return None
    out = []
    for line in patch.split("\n"):
        m = HUNK_RE.match(line)
        if m:
            old, olen, new, nlen = (int(g) if g is not None else 1 for g in m.groups())
            out.append({"old": old, "olen": olen, "new": new, "nlen": nlen, "body": []})
        elif not out or line[:1] not in (" ", "+", "-", "\\"):
            return None
        else:
            out[-1]["body"].append(line)
    for h in out:
        marks = [line[0] for line in h["body"]]
        if h["olen"] != marks.count(" ") + marks.count("-") or h["nlen"] != marks.count(" ") + marks.count("+"):
            return None
    return out


def _whole(entry):
    """The hunks of GitHub's entry for one file, or None unless its patch is there whole: readable by
    _hunks, and adding and removing as many lines as GitHub counts for the file, so a patch that
    stops after a whole hunk is caught too."""
    hunks = _hunks(entry.get("patch"))
    if hunks is None:
        return None
    marks = [line[0] for h in hunks for line in h["body"]]
    counted = [n if isinstance(n, int) and not isinstance(n, bool) else None
               for n in (entry.get("additions"), entry.get("deletions"))]
    return hunks if [marks.count("+"), marks.count("-")] == counted else None


def _blocks(hunks):
    """Each run of changed lines in a patch: (the old file's line it starts at, how many old lines it
    removes, how many lines it puts there). A run that removes nothing goes in before that line."""
    out = []
    for h in hunks:
        at, run = h["old"] if h["olen"] else h["old"] + 1, None
        for line in h["body"]:
            mark = line[0]
            if mark == " ":
                at, run = at + 1, None
            elif mark in "+-":
                if run is None:
                    run = [at, 0, 0]
                    out.append(run)
                run[1 if mark == "-" else 2] += 1
                at += mark == "-"
    return [tuple(run) for run in out]


def _carried(blocks, first, count):
    """How far a change (its _blocks) moves the old file's lines first to first + count - 1, when it
    carries them over whole: None when it removes one of them or puts lines in between them."""
    last, moved = first + count - 1, 0
    for at, removed, added in blocks:
        if removed and at + removed - 1 < first or not removed and at <= first:
            moved += added - removed
        elif at <= last:
            return None
    return moved


def _entry(cmp, path):
    """GitHub's entry for one file in a compare, or None when it lists none."""
    files = cmp.get("files") if isinstance(cmp.get("files"), list) else []
    return next((e for e in files if isinstance(e, dict) and e.get("filename") == path), None)


def _merge_base(cmp):
    """The commit a compare measured its changes from, or None when GitHub named none."""
    mb = cmp.get("merge_base_commit")
    sha = str(mb.get("sha") or "").lower() if isinstance(mb, dict) else ""
    return sha if v.SHA_RE.match(sha) else None


def _cut(cmp):
    """Whether a compare's list of files is at GitHub's cap, so a file may be among those left out."""
    return isinstance(cmp.get("files"), list) and len(cmp["files"]) >= COMPARE_FILES_CAP


def _why_own(then, now, base, cut=()):
    """Why the text of a file changed since a record is not the base branch's change alone, as
    (told, why), or None when it is (claude-config#3574). `told` is True where GitHub's answers show
    the pull request's own change, and False where whose change it was could not be told, so the
    refusal never says the pull request changed a file that was only never compared (L11).

    `then` and `now` are GitHub's entries for the file in the pull request's patch at the record's
    commit and at the head, each measured from where the branch last took in the base branch, and
    `base` its entry in the base branch's change between those two commits. The base alone changed
    it when the pull request's patch has the same hunks at both, line for line with the lines around
    them, and each hunk sits exactly where the base's change carries the lines it rests on. The head's
    file is then the base's file with the hunks the run saw, on the same lines of it.

    Comparing the two patches as text is not enough either way. Line numbers move whenever the base
    adds a line above, and a hunk put back two rows down among identical lines, when the base dropped
    two lines above, has the same text and the same numbers. Only the base's own change says where
    each hunk belongs.

    `cut` names which of "then", "now" and "base" came from a list at GitHub's cap. A file missing
    from such a list may be among those left out, so its absence says nothing. An entry that is
    there is whole whatever the list left out. The file's mode is not in any entry: _why_mode.
    """
    for entry, key, of, absent in (
            (then, "then", "this pull request's patch at the record",
             (True, "GitHub lists no change to it by this pull request at the record")),
            (now, "now", "this pull request's patch at the head",
             (False, "GitHub lists no change to it by this pull request at the head, though its list of this pull"
                     " request's files names it")),
            (base, "base", "the base branch's change since the record",
             (True, "GitHub lists no change to it by the base branch since the record, so the change is this pull"
                    " request's own"))):
        if entry is None and key in cut:
            return False, "GitHub lists only the first %d files of %s, and it is not among them" % (COMPARE_FILES_CAP, of)
        if entry is None:
            return absent
    if any(e.get("status") != "modified" or e.get("previous_filename") for e in (then, now, base)):
        return False, "it was added, removed or renamed, which is not compared line by line"
    a, b, moved = _whole(then), _whole(now), _whole(base)
    if a is None or b is None or moved is None:
        return False, "GitHub gave no patch text for it that can be read whole (a binary or very large file)"
    if [h["body"] for h in a] != [h["body"] for h in b]:
        return True, "this pull request's patch to it differs from its patch at the record"
    blocks = _blocks(moved)
    for x, y in zip(a, b):
        if not x["olen"]:
            return False, "this pull request's patch to it starts from an empty file, which is not compared line by line"
        by = _carried(blocks, x["old"], x["olen"])
        if by is None:
            return True, "the base branch changed lines inside the ones this pull request's patch to it rests on"
        if (y["old"] - x["old"], y["new"] - x["new"]) != (by, by):
            return True, ("this pull request's patch to it is the same text in a different place: the base branch's"
                          " change puts its hunk at line %d of the file, and it is at line %d" % (x["old"] + by, y["old"]))
    return None


def _why_mode(then, at_record, now, at_head):
    """Why a file's mode at the head is not the base branch's change alone, as (told, why) like
    _why_own, or None when it is (claude-config#3574, the review of pull request 3823).

    GitHub's compare carries no mode: a commit that only makes a file executable is listed as
    modified with no patch, and one that also changes its text shows the text patch alone (measured
    on this repository's commits 3e651bc2ba and 9385db6afc). So a file whose patches say the base
    alone changed it is asked about once more. The four modes are the base branch's at the record
    (`then`) and at the head's merge base (`now`), and the branch's at the record and at the head.
    The pull request's change of mode must be the one the run saw: none at both, or the same one at
    both. A mode only the base branch changed is the base's change, like its text. A symbolic link
    or a submodule at any of the four is refused, since its patch is not a file's lines.
    """
    odd = [m for m in (then, at_record, now, at_head) if m not in REGULAR_MODES]
    if odd:
        return False, ("it is not a regular file at every commit compared (GitHub gives mode %o, a symbolic link, a"
                       " submodule or a folder), which is not compared line by line" % odd[0])
    if (then, at_record) == (now, at_head) or (then == at_record and now == at_head):
        return None
    return True, ("this pull request's change to its mode is not the one the run saw (at the record %o on the base"
                  " branch and %o on this branch, at the head %o and %o)" % (then, at_record, now, at_head))


def _modes_request(slug, wanted):
    """The one GraphQL read that gives the mode of every (commit, path) in `wanted`, as the body gh
    sends: {query, variables}. Every commit and path travels as a variable, never in the query's own
    text, so a file's name cannot change what is asked. Each commit answers with its own oid and each
    file with its own path, so the answer is read by what it says, not by where it sits (_modes_read).
    One call whatever the count, where the trees API takes one call a commit and the contents API
    gives no mode at all (measured, 2026-11-27)."""
    owner, _, name = slug.partition("/")
    commits, paths = sorted({c for c, _ in wanted}), sorted({p for _, p in wanted})
    variables = {"owner": owner, "name": name}
    variables.update(("c%d" % i, c) for i, c in enumerate(commits))
    variables.update(("p%d" % j, p) for j, p in enumerate(paths))
    declared = ["$owner:String!", "$name:String!"] + ["$c%d:GitObjectID!" % i for i in range(len(commits))] \
        + ["$p%d:String!" % j for j in range(len(paths))]
    asked = " ".join("c%d:object(oid:$c%d){... on Commit{oid %s}}" % (i, i, " ".join(
        "f%d:file(path:$p%d){path mode type}" % (j, j) for j, p in enumerate(paths) if (c, p) in wanted))
        for i, c in enumerate(commits))
    return {"query": "query(%s){repository(owner:$owner,name:$name){%s}}" % (",".join(declared), asked),
            "variables": variables}


def _modes_read(answer):
    """{(commit, path): mode} out of GitHub's answer to _modes_request, or None when it is not an
    answer to trust whole: not an object, one that reports an error beside its data, or one holding
    no repository. A commit or a file GitHub did not find answers null and is simply not in the
    result, which the caller refuses on."""
    if not isinstance(answer, dict) or answer.get("errors") or not isinstance(answer.get("data"), dict):
        return None
    repo = answer["data"].get("repository")
    if not isinstance(repo, dict):
        return None
    out = {}
    for commit in repo.values():
        if not isinstance(commit, dict):
            continue
        oid = str(commit.get("oid") or "").lower()
        for entry in commit.values():
            if isinstance(entry, dict) and isinstance(entry.get("path"), str) \
                    and isinstance(entry.get("mode"), int) and not isinstance(entry.get("mode"), bool):
                out[(oid, entry["path"])] = entry["mode"]
    return out


def _choose(entries, area, head):
    """The record that speaks for an area, and how it was found: head, older, malformed or none.

    A record made at the head wins; with none, the newest record at any commit, which the caller
    checks against the patch since. A block whose area cannot be read could be this area's, so one
    newer than the choice reads as this area's newest record being broken, not absent (L10).
    """
    mine = [(i, e) for i, e in enumerate(entries) if e["area"] in (area, None)]
    if not mine:
        return None, "none"
    newest_i, newest = mine[-1]
    at_head = [(i, e) for i, e in mine if e["record"] and e["record"]["head_sha"] == head]
    if at_head:
        i, chosen = at_head[-1]
        if newest["record"] is None and newest_i > i:
            return newest, "malformed"
        return chosen, "head"
    if newest["record"] is None:
        return newest, "malformed"
    return newest, "older"


class _Verdict:
    def __init__(self, bundle, home):
        self.bundle, self.home = bundle, home
        self.problems = []
        self.need = {"guides": [], "compares": [], "diffs": [], "modes": None, "listings": [], "repo": False}
        # Every (commit, path) whose mode some area asked about in this pass, and whether one of them
        # is not in the bundle yet. They are asked for together, in one read (asking).
        self.modes_wanted, self.modes_missing = [], False
        self.shots = None
        view_text = _read(os.path.join(bundle, "view.json"))
        try:
            self.view = json.loads(view_text) if view_text else {}
        except ValueError:
            self.view = {}
        if not isinstance(self.view, dict):
            self.view = {}
        self.slug = (_read(os.path.join(bundle, "slug")) or "").strip()
        self.head = str(self.view.get("headRefOid") or "").lower()
        self.number = self.view.get("number")
        base_sha = str(self.view.get("baseRefOid") or "")
        self.where = "%s at %s" % (self.view.get("baseRefName") or "the base branch", base_sha[:7] or "an unknown commit")

    def add(self, kind, area, message):
        self.problems.append({"kind": kind, "area": area, "message": message})

    def path(self, *parts):
        return os.path.join(self.bundle, *parts)

    # -- what GitHub said ----------------------------------------------------------------------

    def github_list(self, name, what):
        """The pages GitHub answered for `name`, or None after saying why there are none."""
        err = _read(self.path(name + ".err"))
        if err is not None:
            self.add("github-unreadable", None, "GitHub could not be read for %s: %s" % (what, err.strip() or "no reason given"))
            return None
        raw = _read(self.path(name + ".json"))
        if raw is None:
            self.add("github-unreadable", None, "no answer from GitHub was recorded for %s" % what)
            return None
        try:
            return _pages(raw)
        except ValueError as e:
            self.add("github-unreadable", None, "GitHub's answer for %s was not JSON: %s" % (what, e))
            return None

    # -- the whole judgment --------------------------------------------------------------------

    def run(self, final):
        try:
            areas = v.parse_areas(_read(self.path("areas.json")) or "")
        except v.VerificationError as e:
            for kind, msg in e.problems:
                self.add("base-areas-invalid", None, "%s on %s is malformed (%s: %s)" % (v.AREAS_PATH, self.where, kind, msg))
            return self.finish(None, [])
        mode = areas["mode"]
        if not v.SHA_RE.match(self.head):
            self.add("github-unreadable", None, "GitHub did not report this pull request's head commit")
            return self.finish(mode, [])

        self.judge_pin()
        touched, pr_files = self.judge_files(areas)
        entries = None
        pages = self.github_list("comments", "this pull request's comments")
        if pages is not None:
            entries = v.comment_records([c.get("body") or "" for c in pages if isinstance(c, dict)])

        guides, chosen = {}, {}
        for name in touched:
            adef = next(a for a in areas["areas"] if a["name"] == name)
            guides[name] = self.base_guide(name, adef["guide"], final)
            if entries is not None:
                chosen[name] = _choose(entries, name, self.head)
                rec, how = chosen[name]
                if how == "older" and not self.have(("compare", rec["record"]["head_sha"])):
                    sha = rec["record"]["head_sha"]
                    if not final and sha not in self.need["compares"]:
                        self.need["compares"].append(sha)
        self.judge_screenshots(areas, touched, pr_files, final)
        if not final and self.asking():
            return {"need": self.need}

        for name in touched:
            if name in chosen:
                self.judge_area(areas, name, guides[name], chosen[name], pr_files, final)
        if not final and self.asking():
            # An older record's area changed since, after a merge: GitHub is asked whose change it was.
            return {"need": self.need}
        return self.finish(mode, touched)

    def asking(self):
        """Whether this pass leaves something for the hook to fetch. The modes are asked for here,
        once every area has said which it wants: the answer is one file, so each ask must name them
        all, or one area's answer would replace another's."""
        if self.modes_missing:
            self.need["modes"] = _modes_request(self.slug, self.modes_wanted)
        return any(self.need.values())

    def have(self, parts):
        kind, key = parts
        return any(os.path.exists(self.path(kind, key + ext)) for ext in (".json", ".err", ".md", ".absent"))

    def judge_pin(self):
        pin = (_read(self.path("pin")) or "").strip()
        if not pin.startswith("required"):
            return
        pinned = pin[len("required"):].strip().lower()
        if not pinned:
            self.add("merge-unpinned", None, "this merge does not pin %s, the head these runs were judged at. Add"
                     " --match-head-commit %s to the gh pr merge itself (sha= or expectedHeadOid on an API merge),"
                     " so a push landing after this check cannot merge unjudged" % (self.head[:7], self.head))
        elif pinned != self.head:
            self.add("merge-pinned-elsewhere", None, "this merge pins %s, but the head these runs were judged at is %s."
                     " Pin %s, or let the check read the new head" % (pinned, self.head, self.head))

    def judge_files(self, areas):
        entries = self.github_list("files", "this pull request's changed files")
        if entries is None:
            return [], set()
        paths = _paths(entries)
        listed = len([e for e in entries if isinstance(e, dict)])
        count = self.view.get("changedFiles")
        if isinstance(count, int) and not isinstance(count, bool) and count > listed:
            self.add("files-incomplete", None, "GitHub listed %d of this pull request's %d changed files (its list stops"
                     " at %d), so the areas it touches cannot all be named. Split the pull request" % (listed, count, PR_FILES_CAP))
        b = v.bucket(areas, paths)
        if b["unowned"]:
            self.add("unowned-file", None, "%s %s owned by no area and no exemption in %s on %s. Give %s an owner"
                     " (an area's owns, or exempt with a why) in a pull request of its own first: this one cannot"
                     " change the file that judges it" % (_named(b["unowned"]), "is" if len(b["unowned"]) == 1 else "are",
                                                           v.AREAS_PATH, self.where, "it" if len(b["unowned"]) == 1 else "them"))
        for a in b["ambiguous"]:
            self.add("ambiguous-file", None, "%s is claimed by %s in %s on %s, and every file must land in exactly one"
                     " bucket" % (a["path"], " and ".join(a["buckets"]), v.AREAS_PATH, self.where))
        return b["touched_areas"], set(paths)

    def base_guide(self, name, gpath, final):
        if os.path.exists(self.path("guides", name + ".absent")):
            self.add("base-guide-missing", name, "its guide %s does not exist on %s" % (gpath, self.where))
            return None
        err = _read(self.path("guides", name + ".err"))
        if err is not None:
            self.add("github-unreadable", name, "GitHub could not be read for its guide %s on %s: %s" % (gpath, self.where, err.strip()))
            return None
        text = _read(self.path("guides", name + ".md"))
        if text is None:
            if final:
                self.add("github-unreadable", name, "no answer from GitHub was recorded for its guide %s on %s" % (gpath, self.where))
            else:
                self.need["guides"].append({"area": name, "path": gpath})
            return None
        try:
            return v.parse_guide(text)
        except v.VerificationError as e:
            self.add("base-guide-invalid", name, "its guide %s on %s is malformed: %s" % (
                gpath, self.where, "; ".join(m for _, m in e.problems[:3])))
            return None

    def judge_area(self, areas, name, guide, choice, pr_files, final):
        entry, how = choice
        if how == "none":
            self.add("no-record", name, "no verification-run record for it is in this pull request's comments. Run the"
                     " verification-guides skill's RUN procedure at %s and post the record it renders" % self.head[:7])
            return
        if how == "malformed":
            self.add("malformed-record", name, "the newest verification-run block that could be its record (comment %d)"
                     " is malformed: %s. Post a fresh record from verification.py record render" % (
                         entry["comment"] + 1, "; ".join("%s: %s" % p for p in entry["errors"][:3])))
            return
        rec = entry["record"]
        at = "the record at %s (receipt %s)" % (rec["head_sha"][:7], rec["receipt_id"])
        if how == "older" and not self.still_describes(areas, name, rec, pr_files, final):
            return
        if not rec["passed"]:
            bad = [c for c in rec["checks"] + rec["done_when"] if c["result"] == "fail"]
            self.add("failing-record", name, "%s fails %s: %s" % (
                at, ", ".join(c["id"] for c in bad), "; ".join("%s %s" % (c["id"], c["note"]) for c in bad[:3])))
        if guide is not None:
            mine = {c["id"]: c["text"] for c in rec["checks"]}
            missing = [c["id"] for c in guide["checks"] if c["id"] not in mine]
            differ = [c["id"] for c in guide["checks"] if c["id"] in mine and mine[c["id"]] != c["text"]]
            if missing or differ:
                what = []
                if missing:
                    what.append("it has no %s" % ", ".join(missing))
                if differ:
                    what.append("its %s %s different text" % (", ".join(differ), "has" if len(differ) == 1 else "have"))
                self.add("record-not-base-guide", name, "%s was not run against the guide on %s (%s). A guide this pull"
                         " request changes judges nothing until it merges" % (at, self.where, " and ".join(what)))
        now = [(d["id"], d["text"]) for d in v.done_when_items(self.view.get("body") or "")]
        then = [(d["id"], d["text"]) for d in rec["done_when"]]
        if now != then:
            self.add("done-when-changed", name, "%s answers the done when items %s, but this pull request's body now"
                     " lists %s. Run it again against the current list" % (
                         at, ", ".join(i for i, _ in then) or "none", ", ".join(i for i, _ in now) or "none"))
        self.judge_receipt(name, rec, at)

    def still_describes(self, areas, name, rec, pr_files, final):
        """For a record at an older commit: does it still describe the area at the head? Says why not,
        or asks in self.need for what GitHub has yet to answer."""
        sha = rec["head_sha"]
        err = _read(self.path("compare", sha + ".err"))
        if err is not None:
            self.add("github-unreadable", name, "GitHub could not be read for the changes since its newest record at %s: %s" % (sha[:7], err.strip()))
            return False
        raw = _read(self.path("compare", sha + ".json"))
        if raw is None:
            self.add("github-unreadable", name, "no answer from GitHub was recorded for the changes since its newest record at %s" % sha[:7])
            return False
        try:
            cmp = json.loads(raw)
        except ValueError as e:
            self.add("github-unreadable", name, "GitHub's compare of %s with the head was not JSON: %s" % (sha[:7], e))
            return False
        status = cmp.get("status") if isinstance(cmp, dict) else None
        if status not in ("ahead", "identical"):
            self.add("stale-record", name, "its newest record is at %s, which is not in this branch's history before %s"
                     " (GitHub compares them as %s: the branch was rebased or force pushed), so it says nothing about"
                     " the head. Run it again at %s" % (sha[:7], self.head[:7], status or "unknown", self.head[:7]))
            return False
        files = cmp.get("files") if isinstance(cmp.get("files"), list) else []
        if len(files) >= COMPARE_FILES_CAP:
            self.add("stale-record", name, "its newest record is at %s, and GitHub lists only the first %d files"
                     " changed since, so whether this area changed cannot be told. Run it again at %s" % (
                         sha[:7], COMPARE_FILES_CAP, self.head[:7]))
            return False
        # The pull request's OWN patch: a base change merged into the branch was verified when it
        # merged into the base. In a file the pull request does not touch, a change since the record
        # can only be the base's. In a file it does touch, the change is the base's, the pull
        # request's own, or both, and own_changes says which (#3574).
        since = [p for p in _paths(files) if p in pr_files]
        b = v.bucket(areas, since)
        mine = [f["path"] for f in b["files"] if f["bucket"] == "area:" + name]
        said = len(self.problems)
        own = self.own_changes(name, sha, cmp, mine, final) if mine else []
        if own is None:
            # Not told is never a record that still describes the head: unless GitHub is being asked
            # for more, or a reason was given, say so here, so no path through own_changes can leave
            # this area with nothing against it.
            if len(self.problems) == said and (final or not (self.need["diffs"] or self.modes_missing)):
                self.add("github-unreadable", name, "whether the changes since its newest record at %s are this pull"
                         " request's own could not be told. %s" % (sha[:7], self.retry()))
            return False
        if own:
            # What GitHub's answers show the pull request changed is said as that. What was only never
            # compared is said as not told, never as a change the pull request made (L11).
            changed, untold = ([p for p, told, _ in own if told is want] for want in (True, False))
            if changed and untold:
                what = "since then this pull request changed %s in this area, and whether it changed %s could not be" \
                       " told" % (_named(changed), _named(untold))
            elif changed:
                what = "since then this pull request changed %s in this area" % _named(changed)
            else:
                what = "whether this pull request changed %s in this area since then could not be told" % _named(untold)
            whys = ["%s: %s" % (p, why) for p, _, why in own if why]
            self.add("stale-record", name, "its newest record is at %s, and %s, so it says nothing about %s. Run it"
                     " again there%s" % (
                         sha[:7], what, self.head[:7],
                         " (a merge into the branch came since, and a record outlives one only where each such"
                         " file's change is the base branch's alone. %s%s)" % (
                             "; ".join(whys[:LIST_MAX]),
                             "; and %d more" % (len(whys) - LIST_MAX) if len(whys) > LIST_MAX else "") if whys else ""))
            return False
        return True

    def retry(self):
        """What to do about a read of GitHub that the question of whose change it was depends on."""
        return "Try the merge again, or run this area again at %s: a record made at the head needs none of these" \
               " reads" % self.head[:7]

    def own_changes(self, name, sha, cmp, paths, final):
        """Of `paths` (files of this area that the pull request touches and that changed since the
        record at `sha`): those that are not the base branch's change alone, as (path, told, why).
        `told` is True where the pull request is shown to have changed the file and False where that
        could not be told (_why_own), and why is None when no merge came between. None when GitHub
        has more to answer first (asked for in self.need) or could not be read (said), which is never
        a record that still describes the head.

        With no merge commit since the record every such change is the pull request's own, and
        nothing more is asked. After a merge, or when GitHub's list of the commits since was cut
        short so that one may be among those not listed, three more answers say whose change each
        file was:
        GitHub's compare of the base commit with the record's commit and with the head (the pull
        request's patch at each, and where the branch last took in the base branch), and its compare
        of those two merge bases (the base branch's own change). _why_own holds the rule. A compare
        shows no change of mode, so when those three leave every file as the base's change alone,
        one more read gives each file's mode at the four commits, and _why_mode holds that rule.
        """
        commits = cmp.get("commits") if isinstance(cmp.get("commits"), list) else []
        total = cmp.get("total_commits")
        merged = any(isinstance(c, dict) and isinstance(c.get("parents"), list) and len(c["parents"]) > 1 for c in commits)
        cut = isinstance(total, int) and not isinstance(total, bool) and total > len(commits)
        if not merged and not cut:
            return [(p, True, None) for p in paths]
        base = str(self.view.get("baseRefOid") or "").lower()
        if not v.SHA_RE.match(base):
            self.add("github-unreadable", name, "GitHub did not report this pull request's base commit, so whether the"
                     " changes since its newest record at %s are its own cannot be told. %s" % (sha[:7], self.retry()))
            return None
        then = self.diff(name, base, sha, final)
        now = self.diff(name, base, self.head, final)
        if then is None or now is None:
            return None
        was, at = _merge_base(then), _merge_base(now)
        if was is None or at is None:
            self.add("github-unreadable", name, "GitHub's compare of %s with %s named no merge base, so whether the"
                     " changes since its newest record are its own cannot be told. %s" % (
                         base[:7], (sha if was is None else self.head)[:7], self.retry()))
            return None
        branch = self.view.get("baseRefName") or "the base branch"
        if was == at:
            # Said as what was measured, the two merge bases being one commit. That the branch took
            # in nothing from the base is the usual cause, not the only one: a base commit GitHub
            # reports from before the record's own merge base reads the same.
            return [(p, False, "GitHub measures this pull request from the same commit of %s (%s) at the record and"
                     " at the head, so a change of %s's since the record cannot be told from its own" % (
                         branch, was[:7], branch)) for p in paths]
        moved = self.diff(name, was, at, final)
        if moved is None:
            return None
        if moved.get("status") != "ahead":
            return [(p, False, "%s at %s is not a later commit than %s at %s (GitHub compares them as %s), so what %s"
                     " changed between them cannot be told" % (
                         branch, at[:7], branch, was[:7], moved.get("status") or "unknown", branch)) for p in paths]
        capped = [key for key, c in (("then", then), ("now", now), ("base", moved)) if _cut(c)]
        whys = [(p, _why_own(_entry(then, p), _entry(now, p), _entry(moved, p), capped)) for p in paths]
        own = [(p,) + why for p, why in whys if why]
        kept = [p for p, why in whys if why is None]
        if own or not kept:
            # Stale whatever the modes of the files left: nothing more is asked of GitHub.
            return own
        four = (was, sha, at, self.head)
        modes = self.modes(name, [(c, p) for p in kept for c in four], final)
        if modes is None:
            return None
        return [(p,) + why for p, why in ((p, _why_mode(*(modes[(c, p)] for c in four))) for p in kept) if why]

    def modes(self, name, wanted, final):
        """The mode of the file at each (commit, path) of `wanted`, as {(commit, path): mode} holding
        every one of them. None when one is not in the bundle yet (asked for through self.need, or
        said unreadable on the final ask) or GitHub could not be read for them (said): a mode that
        was not read is never a mode nobody changed."""
        self.modes_wanted += [w for w in wanted if w not in self.modes_wanted]
        what = "the mode of %s at the commits compared, which says whether this pull request changed it since its" \
               " newest record" % _named(sorted({p for _, p in wanted}))
        err = _read(self.path("modes.err"))
        if err is not None:
            self.add("github-unreadable", name, "GitHub could not be read for %s: %s. %s" % (
                what, err.strip().rstrip("."), self.retry()))
            return None
        raw = _read(self.path("modes.json"))
        table = {}
        if raw is not None:
            try:
                table = _modes_read(json.loads(raw))
            except ValueError as e:
                self.add("github-unreadable", name, "GitHub's answer for %s was not JSON: %s. %s" % (what, e, self.retry()))
                return None
            if table is None:
                self.add("github-unreadable", name, "GitHub's answer for %s reported an error or named no repository."
                         " %s" % (what, self.retry()))
                return None
        missing = [w for w in wanted if w not in table]
        if not missing:
            return table
        if final and raw is None:
            self.add("github-unreadable", name, "no answer from GitHub was recorded for %s. %s" % (what, self.retry()))
        elif final:
            self.add("github-unreadable", name, "GitHub gave no mode for %s at %s%s, so whether this pull request"
                     " changed it since its newest record cannot be told. %s" % (
                         missing[0][1], missing[0][0][:7],
                         " (nor for %d more)" % (len(missing) - 1) if len(missing) > 1 else "", self.retry()))
        elif not re.fullmatch(r"[^/\s]+/[^/\s]+", self.slug):
            self.add("github-unreadable", name, "the repository this merge is in (%s) names no owner and repository,"
                     " so GitHub cannot be asked for %s. %s" % (self.slug or "none given", what, self.retry()))
        else:
            self.modes_missing = True
        return None

    def diff(self, name, a, b, final):
        """GitHub's compare of commit `a` with commit `b`, as the bundle holds it. None when it is not
        there yet (asked for in self.need, or said unreadable on the final ask) or could not be read
        (said)."""
        key = "%s...%s" % (a, b)
        what = "the changes from %s to %s, which say whether the changes since its newest record are its own" % (a[:7], b[:7])
        err = _read(self.path("compare", key + ".err"))
        if err is not None:
            self.add("github-unreadable", name, "GitHub could not be read for %s: %s. %s" % (
                what, err.strip().rstrip("."), self.retry()))
            return None
        raw = _read(self.path("compare", key + ".json"))
        if raw is None:
            if final:
                self.add("github-unreadable", name, "no answer from GitHub was recorded for %s. %s" % (what, self.retry()))
            elif {"from": a, "to": b} not in self.need["diffs"]:
                self.need["diffs"].append({"from": a, "to": b})
            return None
        try:
            cmp = json.loads(raw)
        except ValueError as e:
            self.add("github-unreadable", name, "GitHub's compare of %s with %s was not JSON: %s. %s" % (
                a[:7], b[:7], e, self.retry()))
            return None
        if not isinstance(cmp, dict):
            self.add("github-unreadable", name, "GitHub's compare of %s with %s was not a compare. %s" % (
                a[:7], b[:7], self.retry()))
            return None
        return cmp

    def judge_receipt(self, name, rec, at):
        this = v.machine_name()
        rid = rec["receipt_id"]
        if rec["machine"] != this:
            self.add("receipt-other-machine", name, "%s was run on %s, and its receipt lives only there. Merge from %s,"
                     " or run the area again on this machine (%s)" % (at, rec["machine"], rec["machine"], this))
            return
        try:
            r = v.load_receipt(rid, self.home)
        except v.VerificationError as e:
            kind, msg = e.problems[0]
            if kind == "receipt-missing":
                self.add("receipt-missing", name, "receipt %s, named by its record, is not on this machine: %s" % (rid, msg))
            else:
                self.add("receipt-unreadable", name, "receipt %s could not be read (%s: %s)" % (rid, kind, msg))
            return
        wrong = []
        for key, want in (("receipt_id", rid), ("machine", this), ("head_sha", rec["head_sha"]),
                          ("checkout_sha", rec["head_sha"])):
            if r.get(key) != want:
                wrong.append("%s %s, not %s" % (key, r.get(key), want))
        if name not in (r.get("areas") or []):
            wrong.append("areas %s, without %s" % (", ".join(map(str, r.get("areas") or [])) or "none", name))
        if wrong:
            self.add("receipt-mismatch", name, "receipt %s does not describe its record: %s" % (rid, "; ".join(wrong)))
        if not r.get("stopped_at"):
            self.add("receipt-not-stopped", name, "receipt %s shows serve still running (no stop time), so the run is not over" % rid)
        self.judge_rendered(name, rec, rid, at)
        egress = r.get("egress") if isinstance(r.get("egress"), dict) else {}
        verdict = egress.get("verdict")
        why = egress.get("why") or "no reason recorded"
        if verdict in (None, "unmeasured"):
            self.add("egress-unmeasured", name, "receipt %s records egress as unmeasured (%s), so the run cannot show"
                     " the served app reached nothing outside the project's egress.allow. Run the area again on a Mac"
                     " where the egress monitor can measure the whole run" % (rid, why))
        elif verdict != "clean":
            self.add("egress-not-clean", name, "receipt %s records egress as %s, not clean: %s" % (rid, verdict, why))
        stamp, source = r.get("build_stamp"), r.get("build_stamp_source")
        if not stamp:
            if source == "stamp-failed":
                self.add("stamp-failed", name, "the project's stamp command failed during run %s, so nothing shows which"
                         " commit the served app was built from" % rid)
            else:
                self.add("stamp-missing", name, "receipt %s carries no build stamp: the project's %s has no stamp command"
                         " (commands.stamp), so nothing shows which commit the served app was built from. Add one"
                         " that prints the commit the build came from" % (rid, v.AREAS_PATH))
        elif str(stamp).strip().lower() != rec["head_sha"]:
            self.add("stamp-mismatch", name, "receipt %s's build stamp is %s, not %s: the app that was served was not"
                     " built from the commit that was checked" % (rid, stamp, rec["head_sha"]))
        try:
            drives = v.load_drives(rid, self.home)
        except v.VerificationError as e:
            self.add("receipt-unreadable", name, "the drive log of receipt %s could not be read (%s: %s)" % (rid, *e.problems[0]))
            return
        if not any(d["area"] == name and d["exit"] == 0 for d in drives):
            self.add("no-drive", name, "receipt %s logged no successful drive call for this area, so nothing shows the run"
                     " navigated to it or triggered it" % rid)

    def judge_rendered(self, name, rec, rid, at):
        """Is the posted record exactly one record render wrote for this receipt (#1572)?

        The receipt proves the run happened; only the fingerprint render left beside it proves the
        results posted are the ones it rendered, so a comment edited by hand afterwards is refused.
        """
        try:
            rendered = v.load_rendered(rid, self.home)
        except v.VerificationError as e:
            self.add("receipt-unreadable", name, "the rendered record log of receipt %s could not be read (%s: %s)" % (rid, *e.problems[0]))
            return
        if name not in rendered:
            self.add("record-not-rendered", name, "receipt %s holds no record render wrote for this area, so %s was not"
                     " written by verification.py record render on this machine (or was rendered before render kept"
                     " fingerprints). Render it with record render and post that comment unchanged" % (rid, at))
        elif v.record_digest(rec) not in rendered[name]:
            self.add("record-edited", name, "%s is not any record verification.py record render wrote for it: the"
                     " comment was changed after it was rendered (a result, a note or a check's text). Post the"
                     " rendered comment unchanged, or run the area again" % at)

    # -- the answer ----------------------------------------------------------------------------

    def finish(self, mode, touched):
        passed = not self.problems
        pr = "PR #%s at %s" % (self.number, self.head[:7] or "an unknown head")
        lines = ["- %s: %s" % (p["area"] or "this merge", p["message"]) for p in self.problems]
        if mode is None:
            text = "Cannot judge this merge's verification runs: %s on %s is malformed, so whether it applies, and in" \
                   " which mode, cannot be told.\n%s\nFix that file, or override deliberately with" \
                   " ALLOW_UNVERIFIED_MERGE=1 <the same command>." % (v.AREAS_PATH, self.where, "\n".join(lines))
            return self.answer(None, False, "refuse", text, touched)
        scope = "every area it touches (%s)" % ", ".join(touched) if touched else "no area (it changes only exempt files)"
        if mode == "block":
            if passed:
                text = "%s: %s has a passing verification run at its head." % (pr, scope[0].upper() + scope[1:])
                return self.answer(mode, True, "allow", text, touched)
            text = "Refusing to merge %s until every area it touches has a passing verification run there. Judged" \
                   " against %s and its guides on %s, which this pull request cannot change:\n%s\nDeliberate" \
                   " override: ALLOW_UNVERIFIED_MERGE=1 <the same command>." % (pr, v.AREAS_PATH, self.where, "\n".join(lines))
            return self.answer(mode, False, "refuse", text, touched)
        # warn: allowed whatever the verdict, said in full, and tallied by pull request.
        if passed:
            body = "%s would pass: %s has a passing verification run at its head." % (pr, scope)
        else:
            body = "%s would be refused in block mode:\n%s" % (pr, "\n".join(lines))
        tally = self.tally(passed)
        text = "Verification merge check, warn mode (%s on %s says mode warn), so this merge is allowed. %s\n%s" % (
            v.AREAS_PATH, self.where, body, tally)
        return self.answer(mode, passed, "allow", text, touched)

    def tally(self, passed):
        try:
            kinds = [p["kind"] for p in self.problems + ((self.shots or {}).get("problems") or [])]
            v.tally_append(self.slug, self.number, self.head, passed, kinds, home=self.home)
            n, ask_at = v.tally_progress(self.slug, home=self.home)
        except (v.VerificationError, OSError, TypeError, ValueError) as e:
            return "The warn tally could not be written (%s), so this verdict counts toward nothing." % e
        return "Recorded in the warn tally for %s: %d pull request%s judged; Dan is asked whether to switch to block" \
               " mode at %d." % (self.slug, n, "" if n == 1 else "s", ask_at)

    def answer(self, mode, passed, decision, text, touched):
        """The verdict, with the screenshots judgment laid over it under its own mode (#2516).

        `passed` and `problems` stay the run records' alone; the pictures have `screenshots`. `say`
        is whether the hook hands the text to the session on an allow: always in warn mode, and
        whenever a picture is missing, so a warning is never lost behind a passing block mode check.
        """
        sh = self.shots or {"problems": [], "note": "", "mode": "warn"}
        allow_no = os.path.exists(self.path("allow-no-screenshots"))
        say = mode == "warn"
        if sh["problems"]:
            say = True
            lines = "\n".join("- %s: %s" % (p["area"] or "this merge", p["message"]) for p in sh["problems"])
            if allow_no:
                text += "\nScreenshots overridden for this command with ALLOW_NO_SCREENSHOTS=1, so these do not" \
                        " refuse it:\n" + lines
            elif sh["mode"] == "block":
                decision = "refuse"
                text += "\nRefusing to merge until this pull request's body carries its screenshots (screenshots.mode" \
                        " is block in %s on %s):\n%s\nDeliberate override: ALLOW_NO_SCREENSHOTS=1 <the same command>." % (
                            v.AREAS_PATH, self.where, lines)
            else:
                text += "\nScreenshots, warn mode (screenshots.mode is warn in %s on %s), so they do not refuse this" \
                        " merge. In block mode it would be refused:\n%s" % (v.AREAS_PATH, self.where, lines)
        elif sh["note"] and mode == "warn":
            text += "\n" + sh["note"]
        return {"mode": mode, "passed": passed, "decision": decision, "text": text, "problems": self.problems,
                "touched_areas": touched, "head_sha": self.head, "say": say,
                "screenshots": {"mode": sh["mode"], "problems": sh["problems"], "note": sh["note"],
                                "overridden": bool(allow_no and sh["problems"])}}

    # -- the pictures (#2516) ------------------------------------------------------------------

    def judge_screenshots(self, areas, touched, pr_files, final):
        repo_raw = _read(self.path("repo.json"))
        try:
            repo = json.loads(repo_raw) if repo_raw else None
        except ValueError:
            repo = None
        private = repo.get("private") if isinstance(repo, dict) and isinstance(repo.get("private"), bool) else None
        if repo_raw is None and _read(self.path("repo.err")) is None:
            private = "unasked"
        listings = {}
        folder = self.path("shots")
        for fn in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
            commit, ext = os.path.splitext(fn)
            if ext == ".err":
                listings[commit] = _read(os.path.join(folder, fn)) or "GitHub gave no reason"
            elif ext == ".json":
                try:
                    entries = _pages(_read(os.path.join(folder, fn)) or "")
                except ValueError as e:
                    listings[commit] = "GitHub's listing was not JSON: %s" % e
                    continue
                listings[commit] = [e.get("name") for e in entries if isinstance(e, dict) and e.get("type") == "file"]
        body = self.view.get("body") or ""
        found = shots.parse_block(body)
        m, changed, unread = found["manifest"], None, []
        if m and m["head_sha"] != self.head:
            changed = self.changed_since(m["head_sha"], pr_files, unread)
        out = shots.judge(areas, touched, body, self.head, private, listings, changed, home=self.home)
        names = ", ".join(a["name"] for a in shots.ui_areas(areas, touched))
        for why in unread:
            out["problems"].append({"kind": "screenshots-github-unreadable", "area": names, "message": why})
        for sha in out["need"]["compares"]:
            if unread:
                continue
            if not final:
                if sha not in self.need["compares"]:
                    self.need["compares"].append(sha)
            else:
                out["problems"].append({"kind": "screenshots-github-unreadable", "area": names, "message":
                                        "no answer from GitHub was recorded for the changes since the pictures at %s" % sha[:7]})
        if out["need"]["repo"]:
            if not final:
                self.need["repo"] = True
            else:
                out["problems"].append({"kind": "screenshots-github-unreadable", "area": names, "message":
                                        "no answer from GitHub was recorded for whether this repository is public"})
        for want in out["need"]["listings"]:
            if not final:
                self.need["listings"].append(want)
            else:
                out["problems"].append({"kind": "screenshots-github-unreadable", "area": names, "message":
                                        "no answer from GitHub was recorded for %s at %s, so whether its pictures"
                                        " exist cannot be told" % (want["folder"], want["commit"][:7])})
        self.shots = out

    def changed_since(self, sha, pr_files, unread):
        """The pull request's own files changed since `sha`, None when not yet read; failures to `unread`."""
        err = _read(self.path("compare", sha + ".err"))
        if err is not None:
            unread.append("GitHub could not be read for the changes since the pictures at %s: %s" % (sha[:7], err.strip()))
            return None
        raw = _read(self.path("compare", sha + ".json"))
        if raw is None:
            return None
        try:
            cmp = json.loads(raw)
        except ValueError as e:
            unread.append("GitHub's compare of %s with the head was not JSON: %s" % (sha[:7], e))
            return None
        files = cmp.get("files") if isinstance(cmp, dict) and isinstance(cmp.get("files"), list) else []
        if not isinstance(cmp, dict) or cmp.get("status") not in ("ahead", "identical") or len(files) >= COMPARE_FILES_CAP:
            # Rebased past the pictures, or too many files to tell: every file counts as changed.
            return sorted(pr_files)
        return [p for p in _paths(files) if p in pr_files]


def verdict(bundle, home=None, final=False):
    return _Verdict(bundle, home).run(final)


def main(argv):
    if len(argv) in (2, 3) and argv[0] == "verdict" and argv[2:] in ([], ["--final"]):
        try:
            v = verdict(argv[1], final=argv[2:] == ["--final"])
        except UnicodeDecodeError as e:
            # Read strictly and refused by name (claude-config#1923): the bundle decides a merge.
            print("merge_check: a file in the bundle holds a byte that is not UTF-8 (0x%02x at offset %d)"
                  % (e.object[e.start], e.start), file=sys.stderr)
            return 4
        print(json.dumps(v, indent=2))
        return 0
    print("merge_check: usage: merge_check.py verdict <bundle> [--final]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
