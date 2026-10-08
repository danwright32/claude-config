#!/usr/bin/env bash
# Suite for post-discussion.sh: every place a plan can land is a complete, honest one (claude-config#677).
#
# Three defects, each with its failure path here:
#   - the fallback issue was filed with no priority and no category, and with no milestone at all
#     when the plan's own did not exist yet, because the issue field gate only sees commands typed
#     in a session and never this script's;
#   - the last fallback wrote PLAN-<slug>.md into whatever folder the script happened to run from;
#   - a failure to write that file still printed FILE as though the plan had landed.
#
# GitHub is a stand in `gh` on PATH that records every call and answers from fixtures, so no case
# can reach the network or a real repository (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POST="$DIR/post-discussion.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/post-discussion.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Its physical path, the one git reports for a project inside it (/var is a link on macOS).
TMP="$(cd "$TMP" && pwd -P)"

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /' | awk 'NR <= 30'; return 0; }
has() { grep -qF -- "$2" <<< "$1"; }

mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Records the call, then answers from fixtures the test controls.
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1 $2" in
  "api graphql")
    case "$*" in
      *createDiscussion*) echo '{"data":{"createDiscussion":{"discussion":{"url":"https://github.com/acme/widgets/discussions/5"}}}}' ;;
      *) if [ "${FAKE_DISCUSSIONS:-off}" = on ]; then
           echo '{"data":{"repository":{"id":"R1","hasDiscussionsEnabled":true,"discussionCategories":{"nodes":[{"id":"C1","name":"Ideas"}]}}}}'
         else
           echo '{"data":{"repository":{"id":"R1","hasDiscussionsEnabled":false,"discussionCategories":{"nodes":[]}}}}'
         fi ;;
    esac
    exit 0 ;;
  "api --paginate")
    [ -n "${FAKE_MILESTONES_FAIL:-}" ] && { echo "gh: HTTP 502 reading milestones" >&2; exit 1; }
    cat "$FAKE_MILESTONES"; exit 0 ;;
  "label list")
    [ -n "${FAKE_LABELS_FAIL:-}" ] && { echo "gh: HTTP 403 reading labels" >&2; exit 1; }
    cat "$FAKE_LABELS"; exit 0 ;;
  "label create") exit 0 ;;
  "issue create")
    printf '%s\n' "$@" > "$GH_ISSUE_ARGS"
    [ -n "${FAKE_ISSUE_FAIL:-}" ] && { echo "gh: issues are disabled for this repository" >&2; exit 1; }
    echo "https://github.com/acme/widgets/issues/77"; exit 0 ;;
esac
case "$*" in
  "api repos/acme/widgets/milestones -f title=Ungrouped"*)
    echo '{"number":12,"title":"Ungrouped","state":"open","html_url":"https://github.com/acme/widgets/milestone/12"}'; exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

cat > "$TMP/milestones.json" <<'JSON'
[ { "number": 9, "title": "Search relevance", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/9" } ]
JSON
cat > "$TMP/milestones-with-pen.json" <<'JSON'
[ { "number": 9, "title": "Search relevance", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/9" },
  { "number": 12, "title": "Ungrouped", "state": "open", "html_url": "https://github.com/acme/widgets/milestone/12" } ]
JSON
LEVELS='{"name":"priority-p0"},{"name":"priority-p1"},{"name":"priority-p2"},{"name":"priority-p3"},{"name":"priority-p4"}'
printf '[%s,{"name":"planning"}]\n' "$LEVELS" > "$TMP/labels.json"
printf '[%s]\n' "$LEVELS" > "$TMP/labels-no-planning.json"
printf '# Plan\n\nThe body of the plan.\n' > "$TMP/body.md"

# A project to run from, with the script started in a folder BELOW its root.
mkdir -p "$TMP/project/src/deep"
git -C "$TMP/project" init -q
export GH_CALLS="$TMP/gh-calls" GH_ISSUE_ARGS="$TMP/issue-args"

post() { # post <cwd> <args...>: runs the script with the fake gh, fresh logs each time
  local where="$1"; shift
  : > "$GH_CALLS"; : > "$GH_ISSUE_ARGS"
  out="$(cd "$where" && PATH="$TMP/bin:$PATH" bash "$POST" "$@" 2>"$TMP/err")"; rc=$?
  err="$(cat "$TMP/err")"
  calls="$(cat "$GH_CALLS")"
  issue="$(cat "$GH_ISSUE_ARGS")"
}
export FAKE_MILESTONES="$TMP/milestones.json" FAKE_LABELS="$TMP/labels.json"

# --- a Discussion, when the repository has them ----------------------------------------------
FAKE_DISCUSSIONS=on post "$TMP/project" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
[ "$rc" -eq 0 ] && has "$out" "DISCUSSION https://github.com/acme/widgets/discussions/5" && ok \
  || bad "with Discussions on, the plan becomes a Discussion (rc=$rc)" "$out $err"
has "$calls" "issue create" && bad "and no issue is filed" "$calls" || ok

# --- the fallback issue carries a priority, a category and the plan's milestone -------------------
post "$TMP/project" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
[ "$rc" -eq 0 ] && has "$out" "ISSUE https://github.com/acme/widgets/issues/77" && ok \
  || bad "with Discussions off, the plan becomes an issue (rc=$rc)" "$out $err"
has "$issue" "priority-p2" && ok || bad "the issue carries a priority label" "$issue"
has "$issue" "planning" && ok || bad "the issue carries a category label" "$issue"
grep -qx -- "--milestone" <<< "$issue" && grep -qx "Search relevance" <<< "$issue" && ok \
  || bad "the issue is in the plan's existing milestone" "$issue"
has "$out" "MILESTONE-PENDING" && bad "and nothing is left pending when the milestone exists" "$out" || ok

# --- the plan's milestone does not exist yet: the issue waits in the catch-all, never in none ----
post "$TMP/project" acme/widgets "Search plan" "$TMP/body.md" "Saved views"
[ "$rc" -eq 0 ] && has "$out" "ISSUE https://github.com/acme/widgets/issues/77" && ok \
  || bad "an issue is still filed when the plan's milestone is not there yet (rc=$rc)" "$out $err"
grep -qx "Ungrouped" <<< "$issue" && ok || bad "it goes in the catch-all milestone, never in none" "$issue"
has "$calls" "api repos/acme/widgets/milestones -f title=Ungrouped" && ok \
  || bad "the catch-all is created when the repository has none" "$calls"
has "$out" "MILESTONE-PENDING https://github.com/acme/widgets/issues/77" && has "$out" '--milestone "Saved views"' && ok \
  || bad "and the output names the move to make once the plan's milestone exists" "$out"

FAKE_MILESTONES="$TMP/milestones-with-pen.json" post "$TMP/project" acme/widgets "Search plan" "$TMP/body.md"
grep -qx "Ungrouped" <<< "$issue" && ok || bad "with no milestone asked for, the issue goes in the catch-all" "$issue"
has "$calls" "-f title=Ungrouped" && bad "an existing catch-all is reused, not created again" "$calls" || ok
has "$out" "MILESTONE-PENDING" && bad "and no move is pending when the plan named no milestone" "$out" || ok

# --- a category label the repository lacks is created first ------------------------------------
FAKE_LABELS="$TMP/labels-no-planning.json" post "$TMP/project" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
has "$calls" "label create planning" && ok || bad "the planning label is created when missing" "$calls"
post "$TMP/project" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
has "$calls" "label create planning" && bad "and left alone when present" "$calls" || ok

# --- an issue that cannot carry its fields is not filed bare: the plan goes to a file instead ----
FAKE_LABELS_FAIL=1 post "$TMP/project/src/deep" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
has "$calls" "issue create" && bad "labels that cannot be read stop the issue being filed without them" "$calls" || ok
has "$err" "403 reading labels" && ok || bad "and the reason is said" "$err"
has "$out" "FILE $TMP/project/PLAN-search-plan.md" && ok || bad "and the plan lands in a file at the project root" "$out $err"
rm -f "$TMP/project/PLAN-search-plan.md"
FAKE_MILESTONES_FAIL=1 post "$TMP/project/src/deep" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
has "$calls" "issue create" && bad "a milestone list that cannot be read stops the issue being filed without one" "$calls" || ok
has "$err" "502 reading milestones" && ok || bad "and the reason is said" "$err"
rm -f "$TMP/project/PLAN-search-plan.md"

# --- the last fallback writes at the project root, never the folder it ran from --------------------
FAKE_ISSUE_FAIL=1 post "$TMP/project/src/deep" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
[ "$rc" -eq 0 ] && has "$out" "FILE $TMP/project/PLAN-search-plan.md" && ok \
  || bad "a failed issue falls back to PLAN-<slug>.md at the project root (rc=$rc)" "$out $err"
[ -f "$TMP/project/PLAN-search-plan.md" ] && has "$(cat "$TMP/project/PLAN-search-plan.md")" "The body of the plan." && ok \
  || bad "and the file holds the plan"
[ -e "$TMP/project/src/deep/PLAN-search-plan.md" ] && bad "and nothing is written where it happened to run" || ok
has "$err" "issues are disabled" && ok || bad "and why the issue failed is said" "$err"

# --- a file that cannot be written is a failure, never FILE ---------------------------------------
rm -f "$TMP/project/PLAN-search-plan.md"
mkdir "$TMP/project/PLAN-search-plan.md"
FAKE_ISSUE_FAIL=1 post "$TMP/project/src/deep" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
[ "$rc" -ne 0 ] && ok || bad "a plan file that could not be written fails (rc=$rc)" "$out $err"
has "$out" "FILE " && bad "and does not claim the plan landed" "$out" || ok
has "$err" "$TMP/body.md" && ok || bad "and says where the plan still is" "$err"
rmdir "$TMP/project/PLAN-search-plan.md"

# --- outside any project there is no root to write to: refused by name ----------------------------
mkdir -p "$TMP/loose"
FAKE_ISSUE_FAIL=1 post "$TMP/loose" acme/widgets "Search plan" "$TMP/body.md" "Search relevance"
[ "$rc" -ne 0 ] && has "$err" "not inside a git checkout" && has "$err" "$TMP/body.md" && ok \
  || bad "with no project root it fails, naming where the plan still is (rc=$rc)" "$out $err"
[ -e "$TMP/loose/PLAN-search-plan.md" ] && bad "and writes nothing into the folder it ran from" || ok

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
