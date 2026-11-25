#!/usr/bin/env bash
# lib/posted-text-scan.py: what was posted to a repository in a window, scanned with the publish
# gate's own lists before the repository turns public (claude-config#3582).
#
# The publish gate judges text posted to a PUBLIC repository and lets a private one through without
# reading its lists, so text posted while a repository is private is judged by nothing, and stays
# unjudged when the repository turns public. This suite holds the one command that rechecks it:
#   1. It refuses a window it cannot read exactly (no repository, no time zone, a time to come).
#   2. A planted control goes first: a scan that does not report it stops, and reads nothing.
#   3. It reads every kind of text the gate would have judged (issue and pull request titles and
#      bodies, comments, review comments, review bodies, commit comments, commit messages on every
#      branch and on every pull request, branch names, releases, the repository's description) and
#      the earlier revisions and titles GitHub still holds, and reports a name by its label and
#      line, never printing the name.
#   4. A failed call, a page that is not what was asked for, a revision GitHub would not hand over
#      and a spent time budget are each a failure, never a short clean result.
#   5. It only reads: every call it makes of gh is a GET or a GraphQL query.
#   6. The Slack drafts gate and the publish gate, as they stand, let a session run it.
#
# gh is a stand in on the PATH answering from recorded pages, never the network. Every name here is
# invented. This repository is public, and no work organisation or repository name belongs in this
# file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$HERE/lib/posted-text-scan.py"
LIB="$HERE/lib/work-names.py"
. "$HERE/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ [[ "$1" == *"$2"* ]]; }
lacks(){ [[ "$1" != *"$2"* ]]; }
# Both read their text from a here string, never a pipe: a reader that leaves on its first match
# kills the writer of a pipe, which under pipefail reads as a failure (test-pipefail-shortcircuit.sh).
lacks_any_case(){ ! grep -q -i -F -- "$2" <<< "$1"; }
has_line(){ grep -q -x -F -- "$2" <<< "$1"; }

for tool in python3 shasum jq node; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done
if [ ! -f "$SCAN" ]; then
  echo "FAIL: there is no lib/posted-text-scan.py beside this suite at $HERE, so text posted while a repository was private has no check (claude-config#3582)."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/posted-text-scan.XXXXXX")" || exit 1
case "${WORK%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR"
CALLS="$WORK/gh-calls"
LIST="$WORK/list.json"
REPO="danwright-test/notes"
SINCE="2026-11-24T18:30:00Z"

# A fake gh, never the real one: one signed in account, the work repository list, and recorded
# pages keyed by the path asked for. A path with no page fails as GitHub's 404 does, so a call this
# suite did not expect is a failure and never an empty page. Anything that is not a read is recorded
# as a WRITE and fails.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CALLS"
key(){ printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
case "$1 $2" in
  "auth status")
    printf '{"hosts":{"github.com":[{"login":"alice","active":true,"state":"success"}]}}\n'
    exit 0 ;;
  "auth token")
    printf 'tok-alice\n'; exit 0 ;;
  "api -H")
    case "$*" in *contents/repos.json*) cat "$FAKE_LIST"; exit 0 ;; esac ;;
  "api --paginate")
    if [ "$3" = "--slurp" ] && [ "$#" -eq 4 ]; then
      f="$FAKE_PAGES/$(key "$4")"
      [ -f "$f.sleep" ] && sleep "$(cat "$f.sleep")"
      if [ -f "$f.fail" ]; then cat "$f.fail" >&2; exit 1; fi
      if [ ! -f "$f" ]; then echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
      cat "$f"; exit 0
    fi ;;
  "api graphql")
    if [ "$3" = "-f" ] && [ "$#" -eq 4 ]; then
      f="$FAKE_PAGES/graphql"
      if [ -f "$f.fail" ]; then cat "$f.fail" >&2; exit 1; fi
      if [ ! -f "$f" ]; then echo "gh: no recorded answer" >&2; exit 1; fi
      cat "$f"; exit 0
    fi ;;
esac
printf 'WRITE|%s\n' "$*" >> "$FAKE_CALLS"
echo "fake gh: a call this suite did not expect: $*" >&2
exit 64
SH
chmod +x "$BIN/gh"

printf '%s\n' '{"tokenByOwner":{"Acme-Corp":"X"},"repos":[{"owner":"Acme-Corp","name":"acme-widgets","label":"widgets"},{"owner":"Acme-Corp","name":"zephyr","label":"Zephyr"}]}' > "$LIST"
FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
PROJECTS="$WORK/CLAUDE.md"
printf '%s' '## Projects

On Dans-MacBook-Pro:
- `~/Apps/Quillfeather`: Next.js

## Writing Style
' > "$PROJECTS"

# The recorded pages, written by one builder so the named and the clean repository differ in nothing
# but the two invented names. Each file holds what `gh api --paginate --slurp` prints: a list of pages.
cat > "$WORK/build.py" <<'PY'
import json, os, re, sys
out, variant, repo, since = sys.argv[1:5]
W, Z = ("acme-widgets", "Zephyr") if variant == "named" else ("the-tool", "Breeze")
os.makedirs(out, exist_ok=True)
base = "https://github.com/%s" % repo


def page(path, pages):
    with open(os.path.join(out, re.sub(r"[^A-Za-z0-9]", "_", path)), "w") as f:
        json.dump(pages, f)


def commit(sha, message):
    return {"sha": sha, "commit": {"message": message}}


page("repos/%s/issues?state=all&since=%s&per_page=100" % (repo, since), [
    [{"number": 11, "node_id": "I_11", "title": "Suite times out",
      "body": "The suite runs long.\n\nCopied from the %s issue.\nNothing else." % W},
     {"number": 12, "node_id": "I_12", "title": "Seen in %s" % Z, "body": None}],
    [{"number": 21, "node_id": "PR_21", "pull_request": {}, "title": "Hold the suite to its limit",
      "body": "What changed.\nThe %s build showed it." % W},
     {"number": 22, "node_id": "PR_22", "pull_request": {}, "title": "Tidy", "body": "Nothing to see."}]])
page("repos/%s/issues/comments?since=%s&per_page=100" % (repo, since), [[
    {"id": 501, "node_id": "IC_501", "html_url": base + "/issues/11#issuecomment-501", "body": "Same in %s." % Z},
    {"id": 502, "node_id": "IC_502", "html_url": base + "/issues/11#issuecomment-502", "body": "Agreed."}]])
page("repos/%s/pulls/comments?since=%s&per_page=100" % (repo, since), [[
    {"id": 601, "node_id": "PRRC_601", "html_url": base + "/pull/21#discussion_r601",
     "body": "A question.\nIs this the %s rule?" % W}]])
page("repos/%s/pulls/21/reviews?per_page=100" % repo, [[
    {"id": 701, "node_id": "PRR_701", "html_url": base + "/pull/21#pullrequestreview-701",
     "body": "As %s does it." % W},
    {"id": 702, "node_id": "PRR_702", "html_url": base + "/pull/21#pullrequestreview-702", "body": ""}]])
page("repos/%s/pulls/22/reviews?per_page=100" % repo, [[]])
# A commit only its pull request still holds: the branch was deleted, so no branch reaches it.
page("repos/%s/pulls/21/commits?per_page=100" % repo, [[commit("a" * 38 + "21", "Port the %s fix" % W)]])
page("repos/%s/pulls/22/commits?per_page=100" % repo, [[commit("b" * 40, "Tidy")]])
branch = "fix/%s-port" % W
page("repos/%s/branches?per_page=100" % repo, [[
    {"name": "main", "commit": {"sha": "c" * 40}}, {"name": branch, "commit": {"sha": "d" * 40}}]])
page("repos/%s/commits?sha=main&since=%s&per_page=100" % (repo, since), [[
    commit("b" * 40, "Tidy"), commit("e" * 40, "Hold the limit\n\nMeasured twice.\nAs %s has it." % Z)]])
page("repos/%s/commits?sha=%s&since=%s&per_page=100" % (repo, branch.replace("/", "%2F"), since), [[
    commit("b" * 40, "Tidy"), commit("f" * 40, "Start the port")]])
page("repos/%s/comments?per_page=100" % repo, [[
    {"id": 801, "node_id": "CC_801", "html_url": base + "/commit/eeee#commitcomment-801",
     "updated_at": "2026-11-24T20:00:00Z", "body": "This is the %s line." % W},
    {"id": 802, "node_id": "CC_802", "html_url": base + "/commit/eeee#commitcomment-802",
     "updated_at": "2026-11-01T00:00:00Z", "body": "An old one, before the window, on %s." % W}]])
page("repos/%s/releases?per_page=100" % repo, [[
    {"id": 901, "name": "%s preview" % Z, "tag_name": "v1", "body": "Notes.\nBuilt against %s." % W}]])
page("repos/%s" % repo, [{"description": "Notes for %s" % W, "homepage": "", "topics": ["notes"]}])


def node(i, kind, edits=(), renames=None):
    n = {"__typename": kind, "id": i,
         "userContentEdits": {"pageInfo": {"hasNextPage": False}, "nodes": list(edits)}}
    if renames is not None:
        # As GitHub answers (measured 2026-11-24 on 14 pull requests): totalCount counts every
        # timeline item whatever itemTypes asked for, so it is no measure of a list cut short.
        n["timelineItems"] = {"totalCount": 9, "pageInfo": {"hasNextPage": False}, "nodes": renames}
    return n


current = "The suite runs long.\n\nCopied from the %s issue.\nNothing else." % W
nodes = [
    node("I_11", "Issue", [
        {"editedAt": "2026-11-24T21:00:00Z", "deletedAt": None, "diff": current},
        {"editedAt": "2026-11-24T19:00:00Z", "deletedAt": None, "diff": "The suite runs long.\nFirst seen in %s." % Z},
        {"editedAt": "2026-11-24T18:45:00Z", "deletedAt": "2026-11-24T22:00:00Z", "diff": None}],
        [{"createdAt": "2026-11-24T19:05:00Z", "previousTitle": "%s times out" % Z}]),
    node("I_12", "Issue", renames=[]), node("PR_21", "PullRequest", renames=[]),
    node("PR_22", "PullRequest", renames=[]), node("IC_501", "IssueComment"), node("IC_502", "IssueComment"),
    node("PRRC_601", "PullRequestReviewComment"), node("PRR_701", "PullRequestReview"),
    node("PRR_702", "PullRequestReview"), node("CC_801", "CommitComment")]
with open(os.path.join(out, "graphql"), "w") as f:
    json.dump({"data": {"nodes": nodes}}, f)
PY
key(){ printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
fixture(){   # $1 = named or clean; makes a fresh set of recorded pages in PAGES
  PAGES="$WORK/pages-$1-$RANDOM"
  python3 "$WORK/build.py" "$PAGES" "$1" "$REPO" "$SINCE"
}

fixture_env(){
  env HOOK_TESTS_RUNNING=1 HOME="$HOMEDIR" PATH="$BIN:$PATH" FAKE_CALLS="$CALLS" FAKE_LIST="$LIST" \
    FAKE_PAGES="$PAGES" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" WORK_NAMES_PROJECT_LIST="$PROJECTS" \
    WORK_NAMES_PROJECT_HASHES="" "$@"
}
scan(){   # $@ = the command's arguments; stdout in out, stderr in err, exit code in rc
  : > "$CALLS"
  out="$(fixture_env python3 "$SCAN" "$@" 2>"$WORK/err")"; rc=$?
  err="$(cat "$WORK/err")"
  all="$out
$err"
}
gathered(){ grep -c "repos/$REPO" "$CALLS" || true; }

# ================================================================ 1. the window must be exact
fixture clean
scan
check "no arguments is a refusal, exit 2: rc=$rc" [ "$rc" -eq 2 ]
check "and says how to run it: $err" has "$err" "--since"
scan "$REPO"
check "a repository with no --since is refused: rc=$rc" [ "$rc" -eq 2 ]
scan notes --since "$SINCE"
check "a repository named without its owner is refused: rc=$rc" [ "$rc" -eq 2 ]
check "and says what a repository looks like: $err" has "$err" "owner/name"
scan "$REPO" --since "2026-11-24T13:30:00"
check "a time with no time zone is refused, since reading it as UTC would move the window by hours: rc=$rc" [ "$rc" -eq 2 ]
check "and says a zone is needed: $err" has "$err" "time zone"
scan "$REPO" --since "last tuesday"
check "a time that is not a time is refused: rc=$rc" [ "$rc" -eq 2 ]
scan "$REPO" --since "2999-01-01T00:00:00Z"
check "a time still to come is refused, since nothing can have been posted since then: rc=$rc" [ "$rc" -eq 2 ]
check "none of those asked GitHub about the repository: $(gathered)" [ "$(gathered)" = "0" ]

# ================================================================ 2. the control goes first
# A scanner that reports nothing: the real library with its line scan emptied.
cat > "$WORK/blind.py" <<'PY'
import importlib.util, os
_spec = importlib.util.spec_from_file_location("real_work_names", os.environ["REAL_LIB"])
_real = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_real)
globals().update({k: v for k, v in vars(_real).items() if not k.startswith("__")})


def scan_text(text, shown, matcher, hits, odd=()):
    return
PY
fixture named
: > "$CALLS"
out="$(fixture_env REAL_LIB="$LIB" POSTED_TEXT_SCAN_LIB="$WORK/blind.py" python3 "$SCAN" "$REPO" --since "$SINCE" 2>&1)"; rc=$?
check "a scan that does not report the planted control stops, exit 2: rc=$rc" [ "$rc" -eq 2 ]
check "and says the scan cannot be trusted: $out" has "$out" "cannot be trusted"
check "and never says none were found: $out" lacks "$out" "none found"
check "and read nothing of the repository: $(gathered)" [ "$(gathered)" = "0" ]
# A scanner that reports every line: a control with no name in it must stay quiet.
sed 's/^    return$/    hits.extend("%s:%d: a work repository or owner name" % (shown, n) for n in range(1, len(text.splitlines()) + 1))/' \
  "$WORK/blind.py" > "$WORK/loud.py"
: > "$CALLS"
out="$(fixture_env REAL_LIB="$LIB" POSTED_TEXT_SCAN_LIB="$WORK/loud.py" python3 "$SCAN" "$REPO" --since "$SINCE" 2>&1)"; rc=$?
check "a scan that reports a line with no name in it stops too, exit 2: rc=$rc" [ "$rc" -eq 2 ]
check "and says the scan cannot be trusted: $out" has "$out" "cannot be trusted"
check "and read nothing of the repository: $(gathered)" [ "$(gathered)" = "0" ]
# The stand in library is a test setting: outside a test run it is never loaded.
: > "$CALLS"
out="$(fixture_env HOOK_TESTS_RUNNING=0 REAL_LIB="$LIB" POSTED_TEXT_SCAN_LIB="$WORK/blind.py" python3 "$SCAN" "$REPO" --since "$SINCE" 2>&1)"; rc=$?
check "outside a test run a library named in the environment is not loaded: $out" lacks "$out" "cannot be trusted"

# ================================================================ 3. what it reads and reports
fixture clean
scan "$REPO" --since "$SINCE"
check "a repository whose posted text names nothing is clean, exit 0: rc=$rc $err" [ "$rc" -eq 0 ]
check "it says the control was seen: $out" has "$out" "control:"
check "it says none were found: $out" has "$out" "none found"
check "it names the window it read: $out" has "$out" "$SINCE"
check "and gives it in Eastern time too: $out" has "$out" "1:30 PM ET"
check "it says what it did not read: $out" has "$out" "What this scan did not read"
check "edit history it could not read is said by its count: $out" has "$out" "1 earlier revision was deleted"
check "it says a release keeps no history: $out" has "$out" "release"
check "it says a commit pushed in the window but dated before it is missed: $out" has "$out" "pushed"
check "it counts what it read: $out" has "$out" "2 issues, 2 pull requests"
check "comments in the window are counted, the commit comment from before it is not: $out" has "$out" "2 comments, 1 review comment, 1 review, 1 commit comment"
check "a commit two branches and a pull request share is read once: $out" has "$out" "4 commit messages"
check "an empty review body is not a text: $out" lacks "$out" "2 reviews"

fixture named
scan "$REPO" --since "$SINCE"
K="a work repository or owner name"
U="https://github.com/$REPO"
check "names in what was posted exit 1: rc=$rc $err" [ "$rc" -eq 1 ]
check "an issue body, by its number and line" has_line "$out" "issue #11 body:3: $K"
check "an issue title" has_line "$out" "issue #12 title:1: $K"
check "a pull request body" has_line "$out" "pull request #21 body:2: $K"
check "a comment, by its address" has_line "$out" "comment $U/issues/11#issuecomment-501:1: $K"
check "a review comment" has_line "$out" "review comment $U/pull/21#discussion_r601:2: $K"
check "a review body" has_line "$out" "review $U/pull/21#pullrequestreview-701:1: $K"
check "a commit comment in the window" has_line "$out" "commit comment $U/commit/eeee#commitcomment-801:1: $K"
check "a commit comment from before the window is left out" lacks "$out" "commitcomment-802"
check "a commit message on a branch, by its line" has_line "$out" "commit eeeeeeeeee message:4: $K"
check "a commit only its pull request still holds" has_line "$out" "commit aaaaaaaaaa message:1: $K"
check "a branch name, shown by its tip and never by the name" has_line "$out" "branch name (tip dddddddddd):1: $K"
check "a release title" has_line "$out" "release 901 title:1: $K"
check "release notes" has_line "$out" "release 901 notes:2: $K"
check "the repository's description" has_line "$out" "repository description:1: $K"
check "an earlier revision of a body, by when it was written" has_line "$out" "issue #11 body, revision of 2026-11-24T19:00:00Z:2: $K"
check "an earlier title, by when it was changed" has_line "$out" "issue #11 title before 2026-11-24T19:05:00Z:1: $K"
check "the revision that is the body as it stands is not reported twice: $out" lacks "$out" "revision of 2026-11-24T21:00:00Z"
check "it counts the lines found: $out" has "$out" "15 lines"
check "it says to rewrite and that earlier revisions are deleted by hand: $out" has "$out" "by hand"
check "it says how many are in text as it stands and how many only in its history, since the remedy differs: $out" \
  has "$out" "13 in text as it stands, 1 in an earlier revision, 1 in an earlier title"
check "it never prints a name it found (the repository name)" lacks_any_case "$all" "acme-widgets"
check "it never prints a name it found (the product)" lacks_any_case "$all" "zephyr"
check "it never prints a name it found (the owner)" lacks_any_case "$all" "acme-corp"

# ================================================================ 4. a failure is never a short clean result
broken(){   # $1 = what the case is; the pages were already damaged
  scan "$REPO" --since "$SINCE"
  check "$1 is a failure, exit 2: rc=$rc" [ "$rc" -eq 2 ]
  check "$1 never reads as clean: $all" lacks "$all" "none found"
  check "$1 says the scan is not complete: $err" has "$err" "not a clean"
}
fixture clean
echo "gh: HTTP 502: Bad Gateway" > "$PAGES/$(key "repos/$REPO/issues/comments?since=$SINCE&per_page=100").fail"
broken "a failed call"
check "a failed call names what could not be read: $err" has "$err" "issues/comments"
fixture clean
printf '[[{"number": 11, "node_id"' > "$PAGES/$(key "repos/$REPO/issues?state=all&since=$SINCE&per_page=100")"
broken "a page cut short"
fixture clean
printf '{"message":"Not Found"}' > "$PAGES/$(key "repos/$REPO/pulls/comments?since=$SINCE&per_page=100")"
broken "an answer that is no list of pages"
fixture clean
printf '[[{"id": 501, "html_url": "x"}]]' > "$PAGES/$(key "repos/$REPO/issues/comments?since=$SINCE&per_page=100")"
broken "a comment with no body field"
fixture clean
rm -f "$PAGES/$(key "repos/$REPO/pulls/22/reviews?per_page=100")"
broken "one pull request's reviews unreadable"
fixture clean
echo "gh: HTTP 502: Bad Gateway" > "$PAGES/graphql.fail"
broken "the edit history unreadable"
fixture clean
python3 - "$PAGES/graphql" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["nodes"] = [n for n in d["data"]["nodes"] if n["id"] != "IC_502"]
json.dump(d, open(sys.argv[1], "w"))
PY
broken "an edit history that leaves one text out"
fixture clean
python3 - "$PAGES/graphql" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["nodes"][0]["userContentEdits"]["pageInfo"]["hasNextPage"] = True
json.dump(d, open(sys.argv[1], "w"))
PY
broken "an edit history longer than one answer holds"
check "and names the text whose history was cut: $err" has "$err" "issue #11"
fixture clean
python3 - "$PAGES/graphql" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["nodes"][0]["timelineItems"]["pageInfo"]["hasNextPage"] = True
json.dump(d, open(sys.argv[1], "w"))
PY
broken "a title history longer than one answer holds"
check "and names the issue whose titles were cut: $err" has "$err" "issue #11"
fixture clean
python3 - "$PAGES/graphql" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
del d["data"]["nodes"][0]["userContentEdits"]["pageInfo"]
json.dump(d, open(sys.argv[1], "w"))
PY
broken "an edit history that does not say whether it was cut short"
fixture clean
python3 - "$PAGES/graphql" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["data"]["nodes"][0]["userContentEdits"]["nodes"][1]["diff"] = None
json.dump(d, open(sys.argv[1], "w"))
PY
broken "a revision GitHub hands over with no text and no deletion"
# The other direction: a comment GitHub dates a moment ahead of this Mac's clock is a comment in the
# window, never a page that cannot be read. Only --since itself is refused for being still to come.
fixture clean
python3 - "$PAGES/$(key "repos/$REPO/comments?per_page=100")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[0][0]["updated_at"] = "2999-01-01T00:00:00Z"
json.dump(d, open(sys.argv[1], "w"))
PY
scan "$REPO" --since "$SINCE"
check "a commit comment dated ahead of this Mac's clock is read as in the window: rc=$rc $err" [ "$rc" -eq 0 ]
check "and is counted: $out" has "$out" "1 commit comment"
python3 - "$PAGES/$(key "repos/$REPO/comments?per_page=100")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d[0][0]["updated_at"] = "yesterday"
json.dump(d, open(sys.argv[1], "w"))
PY
broken "a commit comment whose time is not a time"
fixture named
echo "gh: HTTP 502: Bad Gateway" > "$PAGES/$(key "repos/$REPO/releases?per_page=100").fail"
scan "$REPO" --since "$SINCE"
check "a failure with names already found is still a failure, exit 2 and not 1: rc=$rc" [ "$rc" -eq 2 ]
# The time budget: a call that outlasts it is stopped, and the run says the budget was spent.
fixture clean
echo 30 > "$PAGES/$(key "repos/$REPO/branches?per_page=100").sleep"
started=$SECONDS
scan "$REPO" --since "$SINCE" --budget 3
check "a spent time budget is a failure, exit 2: rc=$rc" [ "$rc" -eq 2 ]
check "and says the budget was spent: $err" has "$err" "budget"
check "and never reads as clean: $all" lacks "$all" "none found"
check "and the run ended near its budget, not at the slow call's end: $((SECONDS - started))s" [ "$((SECONDS - started))" -lt 20 ]
scan "$REPO" --since "$SINCE" --budget soon
check "a budget that is not a number is refused: rc=$rc" [ "$rc" -eq 2 ]

# ================================================================ 5. it only reads
fixture named
scan "$REPO" --since "$SINCE"
check "no call was anything but a read the stand in knows: $(grep -c '^WRITE|' "$CALLS")" [ "$(grep -c '^WRITE|' "$CALLS")" = "0" ]
check "no call names a method, a field or an input file: $(grep -E -c -- ' (-X|--method|-F|--field|--input|--raw-field) ' "$CALLS")" \
  [ "$(grep -E -c -- ' (-X|--method|-F|--field|--input|--raw-field) ' "$CALLS")" = "0" ]
check "every GraphQL call is a query" [ "$(grep -c '^api graphql -f query=query' "$CALLS")" = "$(grep -c '^api graphql' "$CALLS")" ]
check "and at least one was made" [ "$(grep -c '^api graphql' "$CALLS")" -ge 1 ]
check "none is a mutation" [ "$(grep -c -i 'mutation' "$CALLS")" = "0" ]
# It loads the library by path, which must leave no bytecode in the installed lib/ (#2080). Judged
# on a copy of the three files in a folder of its own, so what else sits in the real lib/ cannot
# answer for it.
mkdir -p "$WORK/copy/lib"
cp "$SCAN" "$LIB" "$HERE/lib/dev-update-registry.js" "$WORK/copy/lib/"
: > "$CALLS"
out="$(fixture_env python3 "$WORK/copy/lib/posted-text-scan.py" "$REPO" --since "$SINCE" 2>&1)"; rc=$?
check "a copy of the command in a folder of its own runs the same: rc=$rc" [ "$rc" -eq 1 ]
check "and wrote no bytecode beside the library: $(ls "$WORK/copy/lib" | tr '\n' ' ')" [ "$(ls "$WORK/copy/lib" | wc -l | tr -d ' ')" = "3" ]

# ================================================================ 6. the gates let a session run it
# The Slack drafts gate refused the scan a session wrote on 2026-11-24: that one handed a file of
# gathered text to a script that can run programs, and one gathered text named a Slack endpoint.
# This command is handed no file, so the gate has nothing of the repository's to read.
SLACK="$HERE/slack-drafts-only-gate.sh"
PUBLISH="$HERE/check-work-names-publish.sh"
export SLACK_GATE_CACHE_DIR="$WORK/gate-cache"
unset SLACK_GATE_CACHE_TRACE SLACK_GATE_UNWORKED_PATHS
payload(){ jq -nc --arg c "$1" --arg d "$WORK" '{session_id:"f6017250-8f33-47ac-bbb2-b82a7c319d0d",transcript_path:"/tmp/transcript.jsonl",cwd:$d,permission_mode:"auto",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c,description:"d"},tool_use_id:"toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}'; }
slack(){ gout="$(payload "$1" | bash "$SLACK" 2>&1)"; grc=$?; }
if [ -f "$SLACK" ]; then
  slack "python3 $SCAN $REPO --since $SINCE"
  check "the Slack drafts gate lets a session run the command: rc=$grc ${gout:0:300}" [ "$grc" -eq 0 ]
  slack "python3 $SCAN $REPO --since $SINCE > $WORK/scan.txt 2>&1"
  check "and with its report sent to a file: rc=$grc ${gout:0:300}" [ "$grc" -eq 0 ]
  # The control: the shape that was refused that day still is, so the two checks above can fail.
  printf '%s\n' 'import subprocess, sys' 'print(open(sys.argv[1]).read()[:10])' > "$WORK/handrolled.py"
  printf 'issue 1\0see https://%s.%s.com/services/T0 for it\0' hooks slack > "$WORK/texts.bin"
  slack "python3 $WORK/handrolled.py $WORK/texts.bin"
  check "(control) a script that can run programs, handed gathered text naming a Slack endpoint, is still refused: rc=$grc" [ "$grc" -eq 2 ]
else
  check "slack-drafts-only-gate.sh is beside this suite" false
fi
if [ -f "$PUBLISH" ]; then
  : > "$CALLS"
  gout="$(cd "$WORK" && payload "python3 $SCAN $REPO --since $SINCE" | fixture_env bash "$PUBLISH" 2>&1)"; grc=$?
  check "the publish gate's command hook lets a session run the command: rc=$grc ${gout:0:300}" [ "$grc" -eq 0 ]
  check "and decides nothing about it: ${gout:0:300}" [ -z "$(printf '%s' "$gout" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" ]
else
  check "check-work-names-publish.sh is beside this suite" false
fi
# The guard on gh, which every gh a script runs meets first: the command's own calls pass it.
fixture clean
: > "$CALLS"
out="$(fixture_env PATH="$HERE/bin:$BIN:$PATH" python3 "$SCAN" "$REPO" --since "$SINCE" 2>&1)"; rc=$?
check "with the guard on gh first on the PATH the scan still runs clean: rc=$rc ${out:0:400}" [ "$rc" -eq 0 ]

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
