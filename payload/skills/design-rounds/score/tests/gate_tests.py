#!/usr/bin/env python3
"""The checks behind test-design-score-gate.sh (claude-config#1364): the hook that refuses to close a
"Match the settled design" issue or its milestone below 100% on both halves, and `design_score.py
post`, which puts the score where that hook reads it. GitHub is a fake gh (fake_gh.py) on PATH, and
every score is a real one, made by design_score.py from a capture written here.
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCORE_DIR = os.path.dirname(HERE)
HOOKS = os.path.normpath(os.path.join(SCORE_DIR, "..", "..", "..", "hooks"))
GATE_SH = os.path.join(HOOKS, "design-score-gate.sh")
SCORE = os.path.join(SCORE_DIR, "design_score.py")
sys.path.insert(0, SCORE_DIR)
import score_github as sg  # noqa: E402

passed = failed = 0


def check(name, ok, detail=""):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print("FAIL: " + name)
        for line in str(detail).splitlines()[:30]:
            print("    " + line)


T = tempfile.mkdtemp(prefix="design-score-gate-test.")
BIN = os.path.join(T, "bin")
os.makedirs(BIN)
with open(os.path.join(BIN, "gh"), "w") as fh:
    fh.write("#!/bin/sh\nexec python3 %s \"$@\"\n" % os.path.join(HERE, "fake_gh.py"))
os.chmod(os.path.join(BIN, "gh"), 0o755)
FAKE = os.path.join(T, "gh")
os.makedirs(FAKE)
ENV = dict(os.environ, PATH=BIN + os.pathsep + os.environ["PATH"], FAKE_GH=FAKE)
ENV.pop("GH_REPO", None)
ENV.pop("GH_TOKEN", None)

REPO = "acme/widgets"
HEAD = "1" * 40
TREE = "a" * 40
DESIGN = "docs/design/capacity.html"

# --- one real score of a build that matches, from a capture written here ------------------------
sys.path.insert(0, HERE)
import score_fixture  # noqa: E402

work, design_html, MATCHED, proc, cap = score_fixture.make(T, commit=HEAD)
check("control: the fixture build scores as matched", proc.returncode == 0, proc.stdout + proc.stderr)
check("control: the score names the design by its path in the checkout", MATCHED.get("design") == DESIGN, MATCHED.get("design"))


def variant(**changes):
    s = json.loads(json.dumps(MATCHED))
    for k, v in changes.items():
        s[k] = v
    return s


NOT_MATCHED = variant(verdict="not-matched")
NOT_MATCHED["pictures"]["frames"][0]["matched"] -= 1
NOT_MATCHED["pictures"]["score"] = 0.9


def comment(score, at="2026-10-19T20:00:00Z", n=1):
    return {"body": sg.score_comment(score, ["design-score: test"]), "created_at": at,
            "html_url": "https://github.com/%s/issues/9#issuecomment-%d" % (REPO, n)}


MATCH_ISSUE = {"number": 9, "title": "Match the settled design", "state": "open",
               "body": "The last step.\n\n" + sg.mark(sg.ISSUE_MARK, DESIGN)}
PLAIN_ISSUE = {"number": 5, "title": "Phase 1: the page", "state": "open", "body": "Builds Requirement 1."}


def routes(issue9=MATCH_ISSUE, comments=None, design_bytes=design_html, extra=(), trees=None, milestone=None,
           milestone_issues=None):
    trees = trees or {HEAD: TREE}
    r = list(extra)
    r += [{"args": ["api", "repos/%s" % REPO], "out": {"default_branch": "main"}},
          {"args": ["api", "repos/%s/commits/main" % REPO], "out": {"sha": HEAD, "commit": {"tree": {"sha": TREE}}}}]
    for sha, tree in trees.items():
        r.append({"args": ["api", "repos/%s/commits/%s" % (REPO, sha)], "out": {"sha": sha, "commit": {"tree": {"sha": tree}}}})
    r += [{"args": ["api", "repos/%s/issues/9" % REPO], "out": issue9},
          {"args": ["api", "repos/%s/issues/5" % REPO], "out": PLAIN_ISSUE},
          {"args": ["api", "repos/%s/issues/9/comments?per_page=100" % REPO, "--paginate", "--slurp"],
           "out": [comments if comments is not None else [comment(MATCHED)]]},
          {"args": ["api", "-H", "Accept: application/vnd.github.raw",
                    "repos/%s/contents/%s?ref=%s" % (REPO, DESIGN, HEAD)], "out": design_bytes.decode()}]
    if milestone is not None:
        r += [{"args": ["api", "repos/%s/milestones/3" % REPO], "out": milestone},
              {"args": ["api", "repos/%s/issues?milestone=3&state=all&per_page=100" % REPO, "--paginate", "--slurp"],
               "out": [milestone_issues or []]}]
    with open(os.path.join(FAKE, "routes.json"), "w") as fh:
        json.dump(r, fh)
    with open(os.path.join(FAKE, "accounts"), "w") as fh:
        fh.write("danwright32\n")
    open(os.path.join(FAKE, "calls.log"), "w").close()


def gate(command, cwd=None, script=GATE_SH):
    payload = json.dumps({"tool_name": "Bash", "hook_event_name": "PreToolUse", "cwd": cwd or work,
                          "tool_input": {"command": command}})
    proc = subprocess.run(["bash", script], input=payload, capture_output=True, text=True, env=ENV)
    # A refusal is the deny decision on stdout, or exit 2 with the reason on stderr, which Claude Code
    # also reads as a refusal (the form the wrapper uses when its judge itself failed).
    reason = ""
    try:
        reason = json.loads(proc.stdout)["hookSpecificOutput"]["permissionDecisionReason"]
    except (ValueError, KeyError, TypeError):
        if proc.returncode == 2:
            reason = proc.stderr
    return proc.returncode, reason, proc.stdout + proc.stderr


def calls():
    with open(os.path.join(FAKE, "calls.log")) as fh:
        return [json.loads(l) for l in fh if l.strip()]


subprocess.run(["git", "-C", work, "remote", "add", "origin", "https://github.com/%s.git" % REPO], check=True)

# 1. Commands that close nothing are let through without a word to GitHub.
routes()
for cmd in ["git status", "gh issue view 9", "echo 'gh issue close 9'", "gh pr view 12 --json closingIssuesReferences"]:
    rc, reason, out = gate(cmd)
    check("%r is let through" % cmd, rc == 0 and not reason, out)
check("and GitHub is not asked about any of them", calls() == [], calls())

# 2. Closing an ordinary issue is let through.
routes()
rc, reason, out = gate("gh issue close 5")
check("closing an issue that is not a Match issue is let through", rc == 0 and not reason, out)

# 3. The Match issue closes at 100% on both halves, and not below.
routes()
rc, reason, out = gate("gh issue close 9")
check("a Match issue whose build matches at the head closes", rc == 0 and not reason, out)
routes(comments=[comment(NOT_MATCHED)])
check("control: the below 100% score holds together", __import__("design_score").verify_score(NOT_MATCHED)[1] == [],
      __import__("design_score").verify_score(NOT_MATCHED))
rc, reason, out = gate("gh issue close 9")
check("a Match issue below 100% is refused", "below 100%" in reason, out)
check("and the refusal shows the score", "pictures" in reason and "not matched yet" in reason, reason)
check("and says how to get to 100% or settle a difference with Dan",
      "design_score.py" in reason and "exception" in reason, reason)
routes(comments=[comment(MATCHED, "2026-10-19T19:00:00Z", 1), comment(NOT_MATCHED, "2026-10-19T21:00:00Z", 2)])
rc, reason, out = gate("gh issue close 9")
check("the newest score for the code decides, never an older matched one", "below 100%" in reason, out)

# 4. Unmeasured is never 100%.
routes(comments=[])
rc, reason, out = gate("gh issue close 9")
check("a Match issue with no score posted is refused", "no design match score" in reason, out)
OTHER = "2" * 40
routes(comments=[comment(variant(commit=OTHER))], trees={HEAD: TREE, OTHER: "b" * 40})
rc, reason, out = gate("gh issue close 9")
check("a score measured on other code is refused", "no score posted on it was measured on the code" in reason, out)
routes(comments=[comment(variant(commit=OTHER))], trees={HEAD: TREE, OTHER: TREE})
rc, reason, out = gate("gh issue close 9")
check("a score on a commit with the same tree counts (a squash merge of the scored branch)", not reason, out)
routes(comments=[comment(variant(dirty=True))])
rc, reason, out = gate("gh issue close 9")
check("a score drawn with uncommitted changes is refused", "uncommitted" in reason, out)
routes(design_bytes=design_html + b"<!-- edited -->\n")
rc, reason, out = gate("gh issue close 9")
check("a score measured against another version of the design is refused", "different" in reason, out)
routes(comments=[comment(variant(design="docs/design/other.html"))])
rc, reason, out = gate("gh issue close 9")
check("a score for another design is refused", "docs/design/other.html" in reason, out)
routes(comments=[comment(variant(verdict="matched", decisions=dict(MATCHED["decisions"], met=0)))])
rc, reason, out = gate("gh issue close 9")
check("a score whose verdict its rows contradict is refused", "cannot be read" in reason, out)
routes(comments=[comment(variant(unmeasured=["the design's frame f1 has no picture"], verdict="unmeasured"))])
rc, reason, out = gate("gh issue close 9")
check("an unmeasured score is refused", "below 100%" in reason or "could not score" in reason, out)
broken = {"body": sg.SCORE_MARK + "\n<details><summary>Score file</summary>\n\n```json\n{nope\n```\n</details>",
          "created_at": "2026-10-19T22:00:00Z", "html_url": "u"}
routes(comments=[comment(MATCHED), broken])
rc, reason, out = gate("gh issue close 9")
check("a score comment that cannot be read is refused, never skipped", "not JSON" in reason, out)
routes(issue9=dict(MATCH_ISSUE, body="Hand filed, no mark", title="Match the settled design: capacity"))
rc, reason, out = gate("gh issue close 9")
check("a Match issue filed by hand with no mark is refused, naming the mark to add",
      "design-score-issue" in reason, out)
routes(issue9=dict(MATCH_ISSUE, body="<!-- design-score-issue {nope} -->"))
rc, reason, out = gate("gh issue close 9")
check("a mark that cannot be read is refused, never read as no mark", "not readable JSON" in reason, out)
routes(extra=[{"args": ["api", "repos/%s/issues/9" % REPO], "rc": 1, "err": "error connecting to api.github.com"}])
rc, reason, out = gate("gh issue close 9")
check("an issue GitHub cannot be read about is refused, saying so", "could not be read" in reason, out)

# 5. Every way of closing it from here is read.
for cmd in ["gh issue close https://github.com/acme/widgets/issues/9",
            "gh issue close 9 --repo acme/widgets --reason 'not planned'",
            "gh -R acme/widgets issue close '#9' -c done",
            "rtk gh issue close 9",
            "gh issue delete 9 --yes",
            "gh issue transfer 9 acme/elsewhere",
            "gh api -X PATCH repos/acme/widgets/issues/9 -f state=closed",
            "gh api repos/{owner}/{repo}/issues/9 --method PATCH --field state=closed",
            "gh api repos/acme/widgets/issues/9 -X PATCH --input body.json",
            "cd /tmp && gh issue close 9 -R acme/widgets"]:
    routes(comments=[comment(NOT_MATCHED)])
    rc, reason, out = gate(cmd)
    check("%r is judged" % cmd, "below 100%" in reason, out)
routes(comments=[comment(NOT_MATCHED)])
rc, reason, out = gate("gh api repos/acme/widgets/issues/9 -X PATCH -f title=renamed")
check("editing a Match issue's title is not a close", not reason, out)

# 6. The milestone.
MS = {"number": 3, "title": "Agent capacity", "description": "Sam's page.\n\n" + sg.mark(sg.MILESTONE_MARK, DESIGN)}
routes(comments=[comment(NOT_MATCHED)], milestone=MS, milestone_issues=[PLAIN_ISSUE, MATCH_ISSUE])
rc, reason, out = gate("gh api -X PATCH repos/acme/widgets/milestones/3 -f state=closed")
check("closing the milestone below 100% is refused", "below 100%" in reason, out)
routes(milestone=MS, milestone_issues=[PLAIN_ISSUE, dict(MATCH_ISSUE, state="closed")])
rc, reason, out = gate("gh api -X PATCH repos/acme/widgets/milestones/3 -f state=closed")
check("closing the milestone at 100% is let through", not reason, out)
routes(milestone=MS, milestone_issues=[PLAIN_ISSUE])
rc, reason, out = gate("gh api -X PATCH repos/acme/widgets/milestones/3 -f state=closed")
check("a design milestone with no Match issue left is refused", "holds no Match the settled design issue" in reason, out)
routes(milestone=MS, milestone_issues=[PLAIN_ISSUE])
rc, reason, out = gate("gh api -X DELETE repos/acme/widgets/milestones/3")
check("deleting a design milestone is judged as closing it", "holds no Match" in reason, out)
routes(milestone={"number": 3, "title": "Plain", "description": "no design"}, milestone_issues=[PLAIN_ISSUE])
rc, reason, out = gate("gh api -X PATCH repos/acme/widgets/milestones/3 -f state=closed")
check("closing a milestone with no design is let through", not reason, out)

# 7. A merge whose closing keywords name the Match issue is judged at the pull request's head.
PR_HEAD = "3" * 40


def pr_routes(score_commit, tree):
    view = {"number": 12, "url": "https://github.com/%s/pull/12" % REPO, "headRefOid": PR_HEAD,
            "closingIssuesReferences": [{"number": 9, "repository": {"nameWithOwner": REPO}}]}
    routes(comments=[comment(variant(commit=score_commit))], trees={HEAD: TREE, PR_HEAD: tree, score_commit: tree},
           extra=[{"args": ["pr", "view", "12"], "out": view},
                  {"args": ["api", "-H", "Accept: application/vnd.github.raw",
                            "repos/%s/contents/%s?ref=%s" % (REPO, DESIGN, PR_HEAD)], "out": design_html.decode()}])


pr_routes(PR_HEAD, "c" * 40)
rc, reason, out = gate("gh pr merge 12 --squash")
check("merging a pull request that closes the Match issue at 100% is let through", not reason, out)
pr_routes(HEAD, TREE)
with open(os.path.join(FAKE, "routes.json")) as fh:
    r = json.load(fh)
for x in r:
    if x["args"] == ["api", "repos/%s/commits/%s" % (REPO, PR_HEAD)]:
        x["out"] = {"sha": PR_HEAD, "commit": {"tree": {"sha": "c" * 40}}}
with open(os.path.join(FAKE, "routes.json"), "w") as fh:
    json.dump(r, fh)
rc, reason, out = gate("gh pr merge 12 --squash")
check("merging it with no score at its head is refused", "no score posted on it was measured" in reason, out)

# 8. The account that can see the repository is used, never switched to.
routes()
with open(os.path.join(FAKE, "routes.json")) as fh:
    r = json.load(fh)
r.insert(0, {"args": ["api", "repos/%s/issues/9" % REPO], "token": "", "rc": 1, "err": "HTTP 404: Not Found"})
r.insert(0, {"args": ["api", "repos/%s/issues/9" % REPO], "token": "tok-danwright32", "rc": 1, "err": "HTTP 404: Not Found"})
with open(os.path.join(FAKE, "routes.json"), "w") as fh:
    json.dump(r, fh)
with open(os.path.join(FAKE, "accounts"), "w") as fh:
    fh.write("danwright32\ndwright-pennie\n")
rc, reason, out = gate("gh issue close 9")
check("a repository only another logged in account sees is read as that account", not reason, out)
check("with its token for the call, never an auth switch",
      any(c["token"] == "tok-dwright-pennie" for c in calls()) and not any(c["args"][:2] == ["auth", "switch"] for c in calls()),
      calls())

# 9. GraphQL.
routes()
rc, reason, out = gate("gh api graphql -f query='mutation { closeIssue(input: {issueId: $id}) { issue { id } } }' -f id=$X")
check("a GraphQL closeIssue this gate cannot read is refused", "GraphQL" in reason, out)

# 10. Posting: every pull request in the milestone posts the current score, on itself and on the
# Match issue, where the gate above reads it.
def post_routes(milestone=True, issues=None, head=HEAD, comment_rc=0):
    view = {"number": 12, "url": "https://github.com/%s/pull/12" % REPO, "headRefOid": head,
            "milestone": {"number": 3, "title": "Agent capacity"} if milestone else None}
    r = [{"args": ["pr", "view", "12", "--repo", REPO, "--json", "number,url,headRefOid,milestone"], "out": view},
         {"args": ["api", "repos/%s/issues?milestone=3&state=all&per_page=100" % REPO, "--paginate", "--slurp"],
          "out": [issues if issues is not None else [PLAIN_ISSUE, MATCH_ISSUE]]},
         {"args": ["pr", "comment"], "out": "", "rc": comment_rc, "err": "HTTP 422: could not comment"},
         {"args": ["issue", "comment"], "out": ""}]
    with open(os.path.join(FAKE, "routes.json"), "w") as fh:
        json.dump(r, fh)
    open(os.path.join(FAKE, "calls.log"), "w").close()


def post():
    proc = subprocess.run([sys.executable, SCORE, "post", os.path.join(cap, "score.json"), "--repo", REPO, "--pr", "12"],
                          capture_output=True, text=True, env=ENV)
    return proc.returncode, proc.stdout + proc.stderr


post_routes()
rc, out = post()
posted = {c["args"][0]: c for c in calls() if c["args"][:2] in (["pr", "comment"], ["issue", "comment"])}
check("post puts the score on the pull request and on the Match issue", rc == 0 and set(posted) == {"pr", "issue"}, out)
check("on the Match issue by its number", "issue" in posted and posted["issue"]["args"][2] == "9", posted)
body = posted.get("issue", {}).get("bodyFile", "")
check("the comment carries the score file the gate reads back, unchanged", sg.read_score_comment(body) == MATCHED, body[:300])
check("and the score as printed, both halves", "decisions  1 of 1 met (100%)" in body and "pictures" in body, body[:600])
post_routes(milestone=False)
rc, out = post()
check("a pull request in no milestone gets the score, and says the gate cannot read it there",
      rc == 1 and "NO MATCH ISSUE" in out and any(c["args"][:2] == ["pr", "comment"] for c in calls()), out)
post_routes(issues=[PLAIN_ISSUE])
rc, out = post()
check("a milestone with no Match issue for this design is said, exit 1", rc == 1 and "NO MATCH ISSUE" in out, out)
post_routes(head="4" * 40)
rc, out = post()
posted = [c for c in calls() if c["args"][:2] == ["pr", "comment"]]
check("a score measured on another commit says so in the comment and on screen",
      rc == 0 and "not this pull request's head" in out and posted and "not this pull request's head" in posted[0].get("bodyFile", ""), out)
post_routes(comment_rc=1)
rc, out = post()
check("a comment GitHub refuses is reported, exit 2", rc == 2 and "422" in out, out)
with open(os.path.join(T, "forged.json"), "w") as fh:
    json.dump(dict(MATCHED, verdict="not-matched"), fh)
post_routes()
proc = subprocess.run([sys.executable, SCORE, "post", os.path.join(T, "forged.json"), "--repo", REPO, "--pr", "12"],
                      capture_output=True, text=True, env=ENV)
check("a score file that contradicts itself is never posted", proc.returncode == 2 and calls() == [], proc.stdout)
proc = subprocess.run([sys.executable, SCORE, "post", os.path.join(cap, "score.json")], capture_output=True, text=True, env=ENV)
check("post without --repo and --pr prints the usage, exit 2", proc.returncode == 2 and "usage" in proc.stdout.lower(), proc.stdout)

# 11. The gate's own failure refuses rather than allowing.
# The wrapper's seam, DESIGN_SCORE_GATE_PY, points it at a judge that dies before judging.
broken_py = os.path.join(T, "broken-gate.py")
with open(broken_py, "w") as fh:
    fh.write("import sys\nsys.stderr.write('Traceback: the judge fell over')\nsys.exit(7)\n")
ENV["DESIGN_SCORE_GATE_PY"] = broken_py
routes()
rc, reason, out = gate("gh issue close 9")
check("a judge that fails while a close is judged refuses the close, saying it could not check",
      "could not check" in reason and "exit 7" in reason, out)
rc, reason, out = gate("gh pr merge 12 --squash")
check("and refuses a merge it could not check", "could not check" in reason, out)
rc, reason, out = gate("ls -la")
check("and still lets through a command that closes nothing", not reason and rc == 0, out)
del ENV["DESIGN_SCORE_GATE_PY"]

shutil.rmtree(T, ignore_errors=True)
print()
print("passed: %d, failed: %d" % (passed, failed))
print("SUITE-RESULT passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
