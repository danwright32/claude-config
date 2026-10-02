#!/usr/bin/env bash
# Tests for lib/lesson-fanout.sh: one "sweep this project for the defect" issue per digest repo
# for each new lesson.
#
# Every seam the script has is set here, so nothing reaches a real service (L2, L284):
#   gh                         a fake first on PATH, asserted below before anything runs
#   LESSON_FANOUT_SYNC_TOOL    a fake claude-sync answering `lesson Lnnn` from fixtures
#   LESSON_FANOUT_HELPERS_DIR  fake ensure-priority-labels.sh and ensure-milestone.sh
#   CLAUDE_HOME                a temp dir, so the ledger it writes is this suite's own
# The fake gh records every call with the token it was given, so the tests can assert which
# account each write went out as and that no write happened on the paths that must refuse.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/lib/lesson-fanout.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"; echo "  expected to contain: $2"; echo "  actual: $3"; fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (should not contain '$2')"; echo "  actual: $3"; fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (expected '$2', got '$3')"; fi
}

# ---- the fakes ----
mkdir -p "$TMP/bin" "$TMP/helpers"
cat >"$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Answers from files under $FAKE; records "<token> <args>" for every call.
printf '%s %s\n' "${GH_TOKEN:-<none>}" "$*" >>"$FAKE/calls"
key(){ printf '%s' "$1" | tr '/' '_'; }
case "$1 $2" in
  "auth status")
    [ -f "$FAKE/auth.json" ] && cat "$FAKE/auth.json" || echo '{"hosts":{}}'
    exit 0 ;;
  "auth token")
    login=""; prev=""
    for a in "$@"; do [ "$prev" = "-u" ] && login="$a"; prev="$a"; done
    [ -f "$FAKE/notoken-$login" ] && { echo "no token for $login" >&2; exit 1; }
    printf 'tok-%s\n' "$login"; exit 0 ;;
  "issue list")
    repo=""; prev=""
    for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
    [ -f "$FAKE/listfail-$(key "$repo")" ] && { echo "gh: simulated list failure" >&2; exit 1; }
    f="$FAKE/issues-$(key "$repo").json"
    [ -f "$f" ] && cat "$f" || echo '[]'
    exit 0 ;;
  "issue create")
    repo=""; prev=""; body=""
    for a in "$@"; do
      [ "$prev" = "--repo" ] && repo="$a"
      [ "$prev" = "--body-file" ] && body="$a"
      prev="$a"
    done
    [ -f "$FAKE/createfail-$(key "$repo")" ] && { echo "gh: simulated create failure" >&2; exit 1; }
    printf '%s\n' "$*" >>"$FAKE/created"
    [ -n "$body" ] && cat "$body" >>"$FAKE/bodies"
    echo "https://github.com/$repo/issues/77"; exit 0 ;;
  "label create")
    exit 0 ;;
esac
if [ "$1" = "api" ]; then
  path=""
  for a in "$@"; do case "$a" in repos/*) path="$a" ;; esac; done
  case "$path" in
    repos/dwright-pennie/repo-digest/contents/*)
      f="$FAKE/digest/${path##*/}"
      [ -f "$f" ] && { cat "$f"; exit 0; }
      echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
    repos/*)
      r="${path#repos/}"
      if [ -f "$FAKE/push/${GH_TOKEN:-none}/$(key "$r")" ]; then
        echo '{"permissions":{"push":true}}'
      else
        echo '{"permissions":{"push":false}}'
      fi
      exit 0 ;;
  esac
fi
echo "fake gh: unhandled call: $*" >&2
exit 1
STUB
chmod +x "$TMP/bin/gh"

cat >"$TMP/bin/claude-sync" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "lesson" ] || { echo "fake claude-sync: unhandled $*" >&2; exit 2; }
f="$FAKE/lessons/$2.txt"
[ -f "$f" ] || { echo "claude-sync: $2 is not in LESSONS.md" >&2; exit 1; }
cat "$f"
STUB
chmod +x "$TMP/bin/claude-sync"

for h in ensure-priority-labels.sh ensure-milestone.sh; do
  cat >"$TMP/helpers/$h" <<STUB
#!/usr/bin/env bash
printf '%s %s %s\n' "\${GH_TOKEN:-<none>}" "$h" "\$*" >>"\$FAKE/calls"
[ -f "\$FAKE/helperfail-$h" ] && { echo "$h: simulated failure" >&2; exit 6; }
echo "OK"
STUB
  chmod +x "$TMP/helpers/$h"
done

export PATH="$TMP/bin:$PATH"
export LESSON_FANOUT_SYNC_TOOL="$TMP/bin/claude-sync"
export LESSON_FANOUT_HELPERS_DIR="$TMP/helpers"
unset GH_TOKEN GITHUB_TOKEN CLAUDE_DETACHED_RUN

# The structural guard: if the fake is not the gh this suite will run, stop before anything does.
if [ "$(command -v gh)" != "$TMP/bin/gh" ]; then
  echo "FAIL: the fake gh is not first on PATH, refusing to run against a real GitHub"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

# ---- fixtures ----
# A fresh world per case: two signed in accounts, one daily and one weekly list, three repos.
reset_world() {
  export FAKE="$TMP/fake-$1"
  export CLAUDE_HOME="$TMP/home-$1"
  rm -rf "$FAKE" "$CLAUDE_HOME"
  mkdir -p "$FAKE/digest" "$FAKE/lessons" "$FAKE/push/tok-work" "$FAKE/push/tok-personal" "$CLAUDE_HOME/state"
  : >"$FAKE/calls"
  cat >"$FAKE/auth.json" <<'JSON'
{"hosts":{"github.com":[
  {"login":"work","active":true,"state":"success"},
  {"login":"personal","active":false,"state":"success"}
]}}
JSON
  cat >"$FAKE/digest/repos.json" <<'JSON'
{"repos":[{"owner":"Try-Pennie","name":"bidspoke","label":"bidspoke"},
          {"owner":"Try-Pennie","name":"slate","label":"slate"}]}
JSON
  cat >"$FAKE/digest/repos-weekly.json" <<'JSON'
{"repos":[{"owner":"danwright32","name":"overture","label":"overture"}]}
JSON
  touch "$FAKE/push/tok-work/Try-Pennie_bidspoke" "$FAKE/push/tok-work/Try-Pennie_slate" \
        "$FAKE/push/tok-personal/danwright32_overture"
  cat >"$FAKE/lessons/L900.txt" <<'TXT'
id: abc1234567 (this survives a renumber; L900 may not)
- **L900. A partitioned query bounded by the clock locks every
  partition, so pass literal bounds.** More explanation of the rule.
  (bidspoke#1720, 2026-10-02: SECRET-EVIDENCE refresh_field_presence_daily held 430 locks.)
  SHORT: A clock bounded partitioned query locks every partition; pass literal bounds.
TXT
  cat >"$FAKE/lessons/L901.txt" <<'TXT'
id: def7654321 (this survives a renumber; L901 may not)
- **L901. Short rule with no short form.** Why it matters.
  (claude-config#5, 2026-10-02: evidence.)
TXT
}

run() { out="$(bash "$SCRIPT" "$@" 2>&1)"; rc=$?; }

# ---- 1. happy path ----
reset_world happy
run L900
check_eq "happy: exits 0 when every repo is covered" "0" "$rc"
created="$(cat "$FAKE/created" 2>/dev/null)"
check "happy: files in slate" "--repo Try-Pennie/slate" "$created"
check "happy: files in overture" "--repo danwright32/overture" "$created"
check_not "happy: never files in the repo the lesson came from" "Try-Pennie/bidspoke" "$created"
check "happy: says it skipped the source repo" "Try-Pennie/bidspoke" "$out"
check "happy: title names the lesson and uses the short form" \
  "Lesson L900 sweep: A clock bounded partitioned query locks every partition; pass literal bounds." "$created"
check "happy: priority and category labels" "priority-p2,lesson-sweep" "$created"
check "happy: catch-all milestone" "--milestone Ungrouped" "$created"
calls="$(cat "$FAKE/calls")"
check "happy: slate is written as the account that can push to it" "tok-work issue create --repo Try-Pennie/slate" "$calls"
check "happy: overture is written as the account that can push to it" "tok-personal issue create --repo danwright32/overture" "$calls"
check "happy: priority labels ensured per repo" "tok-personal ensure-priority-labels.sh danwright32/overture" "$calls"
check "happy: milestone ensured per repo" "tok-work ensure-milestone.sh Try-Pennie/slate Ungrouped" "$calls"
bodies="$(cat "$FAKE/bodies")"
check "happy: body carries the rule sentence, whitespace collapsed" \
  "A partitioned query bounded by the clock locks every partition, so pass literal bounds." "$bodies"
check "happy: body carries the stable id marker" "<!-- lesson-id: abc1234567 -->" "$bodies"
check_not "happy: body never carries the evidence (public repos)" "SECRET-EVIDENCE" "$bodies"
check_not "happy: body never names the source repo (public repos)" "bidspoke" "$bodies"
check "happy: ledger records the lesson as fanned out" "L900 abc1234567" "$(cat "$CLAUDE_HOME/state/lesson-fanout.done" 2>/dev/null)"

# ---- 2. without a short form the rule is the title ----
reset_world noshort
run L901
check_eq "noshort: exits 0" "0" "$rc"
check "noshort: title uses the rule" "Lesson L901 sweep: Short rule with no short form." "$(cat "$FAKE/created")"
check "noshort: a non digest source excludes nothing" "--repo Try-Pennie/bidspoke" "$(cat "$FAKE/created")"

# ---- 3. a rerun files nothing twice: matched by number ----
reset_world rerun
echo '[{"number":5,"title":"Lesson L900 sweep: older wording","body":"x"}]' >"$FAKE/issues-Try-Pennie_slate.json"
run L900
check_eq "rerun: exits 0" "0" "$rc"
check_not "rerun: no second issue in slate" "Try-Pennie/slate" "$(cat "$FAKE/created")"
check "rerun: still files where it is missing" "danwright32/overture" "$(cat "$FAKE/created")"
check "rerun: names the existing issue" "Try-Pennie/slate#5" "$out"

# ---- 4. a renumbered lesson is matched by id ----
reset_world renum
echo '[{"number":9,"title":"Lesson L612 sweep: same rule","body":"text\n<!-- lesson-id: abc1234567 -->"}]' >"$FAKE/issues-danwright32_overture.json"
run L900
check_eq "renum: exits 0" "0" "$rc"
check_not "renum: no second issue in overture" "danwright32/overture" "$(cat "$FAKE/created")"

# ---- 5. a number that only shares a prefix is not a match ----
reset_world prefix
echo '[{"number":3,"title":"Lesson L9001 sweep: other","body":"<!-- lesson-id: zzz -->"}]' >"$FAKE/issues-Try-Pennie_slate.json"
run L900
check "prefix: L9001 does not count as L900" "--repo Try-Pennie/slate" "$(cat "$FAKE/created")"

# ---- 6. a repo no signed in account can write to ----
reset_world noaccess
rm "$FAKE/push/tok-personal/danwright32_overture"
run L900
check_eq "noaccess: exits nonzero" "1" "$rc"
check "noaccess: names the repo it could not reach" "danwright32/overture" "$out"
check "noaccess: says why" "no signed in account can write" "$out"
check "noaccess: still files the others" "Try-Pennie/slate" "$(cat "$FAKE/created")"
check_eq "noaccess: ledger not written, so it is offered again" "" "$(cat "$CLAUDE_HOME/state/lesson-fanout.done" 2>/dev/null)"

# ---- 7. an unreadable existing issue list never creates blind ----
reset_world listfail
touch "$FAKE/listfail-Try-Pennie_slate"
run L900
check_eq "listfail: exits nonzero" "1" "$rc"
check_not "listfail: nothing created where the list could not be read" "Try-Pennie/slate" "$(cat "$FAKE/created")"
check "listfail: names it" "Try-Pennie/slate" "$out"

# ---- 8. a failing create is reported ----
reset_world createfail
touch "$FAKE/createfail-danwright32_overture"
run L900
check_eq "createfail: exits nonzero" "1" "$rc"
check "createfail: carries gh's own words" "simulated create failure" "$out"

# ---- 9. a failing helper stops that repo ----
reset_world helperfail
touch "$FAKE/helperfail-ensure-milestone.sh"
run L900
check_eq "helperfail: exits nonzero" "1" "$rc"
check_eq "helperfail: nothing created without a milestone" "" "$(cat "$FAKE/created" 2>/dev/null)"

# ---- 10. repo-digest unreadable ----
reset_world nodigest
rm "$FAKE/digest/repos-weekly.json"
run L900
check_eq "nodigest: exits nonzero" "1" "$rc"
check "nodigest: says which list it could not read" "repos-weekly.json" "$out"
check_eq "nodigest: files nothing from a partial list" "" "$(cat "$FAKE/created" 2>/dev/null)"

# ---- 11. repo-digest readable but empty ----
reset_world emptydigest
echo '{"repos":[]}' >"$FAKE/digest/repos.json"
echo '{"repos":[]}' >"$FAKE/digest/repos-weekly.json"
run L900
check_eq "emptydigest: exits nonzero" "1" "$rc"
check "emptydigest: refuses an empty list" "no repos" "$out"

# ---- 12. unknown lesson ----
reset_world unknown
run L999
check_eq "unknown: exits nonzero" "1" "$rc"
check "unknown: names the lesson" "L999" "$out"
check_not "unknown: no gh call at all" "issue" "$(cat "$FAKE/calls")"

# ---- 13. nobody signed in ----
reset_world noauth
echo '{"hosts":{}}' >"$FAKE/auth.json"
run L900
check_eq "noauth: exits nonzero" "1" "$rc"
check "noauth: says so" "no GitHub account is signed in" "$out"

# ---- 14. bad usage ----
reset_world usage
run
check_eq "usage: no argument exits 2" "2" "$rc"
run banana
check_eq "usage: a non lesson argument exits 2" "2" "$rc"

# ---- 15. several lessons in one run ----
reset_world many
run L900 L901
check_eq "many: exits 0" "0" "$rc"
check "many: L900 filed" "Lesson L900 sweep" "$(cat "$FAKE/created")"
check "many: L901 filed" "Lesson L901 sweep" "$(cat "$FAKE/created")"
ledger="$(cat "$CLAUDE_HOME/state/lesson-fanout.done")"
check "many: both in the ledger" "L901 def7654321" "$ledger"

printf 'SUITE-RESULT passed=%d failed=%d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
