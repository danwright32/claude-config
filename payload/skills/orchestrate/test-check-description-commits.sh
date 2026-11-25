#!/usr/bin/env bash
# Tests for check-description-commits.sh, and for the orchestrate wording around it
# (claude-config#3579).
#
# On 2026-11-24 a pull request description carried a prompt for a count on the work MacBook that
# named a commit from before a fix round, and said later commits changed no rule, after two rules had
# changed. A fix round appends a "## The review" section and nothing rereads the rest. The script
# reads a pull request's description and head and says, for every commit id the description names,
# whether it is the head, a commit the branch was cut from (its base side), an earlier commit of this
# branch, or none of these. A fenced block that names the head or an earlier commit of this branch is
# a prompt handed to another session, so one naming anything but the head and its base side, or
# naming no head at all, fails; a fence naming no commit of this branch is pasted output, reported.
#
# A stand in gh on PATH answers from fixtures this suite writes, so no test reaches GitHub. It answers
# `pr view` with the JSON the real gh prints for --json, and `api repos/<r>/compare/<a>...<b>` with the
# body GitHub's compare endpoint returns (a 404 prints its JSON on stdout, "gh: Not Found (HTTP 404)"
# on stderr and exits 1, as the real gh was measured to on 2026-11-25).
#
# CHECK_DESCRIPTION_SCRIPT, ORCHESTRATE_SKILL and ORCHESTRATE_AGENT_RULES point the suite at other
# copies, which is how a broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${CHECK_DESCRIPTION_SCRIPT:-$DIR/check-description-commits.sh}"
SKILL="${ORCHESTRATE_SKILL:-$DIR/SKILL.md}"
RULES="${ORCHESTRATE_AGENT_RULES:-$DIR/agent-rules.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; [ -n "${2:-}" ] && printf '  output: %s\n' "$2"; return 0; }
has() { # has <description> <expected substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else bad "$1 (no '$2')" "$3"; fi
}
lacks() { # lacks <description> <forbidden substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (holds '$2')" "$3"; fi
}
holds() { # holds <description> <expected substring> <file text>   never prints the text, which is long
  if [[ "$3" == *"$2"* ]]; then ok; else bad "$1 (no '$2')"; fi
}
is() { # is <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')" "${4:-}"; fi
}

# ---- the stand in gh ----
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers from the fixture folder $FAKE, and records every call in $FAKE/calls.
printf '%s\n' "$*" >>"$FAKE/calls"
case "$1 $2" in
  "pr view")
    [ -e "$FAKE/fail_pr" ] && { echo "gh: HTTP 502 simulated" >&2; exit 1; }
    cat "$FAKE/pr.json"
    exit 0 ;;
  "api "*)
    spec="${2##*/compare/}"
    left="${spec%%...*}"
    right="${spec#*...}"
    [ -e "$FAKE/fail_api" ] && { echo "gh: Server Error (HTTP 502)" >&2; exit 1; }
    f="$FAKE/cmp/$left@$right"
    if [ -e "$f" ]; then cat "$f"; exit 0; fi
    echo '{"message":"Not Found","status":"404"}'
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1 ;;
esac
echo "stand in gh: unexpected call: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

REPO="owner/repo"
BASE=b0b0aaaa00000000000000000000000000000001
OLD=a1d0aaaa00000000000000000000000000000002
HEAD=feedaaaa00000000000000000000000000000003
GONE=d1ffaaaa00000000000000000000000000000004
MAINTIP=c0c0aaaa00000000000000000000000000000005

FAKE=""
new_case() {
  FAKE="$TMP/case.$RANDOM$RANDOM"
  mkdir -p "$FAKE/cmp"
  # The merge base of main and the head is BASE.
  printf '{"status":"diverged","ahead_by":2,"behind_by":3,"merge_base_commit":{"sha":"%s"},"files":[]}\n' "$BASE" >"$FAKE/cmp/main@$HEAD"
}
# cmp <left as written> <right> <status> <ahead_by> [file ...]
cmp() {
  local left="$1" right="$2" status="$3" ahead="$4"
  shift 4
  local files="" f
  for f in "$@"; do files="$files${files:+,}{\"filename\":\"$f\"}"; done
  printf '{"status":"%s","ahead_by":%s,"behind_by":0,"merge_base_commit":{"sha":"x"},"files":[%s]}\n' \
    "$status" "$ahead" "$files" >"$FAKE/cmp/$left@$right"
}
# The usual answers: the head is itself, the base is behind it and inside the merge base, and the
# earlier commit of the branch is behind the head but not inside the merge base.
usual() {
  cmp "$HEAD" "$HEAD" identical 0
  cmp "$BASE" "$HEAD" ahead 5 payload/a.ts docs/b.md
  cmp "$BASE" "$BASE" identical 0
  cmp "$OLD" "$HEAD" ahead 2 payload/mods/x/hooks/rule.ts docs/b.md
  cmp "$OLD" "$BASE" behind 0
  cmp "a1d0aaaa00" "$HEAD" ahead 2 payload/mods/x/hooks/rule.ts
  cmp "a1d0aaaa00" "$BASE" behind 0
  cmp "feedaaaa00" "$HEAD" identical 0
  cmp "$GONE" "$HEAD" diverged 1
}
# body <markdown file>: writes pr.json carrying it as the description.
body() {
  python3 -c 'import json,sys; print(json.dumps({"body": open(sys.argv[1]).read(), "headRefOid": sys.argv[2], "baseRefName": "main"}))' \
    "$1" "$HEAD" >"$FAKE/pr.json"
}
out=""
code=0
run() {
  out="$(PATH="$TMP/bin:$PATH" FAKE="$FAKE" bash "$SCRIPT" "$@" 2>&1)"
  code=$?
}

FENCE='```'

# ---- 1. the prompt names the head and its base: passes ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
## For Dan

The prompt for the count:

$FENCE
Read code only from two commits: the base $BASE and the change $HEAD.
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "a prompt naming the head and its base: exit 0" 0 "$code" "$out"
has "the head is named as the head" "$HEAD" "$out"
has "the head is said to be the head" "the head" "$out"
has "the base is said to be on the base side" "base" "$out"

# ---- 2. the prompt names an earlier commit of the branch (the 2026-11-24 case): fails ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
$FENCE
Use exactly these two even if the branch has moved since: the base $BASE and the change $OLD.
Later commits change no rule.
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "a prompt naming an earlier commit of the branch: exit 1" 1 "$code" "$out"
has "the stale id is named" "$OLD" "$out"
has "it is called an earlier commit of this branch" "earlier commit of this branch" "$out"
has "the commits since are counted" "2 commits" "$out"
has "the files changed since are listed, so a claim like 'no rule changed' can be checked" "payload/mods/x/hooks/rule.ts" "$out"
has "the head the prompt should name is given" "$HEAD" "$out"
has "a prompt with no head is said to name no head" "does not name the head" "$out"

# ---- 3. the same with an abbreviated id ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
$FENCE
Count on a1d0aaaa00 against the base $BASE.
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "a prompt naming an abbreviated earlier commit: exit 1" 1 "$code" "$out"
has "the abbreviated id is named" "a1d0aaaa00" "$out"

# ---- 4. prose naming an earlier commit is reported, never failed ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
## The review

An independent review of a1d0aaaa00 recommended sign off.

$FENCE
The change feedaaaa00, the base $BASE.
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "an earlier commit named in prose only, the prompt on the head: exit 0" 0 "$code" "$out"
has "the prose id is still reported" "a1d0aaaa00" "$out"

# ---- 5. the prompt names a commit outside the head's history ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
$FENCE
The change $HEAD, and also $GONE.
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "a prompt naming a commit outside the head's history: exit 1" 1 "$code" "$out"
has "it is said to be outside the head's history" "not in the head's history" "$out"

# ---- 6. a hex word that is no commit fails in a prompt; a bare number is not a commit id ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
$FENCE
The change $HEAD. Counted 19292831 records. Then abc1234def.
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "a prompt naming a hex id that is no commit: exit 1" 1 "$code" "$out"
has "the id that is no commit is named" "abc1234def" "$out"
has "it is said to be no commit" "no commit" "$out"
lacks "a number of digits alone is not reported as a commit" "19292831:" "$out"

# ---- 7. pasted output in a fence naming no commit of this branch is not a prompt ----
# The shape of a real description seen on 2026-11-25: fenced test output naming the base and a commit
# outside the head's history.
new_case
usual
cat >"$FAKE/body.md" <<EOF
$FENCE
FAIL  test-x.sh   205 passed, 9 failed   on $BASE, as on $GONE
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "a fence naming only the base and an outside commit is no prompt: exit 3" 3 "$code" "$out"
has "its ids are still reported" "$GONE" "$out"
lacks "it raises no problem" "PROBLEMS" "$out"

# ---- 8. no fenced block names a commit: exit 3, said plainly, never a pass ----
new_case
usual
cat >"$FAKE/body.md" <<EOF
## What changed

Built on $BASE.
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "no fenced block naming a commit: exit 3" 3 "$code" "$out"
has "it says no prompt was found" "No fenced block" "$out"

# ---- 9. a failed read is never a pass ----
new_case
usual
touch "$FAKE/fail_pr"
cat >"$FAKE/body.md" <<EOF
$FENCE
$HEAD
$FENCE
EOF
body "$FAKE/body.md"
run "$REPO" 12
is "the pull request could not be read: exit 2" 2 "$code" "$out"

new_case
usual
cat >"$FAKE/body.md" <<EOF
$FENCE
$HEAD and $BASE
$FENCE
EOF
body "$FAKE/body.md"
touch "$FAKE/fail_api"
run "$REPO" 12
is "a compare that errors (not a 404): exit 2" 2 "$code" "$out"
has "it says it could not check" "Could not check" "$out"

# ---- 10. bad arguments ----
new_case
run "$REPO"
is "no pull request number: exit 2" 2 "$code" "$out"
run "$REPO" twelve
is "a pull request number that is not a number: exit 2" 2 "$code" "$out"

# ---- 11. the wording that sends sessions to it ----
skill_step5="$(awk '/^## 5\. When an agent reports/{on=1; next} on && /^#+ /{exit} on{print}' "$SKILL" 2>/dev/null)"
holds "SKILL.md step 5 names the script" "check-description-commits.sh" "$skill_step5"
holds "SKILL.md step 5 says the description is checked against the new head after a fix round" "every commit, count and claim the description states is checked against the new head" "$skill_step5"
holds "SKILL.md step 5 says the count prompt names the new head" "count prompt names the new head" "$skill_step5"
holds "SKILL.md step 5 runs it before a sign off question" "sign off question" "$skill_step5"
rules_text="$(cat "$RULES" 2>/dev/null)"
holds "agent-rules.md gives the builder's side of a fix round" "every commit, count and claim the description states is checked against the new head" "$rules_text"
holds "agent-rules.md says the count prompt names the new head" "count prompt names the new head" "$rules_text"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
