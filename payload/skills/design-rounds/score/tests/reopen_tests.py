#!/usr/bin/env python3
"""The checks behind test-design-score-reopen.sh (claude-config#1386): the daily check that reopens a
"Match the settled design" issue, or its milestone, closed below 100% where the close gate could not
see it (GitHub's website, a closing keyword pushed straight to the default branch), and the
SessionStart hook that starts it and says what it did.

GitHub is fake_world.World, which remembers what is written to it, so a second run sees what the
first one did. Every score is a real one, made by design_score.py (score_fixture.py).
"""
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE_DIR = os.path.dirname(HERE)
HOOKS = os.path.normpath(os.path.join(SCORE_DIR, "..", "..", "..", "hooks"))
CHECK_PY = os.path.join(HOOKS, "design-score-reopen.py")
HOOK_SH = os.path.join(HOOKS, "design-score-reopen.sh")
sys.path.insert(0, SCORE_DIR)
sys.path.insert(0, HERE)
import fake_world  # noqa: E402
import score_fixture  # noqa: E402
import score_github as sg  # noqa: E402

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL: " + name)
        for line in str(detail).splitlines()[:40]:
            print("    " + line)


def load_check():
    spec = importlib.util.spec_from_file_location("design_score_reopen", CHECK_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


T = tempfile.mkdtemp(prefix="reopen-check-test.")
REPO = "acme/widgets"
DESIGN = score_fixture.DESIGN
HEAD = "1" * 40           # the head of main when the issue was closed
TREE = "a" * 40
LATER = "5" * 40          # main moved on after the close
LATER_TREE = "e" * 40
CLOSED_AT = "2026-10-19T21:34:00Z"

work, design_bytes, MATCHED, proc, _ = score_fixture.make(T, commit=HEAD)
check("control: the fixture build scores as matched", proc.returncode == 0 and MATCHED["verdict"] == "matched",
      proc.stdout + proc.stderr)
_, _, BELOW, proc, _ = score_fixture.make(T, name="below", decisions=("D1", "D2"), failing=("D2",), commit=HEAD)
check("control: a build failing a decision scores below 100%", BELOW["verdict"] == "not-matched", proc.stdout)
_, exc_design, EXCEPTED, proc, _ = score_fixture.make(T, name="excepted", decisions=("D1", "D2"), exception=True,
                                                       failing=("D2",), commit=HEAD)
check("control: the same failing decision under an exception Dan approved scores 100%",
      EXCEPTED["verdict"] == "matched" and len(EXCEPTED.get("exceptions") or []) == 1, proc.stdout)


def score_comment(score, at="2026-10-19T20:00:00Z"):
    return {"body": sg.score_comment(score, ["design-score: test"]), "created_at": at,
            "html_url": "https://github.com/%s/issues/9#issuecomment-1" % REPO}


def world(comments=None, design=design_bytes, issue_state="closed", commit_id=None, milestone_state="open",
          ms_closed_at=None):
    w = fake_world.World()
    r = w.repo(REPO)
    r.commits = {HEAD: TREE, LATER: LATER_TREE}
    r.history = [("2026-10-19T10:00:00Z", HEAD), ("2026-10-20T09:00:00Z", LATER)]
    r.files[(DESIGN, HEAD)] = design
    r.files[(DESIGN, LATER)] = design
    r.issues[9] = {"number": 9, "title": "Match the settled design", "state": issue_state,
                   "closed_at": CLOSED_AT if issue_state == "closed" else None, "updated_at": CLOSED_AT,
                   "body": "The last step.\n\n" + sg.mark(sg.ISSUE_MARK, DESIGN), "milestone": {"number": 3}}
    r.issues[5] = {"number": 5, "title": "Phase 1: the page", "state": "closed", "closed_at": CLOSED_AT,
                   "updated_at": CLOSED_AT, "body": "Builds Requirement 1.", "milestone": {"number": 3}}
    r.comments[9] = list(comments if comments is not None else [score_comment(MATCHED)])
    r.events[9] = [{"event": "closed", "actor": {"login": "danwright32"}, "commit_id": commit_id,
                    "created_at": CLOSED_AT}]
    r.milestones[3] = {"number": 3, "title": "Agent capacity", "state": milestone_state,
                       "closed_at": ms_closed_at, "updated_at": ms_closed_at or CLOSED_AT,
                       "description": "Sam's page.\n\n" + sg.mark(sg.MILESTONE_MARK, DESIGN)}
    return w


def run(w, *extra, state=None, now="2026-10-20T12:00:00Z"):
    mod = load_check()
    out = io.StringIO()
    sd = state or tempfile.mkdtemp(dir=T)
    argv = ["design-score-reopen.py", "--state-dir", sd] + list(extra)
    if "--digest" not in extra and not any(a == "--repo" for a in extra):
        argv += ["--repo", REPO]
    rc = mod.main(argv, github=sg.GitHub(runner=w.run), now=now, out=out)
    return rc, out.getvalue(), sd


def posted(w, n=9):
    # The mark itself, never the bare word: a score comment carries the scratch folder's path.
    return [c["body"] for c in w.repo(REPO).comments.get(n, []) if "<!-- design-score-reopen {" in c["body"]]


# 1. A Match issue closed at 100% is left alone.
w = world()
rc, out, _ = run(w)
check("a Match issue closed at 100% is left alone", rc == 0 and w.repo(REPO).issues[9]["state"] == "closed"
      and w.writes() == [], out + json.dumps(w.writes()))

# 2. Closed below 100%: reopened, with a comment carrying the score read and the way to 100%.
w = world(comments=[score_comment(BELOW)])
rc, out, _ = run(w)
issue = w.repo(REPO).issues[9]
check("a Match issue closed below 100% is reopened", issue["state"] == "open", out)
body = (posted(w) or [""])[0]
check("with one comment", len(posted(w)) == 1, posted(w))
check("which carries the score it read", "not matched yet" in body and "decisions" in body, body)
check("and how to get to 100%: a new design round or an exception Dan approves",
      "design_score.py" in body and "new design round" in body and "exception" in body, body)
check("and when and by whom it was closed, in Eastern time", "danwright32" in body and " ET" in body, body)
check("and the run says what it did", "Reopened acme/widgets#9" in out and rc == 0, out)

# 3. No score posted: unmeasured is never 100%.
w = world(comments=[])
rc, out, _ = run(w)
check("a Match issue closed with no score posted is reopened", w.repo(REPO).issues[9]["state"] == "open", out)
check("and its comment says no score was posted", posted(w) and "no design match score" in posted(w)[0], posted(w))

# 4. A score comment that cannot be read is never skipped.
broken = {"body": sg.SCORE_MARK + "\n<details><summary>Score file</summary>\n\n```json\n{nope\n```\n</details>",
          "created_at": "2026-10-19T22:00:00Z", "html_url": "u"}
w = world(comments=[score_comment(MATCHED), broken])
rc, out, _ = run(w)
check("a Match issue whose newest score comment cannot be read is reopened",
      w.repo(REPO).issues[9]["state"] == "open" and "not JSON" in (posted(w) or [""])[0], out)

# 5. Judged on the code it was closed on, not on whatever main holds today.
w = world()  # the score is for HEAD, the head of main at the close; main has moved to LATER since
rc, out, _ = run(w)
check("a score for the head of main at the close counts, though main moved on after", w.writes() == [], out)
w = world(commit_id=LATER)
rc, out, _ = run(w)
check("a close by a commit is judged on that commit, so a score for older code is stale and reopened",
      w.repo(REPO).issues[9]["state"] == "open" and "measured on the code" in (posted(w) or [""])[0], out)

# 6. An exception Dan approved, recorded in the design file, is honoured, never fought.
w = world(comments=[score_comment(EXCEPTED)], design=exc_design)
rc, out, _ = run(w)
check("a Match issue closed on purpose under an exception Dan approved stays closed", w.writes() == [] and rc == 0, out)

# 7. Running twice reopens and comments once.
w = world(comments=[score_comment(BELOW)])
sd = tempfile.mkdtemp(dir=T)
run(w, state=sd)
run(w, state=sd, now="2026-10-21T12:00:00Z")
check("running twice comments once", len(posted(w)) == 1, posted(w))
check("and reopens once", sum(1 for a in w.writes() if "PATCH" in a) == 1, w.writes())
# A run that commented and then could not reopen leaves the comment for the next run, which only reopens.
w = world(comments=[score_comment(BELOW)])
w.failures.append({"method": "PATCH", "path": "repos/%s/issues/9" % REPO, "times": 1, "err": "HTTP 502: Bad Gateway"})
sd = tempfile.mkdtemp(dir=T)
rc1, out1, _ = run(w, state=sd)
check("a reopen GitHub refuses is reported, exit 1", rc1 == 1 and "502" in out1 and "acme/widgets#9" in out1, out1)
check("and the issue is not counted as handled", not os.path.exists(os.path.join(sd, "since", "acme__widgets")), os.listdir(sd))
rc2, out2, _ = run(w, state=sd, now="2026-10-20T13:00:00Z")
check("the next run reopens it without a second comment",
      w.repo(REPO).issues[9]["state"] == "open" and len(posted(w)) == 1 and rc2 == 0, out2 + json.dumps(posted(w)))
# Closed again below 100% after the reopen: a new close, so one more reopen and one more comment.
r = w.repo(REPO)
r.issues[9].update(state="closed", closed_at="2026-10-22T15:00:00Z", updated_at="2026-10-22T15:00:00Z")
r.events[9].append({"event": "closed", "actor": {"login": "danwright32"}, "commit_id": None, "created_at": "2026-10-22T15:00:00Z"})
run(w, state=sd, now="2026-10-23T12:00:00Z")
check("a second close below 100% is a new close: reopened again with its own comment",
      r.issues[9]["state"] == "open" and len(posted(w)) == 2, posted(w))

# 8. The milestone.
w = world(issue_state="open", milestone_state="closed", ms_closed_at=CLOSED_AT, comments=[score_comment(BELOW)])
rc, out, _ = run(w)
check("a design milestone closed below 100% is reopened", w.repo(REPO).milestones[3]["state"] == "open", out)
check("and its Match issue says why, once", len(posted(w)) == 1 and "Agent capacity" in posted(w)[0], posted(w))
run(w, now="2026-10-20T13:00:00Z")
check("and a second run does nothing more", len(posted(w)) == 1, posted(w))
w = world(issue_state="open", milestone_state="closed", ms_closed_at=CLOSED_AT)
rc, out, _ = run(w)
check("a design milestone closed at 100% is left alone", w.repo(REPO).milestones[3]["state"] == "closed"
      and w.writes() == [], out)
w = world(issue_state="open", milestone_state="closed", ms_closed_at=CLOSED_AT, comments=[score_comment(BELOW)])
w.repo(REPO).milestones[3]["description"] = "No design here."
del w.repo(REPO).issues[9]
rc, out, _ = run(w)
check("a milestone with no design is left alone", w.writes() == [], out)

# 9. A repository that cannot be read is reported, never skipped in silence; the others still run.
w = world(comments=[score_comment(BELOW)])
w.unreadable.add("acme/gone")
rc, out, sd = run(w, "--repo", "acme/gone", "--repo", REPO)
check("an unreadable repository is reported, exit 1", rc == 1 and "acme/gone" in out and "could not" in out.lower(), out)
check("and the readable one is still checked", w.repo(REPO).issues[9]["state"] == "open", out)
check("and only the readable one is recorded as checked",
      os.path.exists(os.path.join(sd, "since", "acme__widgets")) and not os.path.exists(os.path.join(sd, "since", "acme__gone")),
      os.listdir(os.path.join(sd, "since")) if os.path.isdir(os.path.join(sd, "since")) else "no since folder")

# 10. The repository list is the repo-digest's, read live; a list that cannot be read refuses the run.
w = world(comments=[score_comment(BELOW)])
w.digest = {"repos.json": {"repos": [{"owner": "acme", "name": "widgets"}]}, "repos-weekly.json": {"repos": []}}
rc, out, _ = run(w, "--digest")
check("the repos the digest lists are checked", rc == 0 and w.repo(REPO).issues[9]["state"] == "open", out)
w = world(comments=[score_comment(BELOW)])
w.digest = {"repos.json": {"repos": [{"owner": "acme", "name": "widgets"}]}}
rc, out, _ = run(w, "--digest")
check("a digest list that cannot be read refuses the run, naming it",
      rc == 1 and "repos-weekly.json" in out and w.writes() == [], out)

# 11. A dry run writes nothing to GitHub or to disk, and says what it would do.
w = world(comments=[score_comment(BELOW)])
rc, out, sd = run(w, "--dry-run")
check("a dry run says what it would reopen", "Would reopen acme/widgets#9" in out, out)
check("and writes nothing", w.writes() == [] and not os.path.exists(os.path.join(sd, "since")), out)

# 12. The scheduled run: it records its outcome, and leaves anything worth saying for the hook.
w = world(comments=[score_comment(BELOW)])
sd = tempfile.mkdtemp(dir=T)
rc, out, _ = run(w, "--scheduled", state=sd)
results = [f for f in os.listdir(sd) if f.startswith("result.")]
check("a scheduled run that reopened something leaves one result to say", len(results) == 1, os.listdir(sd))
said = open(os.path.join(sd, results[0])).read() if results else ""
check("naming what it reopened", "acme/widgets#9" in said, said)
check("and records that it finished", os.path.exists(os.path.join(sd, "last-finish")), os.listdir(sd))
log = open(os.path.join(sd, "log")).read() if os.path.exists(os.path.join(sd, "log")) else ""
check("and logs every run, the healthy ones too", "reopened 1" in log, log)
w = world()
sd = tempfile.mkdtemp(dir=T)
run(w, "--scheduled", state=sd)
check("a healthy scheduled run leaves nothing to say", not [f for f in os.listdir(sd) if f.startswith("result.")], os.listdir(sd))
os.makedirs(os.path.join(sd, "lock"))
w = world(comments=[score_comment(BELOW)])
rc, out, _ = run(w, "--scheduled", state=sd)
check("a scheduled run that finds another holding the lock checks nothing", w.writes() == [], out)

# 13. The SessionStart hook: starts the check at most once a day, and says what it left, once.
stub = os.path.join(T, "stub-check.py")
with open(stub, "w") as fh:
    fh.write("import sys, os\nd = sys.argv[sys.argv.index('--state-dir') + 1]\n"
             "open(os.path.join(d, 'stub-ran'), 'a').write(' '.join(sys.argv[1:]) + '\\n')\n")


def hook(sd, now, **env):
    e = dict(os.environ, DESIGN_REOPEN_STATE_DIR=sd, DESIGN_REOPEN_PY=stub, DESIGN_REOPEN_NOW=str(now))
    e.pop("CLAUDE_DETACHED_RUN", None)
    e.update(env)
    p = subprocess.run(["bash", HOOK_SH], input='{"session_id": "s1", "hook_event_name": "SessionStart"}',
                       capture_output=True, text=True, env=e)
    return p.returncode, p.stdout + p.stderr


def wait_for(path, seconds=10):
    end = time.time() + seconds
    while time.time() < end:
        if os.path.exists(path):
            return True
        time.sleep(0.05)
    return False


sd = tempfile.mkdtemp(dir=T)
rc, out = hook(sd, 1_000_000)
check("the hook starts the check when it has never run", rc == 0 and wait_for(os.path.join(sd, "stub-ran")), out)
check("as a scheduled run", wait_for(os.path.join(sd, "stub-ran")) and "--scheduled" in open(os.path.join(sd, "stub-ran")).read(), out)
if os.path.exists(os.path.join(sd, "stub-ran")):
    os.remove(os.path.join(sd, "stub-ran"))
with open(os.path.join(sd, "last-finish"), "w") as fh:
    fh.write("1000010\n")
rc, out = hook(sd, 1_000_000 + 3600)
time.sleep(0.3)
check("and not again within the day", not os.path.exists(os.path.join(sd, "stub-ran")) and rc == 0 and not out.strip(), out)
rc, out = hook(sd, 1_000_000 + 86400)
check("and again a day later", wait_for(os.path.join(sd, "stub-ran")), out)
with open(os.path.join(sd, "result.1.1"), "w") as fh:
    fh.write("Reopened acme/widgets#9 (Match the settled design).\n")
rc, out = hook(sd, 1_000_000 + 86400 + 60)
check("a result the check left is said", "Reopened acme/widgets#9" in out and rc == 0, out)
rc, out = hook(sd, 1_000_000 + 86400 + 120)
check("once", "acme/widgets#9" not in out, out)
sd = tempfile.mkdtemp(dir=T)
with open(os.path.join(sd, "last-start"), "w") as fh:
    fh.write("1000000\n")
rc, out = hook(sd, 1_000_000 + 86400)
check("a run that started and never finished is said", "never finished" in out, out)
check("and a new one is started", wait_for(os.path.join(sd, "stub-ran")), out)
sd = tempfile.mkdtemp(dir=T)
rc, out = hook(sd, 1_000_000, CLAUDE_DETACHED_RUN="1")
time.sleep(0.3)
check("a detached headless run starts nothing", not os.path.exists(os.path.join(sd, "stub-ran")) and rc == 0, out)

shutil.rmtree(T, ignore_errors=True)
print()
print("passed: %d, failed: %d" % (passed, failed))
print("SUITE-RESULT passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
