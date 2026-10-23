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
  compare/<sha>.json | .err    GitHub's compare of an older record's commit with the head

CLI: merge_check.py verdict <bundle> [--final]
  Prints {"need": {"guides": [{area, path}], "compares": [sha]}} while the bundle lacks something a
  verdict needs; the hook fetches those and asks again with --final, where anything still missing is
  GitHub unreadable. Otherwise the verdict: {"mode", "passed", "decision" (allow or refuse), "text",
  "problems" [{kind, area, message}], "touched_areas", "head_sha"}. In mode warn the verdict is also
  appended to the warn tally. Exit 0 whenever it printed an answer, 2 on usage; a crash prints no
  JSON, and the hook refuses on that.

Every problem has its own kind, so distinct causes never share a message (L11): github-unreadable,
base-areas-invalid, base-guide-missing, base-guide-invalid, files-incomplete, unowned-file,
ambiguous-file, no-record, malformed-record, failing-record, record-not-base-guide,
done-when-changed, stale-record, receipt-other-machine, receipt-missing, receipt-unreadable,
receipt-mismatch, receipt-not-stopped, egress-unmeasured, egress-not-clean, stamp-missing,
stamp-failed, stamp-mismatch, no-drive, merge-unpinned, merge-pinned-elsewhere.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verification as v  # noqa: E402

# GitHub's documented list limits: a pull request's files endpoint returns at most 3000 files, and a
# compare at most 300. A list at the cap may be cut short, so it cannot show a file is absent.
PR_FILES_CAP = 3000
COMPARE_FILES_CAP = 300
LIST_MAX = 8   # files named in one message before "and N more"


def _read(path):
    try:
        with open(path) as f:
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
        self.need = {"guides": [], "compares": []}
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

    def github_list(self, name, what, final):
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
        touched, pr_files = self.judge_files(areas, final)
        entries = None
        pages = self.github_list("comments", "this pull request's comments", final)
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
        if not final and (self.need["guides"] or self.need["compares"]):
            return {"need": self.need}

        for name in touched:
            if name in chosen:
                self.judge_area(areas, name, guides[name], chosen[name], pr_files)
        return self.finish(mode, touched)

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

    def judge_files(self, areas, final):
        entries = self.github_list("files", "this pull request's changed files", final)
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

    def judge_area(self, areas, name, guide, choice, pr_files):
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
        if how == "older" and not self.still_describes(areas, name, rec, pr_files):
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

    def still_describes(self, areas, name, rec, pr_files):
        """For a record at an older commit: does it still describe the area at the head? Says why not."""
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
        # The pull request's OWN patch: a base change merged into the branch shows in the compare but
        # not in the pull request's files, and was verified when it merged into the base.
        since = [p for p in _paths(files) if p in pr_files]
        b = v.bucket(areas, since)
        mine = [f["path"] for f in b["files"] if f["bucket"] == "area:" + name]
        if mine:
            self.add("stale-record", name, "its newest record is at %s, and since then this pull request changed %s"
                     " in this area, so it says nothing about %s. Run it again there" % (sha[:7], _named(mine), self.head[:7]))
            return False
        return True

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
        egress = r.get("egress") if isinstance(r.get("egress"), dict) else {}
        verdict = egress.get("verdict")
        why = egress.get("why") or "no reason recorded"
        if verdict in (None, "unmeasured"):
            self.add("egress-unmeasured", name, "receipt %s records egress as unmeasured (%s). Nothing measures egress"
                     " for a verification run yet, so no receipt can show a clean verdict, and block mode refuses"
                     " every merge until an egress monitor exists" % (rid, why))
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
            v.tally_append(self.slug, self.number, self.head, passed, [p["kind"] for p in self.problems], home=self.home)
            n, ask_at = v.tally_progress(self.slug, home=self.home)
        except (v.VerificationError, OSError, TypeError, ValueError) as e:
            return "The warn tally could not be written (%s), so this verdict counts toward nothing." % e
        return "Recorded in the warn tally for %s: %d pull request%s judged; Dan is asked whether to switch to block" \
               " mode at %d." % (self.slug, n, "" if n == 1 else "s", ask_at)

    def answer(self, mode, passed, decision, text, touched):
        return {"mode": mode, "passed": passed, "decision": decision, "text": text, "problems": self.problems,
                "touched_areas": touched, "head_sha": self.head}


def verdict(bundle, home=None, final=False):
    return _Verdict(bundle, home).run(final)


def main(argv):
    if len(argv) in (2, 3) and argv[0] == "verdict" and argv[2:] in ([], ["--final"]):
        print(json.dumps(verdict(argv[1], final=argv[2:] == ["--final"]), indent=2))
        return 0
    print("merge_check: usage: merge_check.py verdict <bundle> [--final]", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
