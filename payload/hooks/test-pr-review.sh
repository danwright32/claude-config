#!/usr/bin/env bash
# Tests for the lessons review of a whole branch before a pull request merges (claude-config#560):
# lib/pr-review.sh (start, check), ai-review-on-pr.sh (PostToolUse on `gh pr create`),
# pr-review-gate.sh (PreToolUse on every merge route), the shared runner's pr mode, the nudge's
# cap, and the citation ledger.
#
# Every outcome the design names has a test here that PRODUCES it (L151): finished with findings,
# finished clean, still running, failed, did not finish, came back empty, abandoned, could not run
# (no claude, no python3), too large, and an empty diff.
#
# A fake claude and a fake gh on PATH stand in for the real ones, the state directory is the
# scratch directory's, and the repository is a throwaway with a bare origin, so nothing here can
# reach the network, Dan's reviews, or a real pull request (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/pr-review.sh"
CREATE_HOOK="$DIR/ai-review-on-pr.sh"
GATE="$DIR/pr-review-gate.sh"
NUDGE="$DIR/ai-review-nudge.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_not(){ if [[ "$3" != *"$2"* ]]; then ok; else bad "$1"; echo "  must not contain: $2"; echo "  actual: ${3:0:1500}"; fi; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

# The state directory is the scratch directory's, never Dan's (L2). CLAUDECODE is set so the runner's
# removal of it is exercised even in CI.
export AI_REVIEW_STATE_DIR="$WORKDIR/state"
export CLAUDECODE=1
export PR_REVIEW_DEADLINE_SECONDS=30
# The push review's host list names only the work Mac; the PR review must ignore it (the whole point
# of #560 on this Mac), so the suite judges as the Mac the push review skips.
export AI_REVIEW_HOST="Daniels-MacBook-Pro-2"
unset AI_REVIEW_HOSTS SKIP_PR_REVIEW 2>/dev/null || true

# --- the fake claude: records its call, then answers from the environment the test sets ---
FAKEBIN="$WORKDIR/bin"; mkdir -p "$FAKEBIN"
export FAKE_LOG="$WORKDIR/fakelog"; mkdir -p "$FAKE_LOG"
cat > "$FAKEBIN/claude" <<'EOS'
#!/usr/bin/env bash
printf 'called\n' >> "$FAKE_LOG/calls"
printf '%s\x1e' "$@" > "$FAKE_LOG/args"
env > "$FAKE_LOG/env"
# Read into this call's own file first: the groups of one branch (#601) are reviewed at once.
cat > "$FAKE_LOG/stdin.$$"
cp "$FAKE_LOG/stdin.$$" "$FAKE_LOG/stdin"
# A group's reviewer answers from FAKE_GROUP_<n>_OUT and sleeps FAKE_GROUP_<n>_SLEEP when set.
grp="$(grep -o 'THIS REVIEW IS GROUP [0-9]*' "$FAKE_LOG/stdin.$$" | head -1 | awk '{ print $NF }')"
if [ -n "$grp" ]; then
  mv "$FAKE_LOG/stdin.$$" "$FAKE_LOG/stdin.g$grp"
  v="FAKE_GROUP_${grp}_SLEEP"; sleep "${!v:-0}"
  v="FAKE_GROUP_${grp}_OUT"; [ -n "${!v:-}" ] && { printf '%s\n' "${!v}"; exit 0; }
else
  rm -f "$FAKE_LOG/stdin.$$"
fi
sleep "${FAKE_CLAUDE_SLEEP:-0}"
[ -n "${FAKE_CLAUDE_STDERR_FILE:-}" ] && cat "$FAKE_CLAUDE_STDERR_FILE" >&2
[ -n "${FAKE_CLAUDE_EXIT:-}" ] && { echo "fake claude: simulated failure" >&2; exit "$FAKE_CLAUDE_EXIT"; }
[ -n "${FAKE_CLAUDE_EMPTY:-}" ] && exit 0
# FAKE_CLAUDE_TOOL=1 stands in for the real reviewer as measured 2026-10-08 (claude-config#804):
# Claude Code offers every headless run a built in ReportFindings tool whose own description says to
# report a review through it and NOT also print the findings as text, so whenever the tool is
# offered the answer is prose about having used it. Offered unless the call disallows it by name.
if [ -n "${FAKE_CLAUDE_TOOL:-}" ]; then
  offered=1; in_list=0
  for a in "$@"; do
    case "$a" in
      --disallowedTools=*|--disallowed-tools=*) in_list=0; a="${a#*=}" ;;
      --disallowedTools|--disallowed-tools) in_list=1; continue ;;
      -*) in_list=0; continue ;;
      *) [ "$in_list" = 1 ] || continue ;;
    esac
    for t in $(printf '%s' "$a" | tr ',' ' '); do [ "$t" = "ReportFindings" ] && offered=0; done
  done
  if [ "$offered" = 1 ]; then
    printf 'I reported 1 finding through ReportFindings. It is rated plausible; I did not run any code.\n\n1. **App/Sync.swift:3**, deleteEvent still swallows the error.\n'
  else
    printf 'App/Sync.swift:3: deleteEvent still swallows the error createEvent now reports (L215). Should be: report it the same way. [severity: major]\n'
  fi
  exit 0
fi
if [ -n "${FAKE_CLAUDE_OUT_FILE:-}" ]; then cat "$FAKE_CLAUDE_OUT_FILE"; exit 0; fi
if [ -n "${FAKE_CLAUDE_OUT:-}" ]; then printf '%s\n' "$FAKE_CLAUDE_OUT"; exit 0; fi
printf 'App/Sync.swift:3: deleteEvent still swallows the error createEvent now reports (L215). Should be: report it the same way. [severity: major]\n'
EOS
chmod +x "$FAKEBIN/claude"

# --- the fake gh: answers `pr view` for the merge gate from files the test writes ---
cat > "$FAKEBIN/gh" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LOG/gh-calls"
case "$*" in
  "auth status"*) exit 0 ;;
  "pr view"*) [ -f "$FAKE_LOG/pr-view.json" ] && { cat "$FAKE_LOG/pr-view.json"; exit 0; }
              echo "no pull requests found for branch" >&2; exit 1 ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 3 ;;
esac
EOS
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
calls(){ [ -f "$FAKE_LOG/calls" ] && grep -c . "$FAKE_LOG/calls" || echo 0; }

# --- fixture: a bare origin, a main branch, and a feature branch carrying Swift and markdown ---
ORIGIN="$WORKDIR/origin.git"
git init -q --bare "$ORIGIN"
REPO="$WORKDIR/repo"
mkdir -p "$REPO/App"
git init -q "$REPO"
G(){ git -C "$REPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
G symbolic-ref HEAD refs/heads/main
printf 'func createEvent() {}\nfunc deleteEvent() {}\n' > "$REPO/App/Sync.swift"
printf '# fixture\n' > "$REPO/README.md"
G add App/Sync.swift README.md
G commit -q -m seed
G remote add origin "$ORIGIN"
G push -q -u origin main 2>/dev/null
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
G remote set-head origin main 2>/dev/null || true

G checkout -q -b feat/sync
printf 'func createEvent() throws {}\nfunc deleteEvent() {}\n// two\n' > "$REPO/App/Sync.swift"
G commit -q -am "one"
printf '# fixture\n\nMore.\n' > "$REPO/README.md"
G commit -q -am "two"
G push -q -u origin feat/sync 2>/dev/null
HEAD_SHA="$(G rev-parse HEAD)"
BASE_SHA="$(G merge-base origin/main HEAD)"

prr(){ bash "$LIB" "$@" 2>&1; }
key(){ bash -c ". '$DIR/lib/ai-review-common.sh'; ar_repo_key '$REPO'"; }
KEY="$(key)"
final_of(){ printf '%s/%s-pr-%s.txt' "$AI_REVIEW_STATE_DIR" "$KEY" "$1"; }
wait_final(){ # wait_final <sha>: waits on the condition, bounded, never a fixed sleep (L290)
  # Only while a review is PENDING: with no marker nothing is running, so there is nothing to wait
  # for and the absence is the answer.
  local f; f="$(final_of "$1")"; local t0=$SECONDS
  while [ ! -e "$f" ] && [ -e "$f.pending" ] && [ $((SECONDS - t0)) -lt 40 ]; do sleep 0.1; done
  [ -e "$f" ]
}
reset_state(){ rm -rf "$AI_REVIEW_STATE_DIR" "$FAKE_LOG"; mkdir -p "$FAKE_LOG"; }
meta(){ awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit } /^$/ { exit }' "$1"; }

# ===========================================================================================
# 1. Recognising `gh pr create` in command position, never a mention of it (L673).
# ===========================================================================================
is_create(){ bash -c ". '$DIR/lib/push-scope.sh'; ps_is_gh_pr_create \"\$1\"" _ "$1"; }
for c in 'gh pr create --fill' \
         'GH_TOKEN=$(gh auth token -u danwright32) gh pr create --title x --body y' \
         'cd /tmp/x && gh pr create --base main' \
         'rtk gh pr create --fill' \
         '/opt/homebrew/bin/gh pr create -f'; do
  is_create "$c" && ok || bad "a pull request creation is recognised: $c"
done
for c in 'echo "gh pr create"' \
         'gh pr view 12' \
         'git commit -m "then gh pr create"' \
         $'cat <<EOF > notes.md\ngh pr create --fill\nEOF' \
         'GH_TOKEN=$(gh auth token -u x) gh pr list'; do
  is_create "$c" && bad "a command that only mentions it is not a creation: $c" || ok
done

# ===========================================================================================
# 2. The PostToolUse hook: a successful creation starts a detached review of the WHOLE branch,
#    every file type, on this Mac too.
# ===========================================================================================
fire_create(){ # fire_create <command> <exit code>
  local p
  p="$(python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]},"tool_response":{"exit_code":int(sys.argv[3])}}))' "$REPO" "$1" "$2")"
  printf '%s' "$p" | bash "$CREATE_HOOK" 2>&1
}
reset_state
out="$(fire_create "gh pr create --fill" 1)"
check "a failed creation starts nothing, and says so" "did not succeed" "$out"
check_eq "a failed creation calls no reviewer" "0" "$(calls)"

out="$(fire_create "gh pr create --fill" 0)"
check "a creation says the whole branch review started" "started" "$out"
check "and names the branch range, merge base to head" "${BASE_SHA:0:7}..${HEAD_SHA:0:7}" "$out"
check_not "this Mac is not skipped by the push review's host list" "not one AI_REVIEW_HOSTS names" "$out"
wait_final "$HEAD_SHA" && ok || bad "the review finished and wrote its file"
F="$(final_of "$HEAD_SHA")"
check_eq "the finished review is a pr review" "pr" "$(meta "$F" kind)"
check_eq "and it finished" "ok" "$(meta "$F" status)"
check_eq "with one finding counted" "1" "$(meta "$F" findings)"
check_eq "against the merge base" "$BASE_SHA" "$(meta "$F" base)"
stdin="$(cat "$FAKE_LOG/stdin" 2>/dev/null)"
check "the Swift file is in the diff (every file type)" "App/Sync.swift" "$stdin"
check "markdown is in the diff too" "+More." "$stdin"
check "the first commit of the branch is in it, not only the last" "throws" "$stdin"
check "the reviewer is told this is a whole branch" "WHOLE BRANCH" "$(tr '\036' '\n' < "$FAKE_LOG/args")"
check_not "the reviewer did not inherit CLAUDECODE" "CLAUDECODE=" "$(cat "$FAKE_LOG/env")"
check "the cited lesson reached the durable ledger" "L215" "$(cat "$AI_REVIEW_STATE_DIR/citations.tsv" 2>/dev/null)"

# The durable outcome ledger (claude-config#562): one line per finished pr review, never swept.
LEDGER="$AI_REVIEW_STATE_DIR/pr-reviews.tsv"
line="$(grep -F "$HEAD_SHA" "$LEDGER" 2>/dev/null)"
check "the finished review is in the outcome ledger" "$HEAD_SHA" "$line"
check "with its outcome" $'\tok\t' "$line"
check "the file its finding named" "App/Sync.swift" "$line"
check "the lesson it cited" "L215" "$line"
check "and the Mac it ran on" "$AI_REVIEW_HOST" "$line"
check "the opening is in its own ledger" "$HEAD_SHA" "$(cat "$AI_REVIEW_STATE_DIR/pr-opened.tsv" 2>/dev/null)"

# A second creation for the same head starts nothing new.
out="$(fire_create "gh pr create --fill" 0)"
check "the same head is not reviewed twice" "already" "$out"
check_eq "and no second reviewer ran" "1" "$(calls)"

# ===========================================================================================
# 3. check: every outcome the merge gate can meet.
# ===========================================================================================
# 3a. finished with findings: refused WITH the findings and a read key, until a merge presents that
#     key (claude-config#788). It used to refuse ONCE and then allow, judging the findings read
#     because the refusal had been printed; on #774 another hook refused the same merge, only that
#     hook's message was shown, and the retry merged with nobody having seen them. The key is in
#     the refusal and nowhere else the session reads, so a merge carrying it proves it was shown.
key_in(){ [[ "$1" =~ PR_REVIEW_READ=([a-f0-9]+) ]] && printf '%s' "${BASH_REMATCH[1]}"; }
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "unread findings refuse the merge" "1" "$rc"
check "the refusal carries the finding itself" "deleteEvent still swallows" "$out"
check "and the count" "1 finding" "$out"
k1="$(key_in "$out")"
[ -n "$k1" ] && ok || bad "the refusal names a read key to merge with: $out"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a second attempt without the key is refused again, the refusal may not have been shown" "1" "$rc"
check "carrying the findings again" "deleteEvent still swallows" "$out"
# Each showing issues a FRESH key, and only a hash of each is stored (lessons review of #795): a
# plain key on disk could be read by a session that never saw the findings.
k2="$(key_in "$out")"
[ -n "$k2" ] && [ "$k2" != "$k1" ] && ok || bad "a second showing issues a fresh key (first $k1, second $k2)"
if grep -rqF "$k1" "$AI_REVIEW_STATE_DIR" 2>/dev/null; then bad "a plain read key is stored on disk"; else ok; fi
# Printing is not reading, so nothing records "printed" as if it meant something: the old
# <review>.delivered marker is no longer written by a refusal.
[ ! -e "$(final_of "$HEAD_SHA").delivered" ] && ok || bad "a refusal still writes the unread .delivered marker"
out="$(PR_REVIEW_READ=0000dead prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a wrong key is refused" "1" "$rc"
out="$(PR_REVIEW_READ="$k1" prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "the key from the refusal allows the merge" "0" "$rc"
check "and says the findings were read on their key" "read: this merge presented their key" "$out"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "once read, a later check of the same head allows" "0" "$rc"

# 3a2. a review file with findings but no finish stamp cannot be given a read key, and the refusal
#      says THAT, never that the state folder is at fault (L11).
reset_state
mkdir -p "$AI_REVIEW_STATE_DIR"
printf 'repo=repo\nstatus=ok\nkind=pr\nfindings=1\n\nApp/Sync.swift:3: x (L1). Should be: y.\n' > "$(final_of "$HEAD_SHA")"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a review with no finish stamp refuses" "1" "$rc"
check "and says the review records no finish time" "no finish time" "$out"
check_not "and does not blame the state folder" "could be made in" "$out"

# 3a3. each reason a read key cannot be issued is named, with the remedy that fits it (L11, L111):
#      a missing tool is not fixed by re-running the review, and a stamp problem is not a tool.
reset_state
FAKE_CLAUDE_OUT="App/Sync.swift:3: x (L1). Should be: y. [severity: minor]" prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA"
NOSHA="$WORKDIR/noshasum"; mkdir -p "$NOSHA"
for t in awk tr od git bash cat date mkdir rm grep sed basename dirname env head mv touch wc sort printf python3 claude gh \
         cksum cut uname hostname mktemp ls chmod readlink nohup tail xargs find stat sleep kill ps id; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOSHA/$t"
done
out="$(PATH="$NOSHA" bash "$LIB" check --dir "$REPO" --sha "$HEAD_SHA" 2>&1)"; rc=$?
check_eq "with no shasum the merge is still refused" "1" "$rc"
check "and the refusal names the missing tool" "shasum" "$out"
out="$(PR_REVIEW_READ=0123456789abcdef PATH="$NOSHA" bash "$LIB" check --dir "$REPO" --sha "$HEAD_SHA" 2>&1)"
check_not "a presented key is not blamed when no key can be checked at all" "not this review's key" "$out"
check_not "and does not send it to re-run the review" "pr-review.sh restart --dir" "$out"
chmod a-w "$AI_REVIEW_STATE_DIR"
if ( : > "$AI_REVIEW_STATE_DIR/.probe" ) 2>/dev/null; then
  # Root, or a filesystem ignoring modes: the case cannot be produced here, so it is said, not failed (L411).
  rm -f "$AI_REVIEW_STATE_DIR/.probe"; chmod u+w "$AI_REVIEW_STATE_DIR"
  echo "  UNMEASURED: the state folder stayed writable after chmod a-w, so the no-write case was not produced"
else
  out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
  chmod u+w "$AI_REVIEW_STATE_DIR"
  check_eq "with nowhere to write a key the merge is still refused" "1" "$rc"
  check "and the refusal says nothing could be written beside the review" "could not be written" "$out"
fi

# 3b. finished clean: allowed at once.
reset_state
FAKE_CLAUDE_OUT="No issues found." prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the clean review finished"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a clean review allows the merge" "0" "$rc"
check "and says it found nothing" "0 findings" "$out"

# 3c. no review for this head: one is started, and the merge is refused while it runs.
reset_state
out="$(FAKE_CLAUDE_SLEEP=3 prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "no review for the head refuses as still to come (3), not as a verdict" "3" "$rc"
check "and starts one" "started" "$out"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a running review refuses, with its own exit code so a waiter can tell it from a verdict" "3" "$rc"
check "and says it is still running, with its elapsed time" "still running" "$out"
check "naming its deadline" "30s" "$out"
wait_final "$HEAD_SHA" || bad "the started review finished"

# 3d. did not finish inside its deadline.
reset_state
out="$(PR_REVIEW_DEADLINE_SECONDS=1 FAKE_CLAUDE_SLEEP=20 prr start --dir "$REPO" --sha "$HEAD_SHA")"
wait_final "$HEAD_SHA" || bad "the slow review was recorded as unfinished"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a review that ran out of time refuses" "1" "$rc"
check "in its own words" "did not finish" "$out"
check "naming the one command override" "SKIP_PR_REVIEW=1" "$out"
check "and the way to run it again" "pr-review.sh restart" "$out"

# 3e. the reviewer failed.
reset_state
FAKE_CLAUDE_EXIT=3 prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the failed review wrote its file"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a failed review refuses" "1" "$rc"
check "saying it failed and why" "claude exited 3" "$out"

# 3e2. the reviewer failed and its stderr carried SECRETS (claude-config#581). On 2026-09-24 in
#      Bidspoke a failed start printed Claude Code's warnings about wildcard permission rules, which
#      quote each rule verbatim, and a rule held a live Supabase secret key inside a curl command, so
#      the gate echoed the key into the session. The fake values are assembled at run time so this
#      file holds no secret shaped literal for a scanner to trip on.
reset_state
SB="sb_""secret_""Zq9fakeFAKEfake0123456789abcd"
SK="sk-""ant-fakeFAKEfake0123456789abcdef"
JWT="eyJ""hbGciOiJIUzI1NiJ9.eyJ""zdWIiOiJmYWtlIn0.c2lnbmF0dXJlZmFrZQ"
BEARER="tok""FAKEfake0123456789bearer"
GHP="ghp""_FAKEfake0123456789abcdefghijABCDEFGHIJ"
cat > "$WORKDIR/stderr-secrets" <<EOS
Warning: permission rule Bash(curl -H "apikey: $SB" https://x.supabase.co/rest/v1/*) uses a wildcard
Settings warning in .claude/settings.local.json: Bash(curl -H "Authorization: Bearer $BEARER" *)
Error: request failed: Authorization: Bearer $BEARER
Error: the key $SK was rejected
Error: a token $JWT and $GHP were seen
EOS
FAKE_CLAUDE_EXIT=1 FAKE_CLAUDE_STDERR_FILE="$WORKDIR/stderr-secrets" prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the failed review with secrets on stderr wrote its file"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
stored="$(cat "$(final_of "$HEAD_SHA")")"
check_eq "a failed review carrying secrets still refuses" "1" "$rc"
check "still saying why it failed" "claude exited 1" "$out"
for secret in "$SB" "$SK" "$JWT" "$BEARER" "$GHP"; do
  check_not "the merge refusal never echoes a secret from the reviewer's stderr (${secret:0:6})" "$secret" "$out"
  check_not "the stored review never holds a secret from the reviewer's stderr (${secret:0:6})" "$secret" "$stored"
done
check_not "a permission rule warning is dropped, not shown" "permission rule" "$out"
check_not "a settings warning is dropped, not shown" "settings.local.json" "$out"
check "a redaction says so" "[REDACTED]" "$out"
# A review file written BEFORE the fix holds its stderr raw, so the gate redacts on the way out too.
f="$(final_of "$HEAD_SHA")"
printf 'repo=x\nstatus=error\nstarted=1\nfinished=2\n\nclaude exited 1 and no review was read back. Its last lines:\nWarning: permission rule Bash(curl -H "apikey: %s" *)\nError: Authorization: Bearer %s\n' "$SB" "$BEARER" > "$f"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"
check "an old raw review still refuses with its reason" "claude exited 1" "$out"
check_not "an old raw review's secret is redacted at display" "$SB" "$out"
check_not "an old raw review's bearer token is redacted at display" "$BEARER" "$out"
# With its rule file missing the redactor withholds and fails, never passes the text through (L42).
mkdir -p "$WORKDIR/norules"
cp "$DIR/lib/ai-review-common.sh" "$WORKDIR/norules/"
out="$(printf 'Error: the key %s\n' "$SK" | bash -c '. "$1" && ar_redact' _ "$WORKDIR/norules/ai-review-common.sh")"; rc=$?
check_eq "a redactor without its rules fails" "1" "$rc"
check_not "a redactor without its rules never passes the text through" "$SK" "$out"
check "and says it withheld it" "withheld" "$out"
# An answer in neither shape is shown as evidence, and is redacted the same way.
reset_state
FAKE_CLAUDE_OUT="I could not review this. The key apikey: $SB is in the diff." prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the unparsed review with a secret wrote its file"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"
check "the unparsed answer is still shown as evidence" "I could not review this" "$out"
check_not "an unparsed answer's secret is redacted" "$SB" "$out"
check_not "the stored unparsed answer holds no secret" "$SB" "$(cat "$(final_of "$HEAD_SHA")")"

# 3f. the reviewer came back empty.
reset_state
FAKE_CLAUDE_EMPTY=1 prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the empty review wrote its file"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "an empty answer refuses, never reads as clean" "1" "$rc"
check "in its own words" "printed nothing" "$out"

# 3f2. an answer in neither shape the prompt allows. Measured 2026-09-24, the first real run: the
#      headless claude ran Dan's global hooks, and what came back was the end of turn issue review,
#      not a review. Counted as zero findings it would have allowed the merge as clean (L98, L340).
reset_state
FAKE_CLAUDE_OUT=$'ISSUE REVIEW\n\n1.1 Something about the session, not the diff.\n\nWant me to file that as an issue?' prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the unparsed review wrote its file"
check_eq "an answer in neither allowed shape is its own outcome" "unparsed" "$(meta "$(final_of "$HEAD_SHA")" status)"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "and it refuses, never reads as zero findings" "1" "$rc"
check "saying the answer was not a review" "not in the review's format" "$out"
check "the reviewer runs with every hook switched off" "disableAllHooks" "$(tr '\036' '\n' < "$FAKE_LOG/args")"

# 3f3. the findings tool (claude-config#804). Measured 2026-10-08: in 6 of about 10 rounds on one
#      pull request the real reviewer called Claude Code's built in ReportFindings tool and answered
#      "I reported N findings through ReportFindings" with no finding line, so a review that had run
#      was refused as unparsed and the findings never reached the gate. The runner takes the tool
#      away, so the reviewer's only channel is the text the gate parses. Three stand ins, one verdict
#      each: the one that answers through the tool whenever it is offered, one that answers in prose
#      whatever it is offered, and one that answers in the format.
reset_state
FAKE_CLAUDE_TOOL=1 prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the tool using reviewer's review wrote its file"
F="$(final_of "$HEAD_SHA")"
check_eq "a reviewer that would answer through the findings tool is never offered it, so it is read" "ok" "$(meta "$F" status)"
check_eq "and its finding is counted" "1" "$(meta "$F" findings)"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "and the gate refuses it as findings to read, not as a failed review" "1" "$rc"
check "carrying the finding line" "App/Sync.swift:3: deleteEvent still swallows" "$out"
check "and a read key" "PR_REVIEW_READ=" "$out"
check_not "never as unparsed" "not in the review's format" "$out"
reset_state
FAKE_CLAUDE_OUT=$'I reported 3 findings through ReportFindings. All three are plausible.\n\n1. **App/Sync.swift:3**, deleteEvent still swallows the error.' prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the prose review wrote its file"
check_eq "an answer that is prose about findings, with no finding line, is still unparsed" "unparsed" "$(meta "$(final_of "$HEAD_SHA")" status)"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "and still refuses" "1" "$rc"
check "as not a review" "not in the review's format" "$out"
check_not "with no read key, since nothing was read back" "PR_REVIEW_READ=" "$out"
reset_state
FAKE_CLAUDE_OUT="No issues found." prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the clean review wrote its file"
check_eq "an answer in the format is read as clean" "ok" "$(meta "$(final_of "$HEAD_SHA")" status)"
check_eq "with no findings" "0" "$(meta "$(final_of "$HEAD_SHA")" findings)"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "and the gate allows it" "0" "$rc"

# 3g. abandoned: pending past its deadline with no runner left.
reset_state
mkdir -p "$AI_REVIEW_STATE_DIR"
printf 'repo=repo\nbranch=feat/sync\nsha=%s\nstarted=%s\ndeadline=30\nkind=pr\n' "$HEAD_SHA" "$(( $(date +%s) - 600 ))" > "$(final_of "$HEAD_SHA").pending"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "an abandoned review refuses" "1" "$rc"
check "saying the runner died" "never finished" "$out"
[ -e "$(final_of "$HEAD_SHA").pending" ] && bad "the abandoned marker is cleared" || ok
check "an abandoned review is in the outcome ledger" $'\tabandoned\t' "$(cat "$AI_REVIEW_STATE_DIR/pr-reviews.tsv" 2>/dev/null)"

# 3g2. The nudge's own abandoned conversion records the repository directory as well, from the
#      pending marker, so both abandoned paths write the same ledger row (found by the review of #571).
reset_state
FAKE_CLAUDE_SLEEP=5 prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
check "the pending marker names the repository directory" "dir=$(git -C "$REPO" rev-parse --show-toplevel)" "$(cat "$(final_of "$HEAD_SHA").pending" 2>/dev/null)"
python3 - "$(final_of "$HEAD_SHA").pending" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r"started=\d+", "started=1000", s))
PYEOF
printf '{"session_id":"n9","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" >/dev/null 2>&1
check "the nudge's abandoned row carries the repository directory" $'\t'"$(git -C "$REPO" rev-parse --show-toplevel)"$'\t' "$(grep -F $'\tabandoned\t' "$AI_REVIEW_STATE_DIR/pr-reviews.tsv" 2>/dev/null)"

# 3h. could not run: no claude on PATH. A PATH built from every tool but claude, so the case is
#     produced on a machine that has one installed, which this suite used to report as UNMEASURED.
reset_state
NOCLAUDE="$WORKDIR/noclaude"; mkdir -p "$NOCLAUDE"
for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin "$FAKEBIN"; do
  [ -d "$d" ] || continue
  for t in "$d"/*; do
    b="$(basename "$t")"
    [ "$b" = claude ] && continue
    [ -e "$NOCLAUDE/$b" ] || ln -s "$t" "$NOCLAUDE/$b" 2>/dev/null
  done
done
out="$(PATH="$NOCLAUDE" bash "$LIB" check --dir "$REPO" --sha "$HEAD_SHA" 2>&1)"; rc=$?
check_eq "no claude refuses" "1" "$rc"
check "naming what is missing" "could not run" "$out"
check "and which tool" "claude" "$out"
check "a review that could not run is in the outcome ledger too" $'\tcould-not-run\t' "$(cat "$AI_REVIEW_STATE_DIR/pr-reviews.tsv" 2>/dev/null)"

# 3i. could not run: no python3 (the runner's interpreter). A PATH built from every tool but python3.
reset_state
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin "$FAKEBIN"; do
  [ -d "$d" ] || continue
  for t in "$d"/*; do
    b="$(basename "$t")"
    case "$b" in python3*|python) continue ;; esac
    [ -e "$NOPY/$b" ] || ln -s "$t" "$NOPY/$b" 2>/dev/null
  done
done
out="$(PATH="$NOPY" bash "$LIB" check --dir "$REPO" --sha "$HEAD_SHA" 2>&1)"; rc=$?
check_eq "no python3 refuses" "1" "$rc"
check "naming python3" "python3" "$out"
check_eq "and no reviewer was started without its interpreter" "0" "$(calls)"

# 3j. too large for a review to use.
reset_state
out="$(PR_REVIEW_MAX_BYTES=10 prr start --dir "$REPO" --sha "$HEAD_SHA")"
out="$(PR_REVIEW_MAX_BYTES=10 prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "a branch over the size cap refuses" "1" "$rc"
check "saying it is too large, with its size" "too large" "$out"
check_eq "and no reviewer ran" "0" "$(calls)"

# 3k. an empty diff: nothing to review, allowed, said so.
reset_state
out="$(prr check --dir "$REPO" --sha "$BASE_SHA")"; rc=$?
check_eq "a head with nothing on it beyond the base is allowed" "0" "$rc"
check "and says the diff was empty" "empty" "$out"

# 3l. A flag that needs a value, given last, is a usage error at once, never a loop: `shift 2` with
#     one argument left fails without shifting (the class found in find-prior-verdicts.sh, L387).
for flag in --dir --sha --base-ref; do
  bash "$LIB" check "$flag" >"$WORKDIR/trail.out" 2>&1 &
  pid=$!; t0=$SECONDS
  while kill -0 "$pid" 2>/dev/null && [ $((SECONDS - t0)) -lt 5 ]; do sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; bad "$flag given last hangs instead of being refused"
  else
    wait "$pid"; check_eq "$flag given last is a usage error" "64" "$?"
  fi
done

# ===========================================================================================
# 4. The merge gate, on the typed route and its override.
# ===========================================================================================
fire_gate(){ # fire_gate <command>
  python3 -c 'import json,sys; print(json.dumps({"session_id":"s1","cwd":sys.argv[1],"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[2]}}))' "$REPO" "$1" \
    | bash "$GATE" 2>&1
}
reset_state
printf '{"number":7,"headRefOid":"%s","baseRefName":"main","headRefName":"feat/sync"}\n' "$HEAD_SHA" > "$FAKE_LOG/pr-view.json"
out="$(fire_gate "echo hello")"; rc=$?
check_eq "a command that merges nothing passes untouched" "0" "$rc"
check_eq "and says nothing" "" "$out"
out="$(FAKE_CLAUDE_SLEEP=2 fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "a merge with no review is refused" "2" "$rc"
check "and the review is started for the pull request's head" "started" "$out"
wait_final "$HEAD_SHA" || bad "the gate's review finished"
out="$(fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "the first merge after it finishes is refused with the findings" "2" "$rc"
check "carrying them" "deleteEvent still swallows" "$out"
gk="$(key_in "$out")"
# #788: suppose another hook refused this same attempt and only ITS message was shown. The retry,
# without the key, must be refused again with the findings, never allowed as if they were read.
out="$(fire_gate "gh pr merge 7 --squash --match-head-commit $HEAD_SHA")"; rc=$?
check_eq "a retry without the read key is refused again" "2" "$rc"
check "carrying the findings again" "deleteEvent still swallows" "$out"
# The key counts only as an assignment in front of the MERGE itself, never as text elsewhere in the
# command: an echo or another command carrying it says nothing about this merge (L673).
out="$(fire_gate "echo 'PR_REVIEW_READ=$gk' && gh pr merge 7 --squash")"; rc=$?
check_eq "a key that is only mentioned in another command does not count" "2" "$rc"
out="$(fire_gate "PR_REVIEW_READ=$gk true && gh pr merge 7 --squash")"; rc=$?
check_eq "a key in front of a different command does not count" "2" "$rc"
# Before an assignment holding a space (scoping the merge to one of Dan's accounts), still the key.
out="$(fire_gate "PR_REVIEW_READ=$gk GH_TOKEN=\$(gh auth token -u x; true) gh pr merge 7 --squash")"; rc=$?
check_eq "a key before an account scoped merge is read as the key" "0" "$rc"
rm -f "$(final_of "$HEAD_SHA").acknowledged"
# Quoted, as a shell would accept it, the key is the same key.
out="$(fire_gate "PR_REVIEW_READ=\"$gk\" gh pr merge 7 --squash")"; rc=$?
check_eq "a quoted key in front of the merge is read as the key" "0" "$rc"
out="$(fire_gate "PR_REVIEW_READ=$gk gh pr merge 7 --squash")"; rc=$?
check_eq "the merge carrying the key from the refusal is allowed" "0" "$rc"
# An acknowledgement belongs to the review it read: a review file written again for the same head,
# by any route, must not inherit it.
f7="$(final_of "$HEAD_SHA")"
sed 's/^finished=.*/finished=1/' "$f7" > "$f7.tmp" && mv "$f7.tmp" "$f7"
out="$(fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "an acknowledgement does not carry over to a replaced review of the same head" "2" "$rc"
[ -n "$(key_in "$out")" ] && [ "$(key_in "$out")" != "$gk" ] && ok \
  || bad "a replaced review of the same head is given a NEW read key (old $gk, now $(key_in "$out"))"
out2="$(fire_gate "PR_REVIEW_READ=$gk gh pr merge 7 --squash")"; rc=$?
check_eq "and the earlier review's key does not read the replaced one" "2" "$rc"
out="$(fire_gate "PR_REVIEW_READ=$(key_in "$out") gh pr merge 7 --squash")"; rc=$?
check_eq "and the replaced review is read the same way, by its key" "0" "$rc"
# Eight issuers at once each get a whole key that reads the review, none lost to another's write.
fk="$WORKDIR/concurrent-review.txt"; printf 'status=ok\nfinished=42\n\n' > "$fk"; rm -f "$fk".readkey*
for i in 1 2 3 4 5 6 7 8; do
  bash -c '. "$1" && ar_review_issue_key "$2"' _ "$DIR/lib/ai-review-common.sh" "$fk" > "$WORKDIR/key.$i" &
done
wait
all_valid=1
for i in 1 2 3 4 5 6 7 8; do
  k="$(cat "$WORKDIR/key.$i")"
  { [ "${#k}" -eq 16 ] && bash -c '. "$1" && ar_review_key_valid "$2" "$3"' _ "$DIR/lib/ai-review-common.sh" "$fk" "$k"; } || all_valid=0
done
[ "$all_valid" -eq 1 ] && ok \
  || bad "eight concurrent issuers each get a key that reads the review (got: $(for i in 1 2 3 4 5 6 7 8; do printf '[%s] ' "$(cat "$WORKDIR/key.$i")"; done))"
bash -c '. "$1" && ar_review_key_valid "$2" 0123456789abcdef' _ "$DIR/lib/ai-review-common.sh" "$fk" && bad "a key never issued reads the review" || ok
# Never rewritten, only appended: every key issued, first and seventieth, still reads (a trim raced
# concurrent appends and dropped keys that had been shown; lessons review of #795).
firstk="$(bash -c '. "$1"; ar_review_issue_key "$2"' _ "$DIR/lib/ai-review-common.sh" "$fk")"
lastk="$(bash -c '. "$1"; for i in $(seq 1 70); do k="$(ar_review_issue_key "$2")"; done; printf %s "$k"' _ "$DIR/lib/ai-review-common.sh" "$fk")"
bash -c '. "$1" && ar_review_key_valid "$2" "$3"' _ "$DIR/lib/ai-review-common.sh" "$fk" "$firstk" && ok || bad "an early key stops reading after many showings"
bash -c '. "$1" && ar_review_key_valid "$2" "$3"' _ "$DIR/lib/ai-review-common.sh" "$fk" "$lastk" && ok || bad "the newest key does not read"
rm -f "$WORKDIR"/key.*
out="$(fire_gate "./scripts/merge-when-green.sh 7")"; rc=$?
check_eq "a repo's own merge script is judged the same way" "0" "$rc"
rm -f "$(final_of "$HEAD_SHA")"*
out="$(fire_gate "./scripts/merge-when-green.sh 7")"; rc=$?
check_eq "and refused the same way when there is no review" "2" "$rc"
wait_final "$HEAD_SHA"; rm -f "$(final_of "$HEAD_SHA")"*
out="$(fire_gate "venv/bin/python tools/wait_for_checks.py 7 --merge")"; rc=$?
check_eq "PostRoll's REST merge tool, run by its interpreter, is refused the same way" "2" "$rc"
wait_final "$HEAD_SHA"; rm -f "$(final_of "$HEAD_SHA")"*
out="$(fire_gate "bash scripts/merge-when-green.sh 7 && echo merged")"; rc=$?
check_eq "a merge followed by another command is still seen" "2" "$rc"
out="$(fire_gate "SKIP_PR_REVIEW=1 gh pr merge 7 --squash")"; rc=$?
check_eq "the override lets the merge through" "0" "$rc"
check "and says out loud that it did" "SKIP_PR_REVIEW=1" "$out"
rm -f "$FAKE_LOG/pr-view.json"
out="$(fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "a pull request gh cannot find is refused, never allowed blind" "2" "$rc"

# ===========================================================================================
# 5. The nudge shows a pr review under the 10,000 char hook cap, with a read key; showing it there
#    does not allow the merge (#788).
# ===========================================================================================
reset_state
big="$WORKDIR/big.txt"; : > "$big"
for i in $(seq 1 200); do printf 'App/Sync.swift:%d: finding number %d with enough words to be a realistic finding line about something (L1). Should be: fixed. [severity: minor]\n' "$i" "$i" >> "$big"; done
FAKE_CLAUDE_OUT_FILE="$big" prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "the big review finished"
out="$(printf '{"session_id":"n1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "the nudge names it as the pull request review" "Lessons review of the whole branch" "$out"
check "with the total count" "200 findings" "$out"
check "and where the full list is" "$(final_of "$HEAD_SHA")" "$out"
[ "${#out}" -lt 10000 ] && ok || bad "the nudge stays under the 10,000 char hook cap (was ${#out})"
# The nudge reaches whichever session prompts next in this repository, which need not be the one
# merging (on #774 the nudge marked them delivered in the coordinating session while a subagent
# merged), so showing them there is not proof the merger read them (#788). It carries the read key,
# so the session that saw them can merge with it.
nk="$(key_in "$out")"
[ -n "$nk" ] && ok || bad "the nudge names the read key"
out="$(prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "findings the nudge showed still refuse a merge without the key" "1" "$rc"
[ "${#out}" -lt 10000 ] && ok || bad "the gate's own message stays under the cap too"
out="$(PR_REVIEW_READ="$nk" prr check --dir "$REPO" --sha "$HEAD_SHA")"; rc=$?
check_eq "and the nudge's key allows it" "0" "$rc"

# 5a. With no read key to give (the review records no finish time), the nudge says so and names
#     the remedy, rather than saying the merge waits on a key it never shows (L11).
reset_state
mkdir -p "$AI_REVIEW_STATE_DIR"
printf 'repo=repo\nbranch=feat/sync\nsha=%s\nstatus=ok\nkind=pr\nfindings=1\n\nApp/Sync.swift:3: x (L1). Should be: y.\n' "$HEAD_SHA" > "$(final_of "$HEAD_SHA")"
out="$(printf '{"session_id":"k1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "the nudge says no read key could be made" "No read key could be made" "$out"
check "and names the restart" "pr-review.sh restart" "$out"

# 5b. The nudge's sentence fits the count: one finding is singular, and a clean review says it is
#     clean rather than that the merge waits on findings it does not have (L21).
reset_state
FAKE_CLAUDE_OUT="No issues found." prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA"
out="$(printf '{"session_id":"c1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "a clean review says so" "found nothing" "$out"
check_not "and does not say the merge waits on it" "merge waits" "$out"
reset_state
prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA"
out="$(printf '{"session_id":"c2","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "one finding is singular" "with 1 finding " "$out"

# 6. The ledger outlives the 14 day sweep: the nudge's sweep leaves it alone.
touch -t 202601010000 "$AI_REVIEW_STATE_DIR/citations.tsv"
printf '{"session_id":"n2","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" >/dev/null 2>&1
[ -s "$AI_REVIEW_STATE_DIR/citations.tsv" ] && ok || bad "the citation ledger survives the sweep"
# A review's list of files it left out (#583) is swept with the review it belongs to.
printf '1\tx.json\tfixture\tfixture data\n' > "$AI_REVIEW_STATE_DIR/old-pr-abc.txt.leftout"
touch -t 202601010000 "$AI_REVIEW_STATE_DIR/old-pr-abc.txt.leftout"
printf '{"session_id":"n3","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" >/dev/null 2>&1
[ ! -e "$AI_REVIEW_STATE_DIR/old-pr-abc.txt.leftout" ] && ok || bad "#583 a left out list older than 14 days is swept with its review"

# ===========================================================================================
# 7. A push to a branch with an OPEN pull request starts the review of the new head
#    (claude-config#577), so a fix pushed after the PR opened is reviewed by merge time rather
#    than started by the merge gate, which then waits about five minutes.
# ===========================================================================================
reset_state
printf 'func pushed() {}\n' >> "$REPO/App/Sync.swift"; G commit -q -am "fix after review"
G push -q 2>/dev/null
PUSHED_SHA="$(G rev-parse HEAD)"
printf '{"number":7,"state":"OPEN","headRefOid":"%s","baseRefName":"main"}\n' "$PUSHED_SHA" > "$FAKE_LOG/pr-view.json"
out="$(fire_create "git push" 0)"
check "a push to a branch with an open PR starts its review" "started" "$out"
wait_final "$PUSHED_SHA" && ok || bad "the pushed head was reviewed"
check_eq "and it is the pushed head that was reviewed" "$PUSHED_SHA" "$(meta "$(final_of "$PUSHED_SHA")" sha)"
out="$(fire_create "git push" 0)"
check "a second push of the same head starts nothing new" "already" "$out"
reset_state
out="$(fire_create "git push" 1)"
check_eq "a failed push starts nothing" "0" "$(calls)"
printf '{"number":7,"state":"MERGED","headRefOid":"%s","baseRefName":"main"}\n' "$PUSHED_SHA" > "$FAKE_LOG/pr-view.json"
out="$(fire_create "git push" 0)"
check_eq "a push to a branch whose PR is merged starts nothing" "0" "$(calls)"
rm -f "$FAKE_LOG/pr-view.json"
out="$(fire_create "git push" 0)"
check_eq "a push to a branch with no PR starts nothing" "0" "$(calls)"
check_eq "and says nothing, since most pushes have no PR yet" "" "$out"

# ===========================================================================================
# 9. Generated files are diffed with no context and their full text is left out (claude-config#591).
#    On overture PR #4401 (measured 2026-09-30) the generated project.pbxproj, 30 added lines, was 145 KB of a 373 KB
#    diff at -U20, which put an ordinary branch over the cap. Marked generated by .gitattributes,
#    as a merge driver or linguist-generated, read from the HEAD being reviewed, not the checkout.
# ===========================================================================================
reset_state
G checkout -q -b feat/gen main
printf 'App.pbxproj merge=overture-generated\nvendor.txt linguist-generated\nCHANGES.md merge=union\n' > "$REPO/.gitattributes"
seq 1 200 | sed 's/^/genline /' > "$REPO/App.pbxproj"
seq 1 200 | sed 's/^/vendline /' > "$REPO/vendor.txt"
seq 1 200 | sed 's/^/handline /' > "$REPO/Hand.swift"
seq 1 200 | sed 's/^/changeline /' > "$REPO/CHANGES.md"
G add .gitattributes App.pbxproj vendor.txt Hand.swift CHANGES.md
G commit -q -m "gen base"
GEN_BASE="$(G rev-parse HEAD)"
G push -q origin feat/gen 2>/dev/null
sed -i.bak 's/^genline 100$/genline 100 CHANGED/' "$REPO/App.pbxproj"
sed -i.bak 's/^vendline 100$/vendline 100 CHANGED/' "$REPO/vendor.txt"
sed -i.bak 's/^handline 100$/handline 100 CHANGED/' "$REPO/Hand.swift"
sed -i.bak 's/^changeline 100$/changeline 100 CHANGED/' "$REPO/CHANGES.md"
rm -f "$REPO"/*.bak
G commit -q -am "gen change"
GEN_SHA="$(G rev-parse HEAD)"
G checkout -q feat/sync
# Reviewed against the commit before the change, so the change is the whole diff.
out="$(prr start --dir "$REPO" --sha "$GEN_SHA" --base-ref "$GEN_BASE")"
wait_final "$GEN_SHA" && ok || bad "the branch with generated files was reviewed: $out"
stdin="$(cat "$FAKE_LOG/stdin" 2>/dev/null)"
check "the generated file's change is in the diff" "+genline 100 CHANGED" "$stdin"
check_not "but none of its context lines are" " genline 95" "$stdin"
check "a linguist-generated file's change is in the diff" "+vendline 100 CHANGED" "$stdin"
check_not "but none of its context lines are" " vendline 95" "$stdin"
check "a hand written file keeps its twenty lines of context" " handline 95" "$stdin"
check "and a union merged file is hand written, so it keeps its context too" " changeline 95" "$stdin"
check_not "the generated file's full text is not appended" "FULL FILE at ${GEN_SHA:0:7}: App.pbxproj" "$stdin"
check "while a hand written file's still is" "FULL FILE at ${GEN_SHA:0:7}: Hand.swift" "$stdin"
check "and the review says which files were treated as generated" "GENERATED" "$stdin"
check "naming them" "App.pbxproj" "$(printf '%s\n' "$stdin" | grep GENERATED)"
# A name git would C-quote (non-ASCII here) is still matched to its attributes, not lost to quoting.
QREPO="$WORKDIR/quoted"; git init -q "$QREPO"
QG(){ git -C "$QREPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
QNAME="$(printf 'caf\303\251.gen')"
printf '*.gen linguist-generated\n' > "$QREPO/.gitattributes"; printf 'a\n' > "$QREPO/$QNAME"
QG add -A; QG commit -q -m base; QB="$(QG rev-parse HEAD)"
printf 'b\n' > "$QREPO/$QNAME"; QG commit -q -am change; QH="$(QG rev-parse HEAD)"
qgen="$(cd "$QREPO" && bash -c ". '$DIR/lib/ai-review-common.sh'; ar_generated_paths '$QB' '$QH'")"
check_eq "#591 a generated file with a non-ASCII name is found by its real name" "$QNAME" "$qgen"
# A git too old for check-attr --source refuses it, and the working tree's attributes are read
# instead: the pipe through tr must not hide that refusal and skip the fallback.
qold="$(cd "$QREPO" && bash -c "git(){ case \" \$* \" in *' --source '*) echo 'error: unknown option source' >&2; return 129 ;; esac; command git \"\$@\"; }; . '$DIR/lib/ai-review-common.sh'; ar_generated_paths '$QB' '$QH'")"
check_eq "#591 and on a git with no check-attr --source, the working tree's attributes still find it" "$QNAME" "$qold"

# ===========================================================================================
# 10. The label and the base are the PULL REQUEST's, never this checkout's (claude-config#852).
#     Merging Slate #3358 from a primary checkout that another session had on
#     fix/2210-corrected-number-wins labelled the review with that branch. And a merge run from a
#     checkout whose origin/main was 130 commits stale diffed from that stale tip, 305 KB against
#     a 300 KB cap, when the pull request's real base made it a fraction of that.
# ===========================================================================================
reset_state
G checkout -q -b other/session-work
out="$(FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$HEAD_SHA" --base-ref origin/main)"
check_not "#852 a review of another head is not labelled with the branch this checkout is on" "other/session-work" "$out"
check "#852 with no branch named, it is labelled by its own commit" "whole branch repo ${HEAD_SHA:0:7} (" "$out"
wait_final "$HEAD_SHA" || bad "#852 the unnamed review finished"
check_eq "#852 and the review file records the commit, not the checkout's branch" "${HEAD_SHA:0:7}" "$(meta "$(final_of "$HEAD_SHA")" branch)"
reset_state
out="$(FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$HEAD_SHA" --base-ref origin/main --branch feat/sync)"
check "#852 a branch named by the caller is the label" "whole branch repo feat/sync (" "$out"
wait_final "$HEAD_SHA" || bad "#852 the named review finished"
reset_state
printf '{"number":7,"headRefOid":"%s","baseRefName":"main","headRefName":"feat/pr-head-name"}\n' "$HEAD_SHA" > "$FAKE_LOG/pr-view.json"
out="$(FAKE_CLAUDE_OUT='No issues found.' fire_gate "gh pr merge 7 --squash")"; rc=$?
check_eq "#852 the gate still refuses while the review it started runs" "2" "$rc"
check "#852 the gate labels the review with the pull request's own head branch" "feat/pr-head-name" "$out"
check_not "#852 never with the branch the merging checkout is on" "other/session-work" "$out"
wait_final "$HEAD_SHA" || bad "#852 the gate's review finished"
G checkout -q feat/sync
G branch -q -D other/session-work
# The checkout's own branch is still the right label when it IS the head being reviewed.
reset_state
CUR_SHA="$(G rev-parse HEAD)"
out="$(FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --base-ref origin/main)"
check "#852 the checkout's branch labels a review of its own head" "whole branch repo feat/sync (" "$out"
wait_final "$CUR_SHA" || bad "#852 the own head review finished"

# The base is fetched from origin, not read from a stale remote tracking ref.
reset_state
OTHER="$WORKDIR/other-clone"
git clone -q "$ORIGIN" "$OTHER" 2>/dev/null
OG(){ git -C "$OTHER" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
OG checkout -q main
for n in 1 2 3; do printf 'moved %s\n' "$n" >> "$OTHER/Moved.md"; OG add Moved.md; OG commit -q -m "main moved $n"; done
OG push -q origin main 2>/dev/null
NEW_MAIN="$(OG rev-parse HEAD)"
OG checkout -q -b feat/fresh
printf 'fresh\n' > "$OTHER/Fresh.md"; OG add Fresh.md; OG commit -q -m fresh
OG push -q origin feat/fresh 2>/dev/null
FRESH="$(OG rev-parse HEAD)"
STALE_MAIN="$(G rev-parse origin/main)"
[ "$STALE_MAIN" != "$NEW_MAIN" ] && ok || bad "#852 fixture: this checkout's origin/main is stale"
out="$(FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$FRESH" --base-ref origin/main)"
check "#852 the diff starts at the base branch's real tip on origin" "${NEW_MAIN:0:7}..${FRESH:0:7}" "$out"
wait_final "$FRESH" || bad "#852 the fresh review finished"
check_eq "#852 and the review records that tip as its base" "$NEW_MAIN" "$(meta "$(final_of "$FRESH")" base)"
check_not "#852 the review never reads Moved.md, which main already holds" "Moved.md" "$(cat "$FAKE_LOG/stdin" 2>/dev/null)"
# When origin cannot be reached the local copy is all there is: the review still runs, and says
# its base may be stale rather than presenting it as the real one (L93, L11).
reset_state
G update-ref refs/remotes/origin/main "$STALE_MAIN"
mv "$ORIGIN" "$ORIGIN.away"
out="$(FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$HEAD_SHA" --base-ref origin/main)"
mv "$ORIGIN.away" "$ORIGIN"
check "#852 an unreachable origin still starts the review" "started" "$out"
check "#852 and says the base came from this checkout's copy, which may be stale" "could not fetch origin/main" "$out"
wait_final "$HEAD_SHA" || bad "#852 the offline review finished: $out"

# ===========================================================================================
# 11. Files proven to need no reading are left out of a branch over the cap, and named
#     (claude-config#583). Slate PR #2794 was refused at 314 KB when 219 KB of it was one regenerated
#     test fixture, and on 2026-10-08 four claude-config branches had to be split, mostly for the
#     byte for byte copies of mod-kit's readers under payload/mods/*/tests/mod-kit. Left out only
#     when the whole diff is over the cap, only what is PROVEN to be data or a copy, and every file
#     left out is named with its size in the start line and in the verdict (L98).
# ===========================================================================================
reset_state
G checkout -q -b feat/data main
mkdir -p "$REPO/payload/mods/mod-kit/hooks" "$REPO/scripts/fixtures"
seq 1 600 | sed 's/^/reader line /' > "$REPO/payload/mods/mod-kit/hooks/reader.ts"
printf 'export const drift = 1\n' > "$REPO/payload/mods/mod-kit/hooks/drift.ts"
G add payload/mods/mod-kit/hooks/reader.ts payload/mods/mod-kit/hooks/drift.ts
printf 'gen.txt linguist-generated\n' > "$REPO/.gitattributes"; G add .gitattributes
G commit -q -m "data base"
DATA_BASE="$(G rev-parse HEAD)"
mkdir -p "$REPO/payload/mods/demo/tests/mod-kit/hooks" "$REPO/payload/mods/other/tests/mod-kit/hooks"
cp "$REPO/payload/mods/mod-kit/hooks/reader.ts" "$REPO/payload/mods/demo/tests/mod-kit/hooks/reader.ts"
printf 'export const drift = 2  // drifted copy\n' > "$REPO/payload/mods/other/tests/mod-kit/hooks/drift.ts"
seq 1 600 | sed 's/^/bigdata /' > "$REPO/scripts/fixtures/big.json"
printf 'smalldata 1\n' > "$REPO/scripts/fixtures/small.json"
printf 'echo fixture helper code\n' > "$REPO/scripts/fixtures/helper.sh"
seq 1 600 | sed 's/^/genwritten /' > "$REPO/gen.txt"
printf 'func codeChange() {}\n' > "$REPO/Code.swift"
# Enough smaller fixtures that naming every file left out would make the verdict as long as the list.
mkdir -p "$REPO/scripts/fixtures/many"
for n in 01 02 03 04 05 06 07 08 09 10 11 12; do seq 1 300 | sed "s/^/md$n /" > "$REPO/scripts/fixtures/many/f$n.json"; done
G add payload/mods/demo/tests/mod-kit/hooks/reader.ts payload/mods/other/tests/mod-kit/hooks/drift.ts \
  scripts/fixtures/big.json scripts/fixtures/small.json scripts/fixtures/helper.sh gen.txt Code.swift scripts/fixtures/many
G commit -q -m "data change"
DATA_SHA="$(G rev-parse HEAD)"
G checkout -q feat/sync
DCAP=6000

# Under the cap nothing changes: every file is in the diff, as before.
out="$(FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE")"
wait_final "$DATA_SHA" || bad "#583 the branch under the cap was reviewed: $out"
stdin="$(cat "$FAKE_LOG/stdin" 2>/dev/null)"
check "#583 under the cap a fixture is still read" "+bigdata 600" "$stdin"
check "#583 under the cap a copy is still read" "b/payload/mods/demo/tests/mod-kit/hooks/reader.ts" "$stdin"
check_not "#583 and nothing is said to be left out" "left out of this review" "$out"

# Over the cap, the code fits once the proven data and copies are left out.
reset_state
out="$(PR_REVIEW_MAX_BYTES=$DCAP FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE")"
start_out="$out"
check "#583 a branch over the cap only because of data and copies is reviewed" "started" "$out"
check_not "#583 and is not refused as too large" "too large" "$out"
wait_final "$DATA_SHA" || bad "#583 the branch with data left out was reviewed: $out"
stdin="$(cat "$FAKE_LOG/stdin" 2>/dev/null)"
check "#583 the code is read" "+func codeChange" "$stdin"
check "#583 code under a fixtures folder is read: only data is left out there" "+echo fixture helper code" "$stdin"
check "#583 a copy that DIFFERS from mod-kit's is read" "+export const drift = 2" "$stdin"
check "#583 a small fixture that fits beside the code is still read" "+smalldata 1" "$stdin"
check_not "#583 the large fixture is not in the diff" "+bigdata 1" "$stdin"
check_not "#583 the identical copy is not in the diff" "b/payload/mods/demo/tests/mod-kit/hooks/reader.ts" "$stdin"
check_not "#583 the generated file is not in the diff" "+genwritten 1" "$stdin"
check "#583 the reviewer's file list says which files were left out" $'scripts/fixtures/big.json\tleft out' "$stdin"
for f in scripts/fixtures/big.json payload/mods/demo/tests/mod-kit/hooks/reader.ts gen.txt; do
  check "#583 the start line names $f as left out" "$f" "$(printf '%s\n' "$out" | grep -i 'left out')"
done
check "#583 with the reason a copy needs no reading" "identical to payload/mods/mod-kit/hooks/reader.ts" "$out"
check "#583 and each one's size" "KB" "$(printf '%s\n' "$out" | grep -i 'left out')"
check_not "#583 the drifted copy is not called left out" "other/tests/mod-kit/hooks/drift.ts (" "$out"
check_not "#583 nor the helper code" "helper.sh (" "$out"
out="$(PR_REVIEW_MAX_BYTES=$DCAP prr check --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE")"; rc=$?
check_eq "#583 the clean review of the rest allows the merge" "0" "$rc"
check "#583 and the verdict names every file left out, so none is silently unreviewed" "scripts/fixtures/big.json" "$out"
check "#583 the copy too" "payload/mods/demo/tests/mod-kit/hooks/reader.ts" "$out"
check "#583 and the generated file" "gen.txt" "$out"
# Named largest first and capped, with a count and where the whole list is, so a branch with hundreds
# of fixtures cannot push the verdict past the hook output cap and cut it silently (lessons review of
# #1003, L351).
note="$(printf '%s\n' "$out" | grep 'Not read by this review')"
check "#583 the verdict says how many more were left out and where they are all listed" "more, all listed in $(final_of "$DATA_SHA").leftout" "$note"
named="$(printf '%s\n' "$note" | grep -o 'many/f[0-9]*\.json' | sort -u | wc -l | tr -d '[:space:]')"
[ "$named" -lt 12 ] && ok || bad "#583 the verdict does not name every one of the 12 small fixtures ($named named)"
check "#583 the largest are the ones named" "payload/mods/demo/tests/mod-kit/hooks/reader.ts" "$note"
[ "${#note}" -lt 2500 ] && ok || bad "#583 the left out note stays short (${#note} chars)"
check "#583 the start line is capped the same way" "more, all listed in" "$start_out"
# The nudge shows a finished review too, so it names what that review did not read (#1003).
nout="$(printf '{"session_id":"lo1","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "#583 the nudge's report of the review names the files it left out" "scripts/fixtures/big.json" "$nout"
# And counts that note against its own output budget, so three long reviews cannot push it past the
# 10,000 character hook cap (lessons review of #1003, L351).
reset_state
mkdir -p "$AI_REVIEW_STATE_DIR"
long="$(printf 'x%.0s' $(seq 1 110))"
for n in 1 2 3; do
  lf="$(final_of "fake$n")"
  {
    printf 'repo=repo\nbranch=b%s\nsha=fake%s\nstarted=1\nfinished=2\nstatus=ok\nkind=pr\nfindings=15\n\n' "$n" "$n"
    for l in $(seq 1 15); do printf 'App/F%s.swift:%s: %s (L1). Should be: y.\n' "$n" "$l" "$long"; done
  } > "$lf"
  for l in $(seq 1 12); do printf '%s\tscripts/fixtures/%s/%s%s.json\tfixture\tfixture data\n' "$((5000 - l))" "$long" "$long" "$l"; done > "$lf.leftout"
done
nout="$(printf '{"session_id":"lo2","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"hi"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
[ "${#nout}" -lt 10000 ] && ok || bad "#583 the nudge stays under the hook cap with left out notes counted (${#nout} chars)"
check "#583 holding back what does not fit, and saying so" "not shown" "$nout"
# And keeps that promise: the next prompt takes the full path and shows what was held, rather than
# the fast path, which would hide it until something else wrote to the state folder (review of #601).
nout2="$(printf '{"session_id":"lo2","cwd":"%s","hook_event_name":"UserPromptSubmit","prompt":"again"}' "$REPO" | bash "$NUDGE" 2>/dev/null)"
check "#583 a review held back is shown on the next prompt" "Lessons review of the whole branch" "$nout2"
# A review with findings names them as well, in the refusal that carries the findings.
reset_state
PR_REVIEW_MAX_BYTES=$DCAP prr start --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE" >/dev/null
wait_final "$DATA_SHA" || bad "#583 the review with findings finished"
out="$(PR_REVIEW_MAX_BYTES=$DCAP prr check --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE")"; rc=$?
check_eq "#583 findings on the rest still refuse" "1" "$rc"
check "#583 and that refusal names what was left out" "scripts/fixtures/big.json" "$out"
# When the code itself is over the cap, it is still refused as too large.
reset_state
out="$(PR_REVIEW_MAX_BYTES=300 prr start --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE")"
out="$(PR_REVIEW_MAX_BYTES=300 prr check --dir "$REPO" --sha "$DATA_SHA" --base-ref "$DATA_BASE")"; rc=$?
check_eq "#583 code over the cap with the data left out is still refused" "1" "$rc"
check "#583 as too large" "too large" "$out"
check "#583 saying how large the rest still was" "proven to need no reading still leaves" "$out"
check "#583 and naming, uncut, what it would have left out" "scripts/fixtures/big.json (fixture data" "$(printf '%s\n' "$out" | grep 'Would have been left out')"
check_not "#583 never saying a review left them out, since none ran" "Not read by this review" "$out"
check_eq "#583 and no reviewer ran" "0" "$(calls)"
# The proof is the content: a copy is identical only to the file at the same path in mod-kit.
cand="$(cd "$REPO" && bash -c ". '$DIR/lib/ai-review-common.sh'; ar_left_out_candidates '$DATA_BASE' '$DATA_SHA'")"
check "#583 the identical copy is a candidate" "payload/mods/demo/tests/mod-kit/hooks/reader.ts" "$cand"
check_not "#583 the drifted copy is not" "drift.ts" "$cand"
check_not "#583 code under fixtures is not" "helper.sh" "$cand"
check_not "#583 hand written code is not" "Code.swift" "$cand"
# A generated mark counts only when the base already had it, so a branch cannot excuse its own file
# by marking it in the same branch. The file marked at both ends in the same fixture is the control
# that the rule fires at all (L159).
MREPO="$WORKDIR/marked"; git init -q "$MREPO"
MG(){ git -C "$MREPO" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
printf 'old.gen linguist-generated\n' > "$MREPO/.gitattributes"; printf 'a\n' > "$MREPO/old.gen"; printf 'a\n' > "$MREPO/new.gen"
MG add .gitattributes old.gen new.gen; MG commit -q -m base; MB="$(MG rev-parse HEAD)"
printf 'old.gen linguist-generated\nnew.gen linguist-generated\n' > "$MREPO/.gitattributes"
printf 'b\n' > "$MREPO/old.gen"; printf 'b\n' > "$MREPO/new.gen"
MG commit -q -am change; MH="$(MG rev-parse HEAD)"
mcand="$(cd "$MREPO" && bash -c ". '$DIR/lib/ai-review-common.sh'; ar_left_out_candidates '$MB' '$MH'")"
check "#583 a file the base already marked generated is a candidate" "old.gen" "$mcand"
check_not "#583 a file marked generated only by this branch is not" "new.gen" "$mcand"

# ===========================================================================================
# 12. A branch still over the cap is reviewed in groups of files, each fitting, rather than refused
#     (claude-config#601). Slate #3049 (456 KB across about 86 files) could only merge by Dan
#     clicking merge on GitHub. Every group is read by the same runner with the same deadline, the
#     branch counts as reviewed only when every group returned, and any group that did not blocks.
# ===========================================================================================
reset_state
G checkout -q -b feat/groups main
for n in 1 2 3 4; do seq 1 120 | sed "s/^/func g${n}_/; s/\$/() {}/" > "$REPO/G$n.swift"; done
G add G1.swift G2.swift G3.swift G4.swift
G commit -q -m "four files"
GRP_SHA="$(G rev-parse HEAD)"
GRP_BASE="$(G rev-parse main)"
G checkout -q feat/sync
GCAP=6000
GF1='G1.swift:3: the first group finding (L1). Should be: x. [severity: minor]'
GF2='G4.swift:5: the second group finding (L2). Should be: y. [severity: minor]'
grp_parts(){ printf '%s/parts/%s-pr-%s' "$AI_REVIEW_STATE_DIR" "$KEY" "$1"; }
out="$(PR_REVIEW_MAX_BYTES=$GCAP FAKE_GROUP_1_OUT="$GF1" FAKE_GROUP_2_OUT="$GF2" prr start --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"
check "#601 a branch over the cap that splits is reviewed, not refused" "started" "$out"
check "#601 in groups of files, said with how many" "in 2 groups" "$out"
check_not "#601 and is not called too large" "too large" "$out"
wait_final "$GRP_SHA" || bad "#601 the grouped review finished: $out"
F="$(final_of "$GRP_SHA")"
check_eq "#601 one reviewer per group, the same runner each time" "2" "$(calls)"
check_eq "#601 every group returned, so the branch review is ok" "ok" "$(meta "$F" status)"
check_eq "#601 its findings are every group's together" "2" "$(meta "$F" findings)"
check_eq "#601 it records how many groups read it" "2" "$(meta "$F" groups)"
g1="$(cat "$FAKE_LOG/stdin.g1" 2>/dev/null)"; g2="$(cat "$FAKE_LOG/stdin.g2" 2>/dev/null)"
check "#601 group 1 reads its own files" "+func g1_1() {}" "$g1"
check_not "#601 and not another group's" "+func g3_1() {}" "$g1"
check "#601 group 2 reads its own files" "+func g4_1() {}" "$g2"
check_not "#601 and not another group's" "+func g1_1() {}" "$g2"
check "#601 every group is given the complete file list, saying where the rest are read" $'G3.swift\t(changed, reviewed in another group' "$g1"
check "#601 and is told it is one group of the branch" "THIS REVIEW IS GROUP 2 OF 2" "$g2"
check_not "#601 a group never carries another group's full text" "FULL FILE at ${GRP_SHA:0:7}: G3.swift" "$g1"
for g in 1 2; do
  [ "$(wc -c < "$FAKE_LOG/stdin.g$g")" -le "$GCAP" ] && ok || bad "#601 group $g fits under the cap ($(wc -c < "$FAKE_LOG/stdin.g$g") bytes)"
done
[ ! -e "$(grp_parts "$GRP_SHA")" ] && ok || bad "#601 the groups' own files are removed once the branch's review is written"
check_eq "#601 the outcome ledger counts the branch once, not once per group" "1" "$(grep -c "$GRP_SHA" "$AI_REVIEW_STATE_DIR/pr-reviews.tsv" 2>/dev/null)"
check "#601 the lessons each group cited reach the citation ledger" "L2" "$(cat "$AI_REVIEW_STATE_DIR/citations.tsv" 2>/dev/null)"
out="$(PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 findings from the groups refuse until read" "1" "$rc"
check "#601 the refusal carries group 1's finding" "the first group finding" "$out"
check "#601 and group 2's" "the second group finding" "$out"
check "#601 each under its own group" "Group 2 of 2" "$out"
gk="$(key_in "$out")"
[ -n "$gk" ] && ok || bad "#601 one read key covers every group's findings: $out"
out="$(PR_REVIEW_READ="$gk" PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 and that one key allows the merge" "0" "$rc"

# While the groups run, the check says how many have returned.
reset_state
out="$(PR_REVIEW_MAX_BYTES=$GCAP FAKE_GROUP_2_SLEEP=4 FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"
out="$(PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 a grouped review still running refuses as still to come" "3" "$rc"
check "#601 and says how many of its groups have returned" "of 2 groups" "$out"
wait_final "$GRP_SHA" || bad "#601 the slow grouped review finished"
check_eq "#601 two clean groups make a clean branch" "0" "$(meta "$(final_of "$GRP_SHA")" findings)"

# A group that does not finish inside the deadline blocks the branch, as one review that did not would.
reset_state
PR_REVIEW_DEADLINE_SECONDS=2 PR_REVIEW_MAX_BYTES=$GCAP FAKE_GROUP_1_OUT="$GF1" FAKE_GROUP_2_SLEEP=8 prr start --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE" >/dev/null
wait_final "$GRP_SHA" || bad "#601 the review with a slow group finished"
check_eq "#601 a group past its deadline makes the branch's review a timeout" "timeout" "$(meta "$(final_of "$GRP_SHA")" status)"
out="$(PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 which refuses the merge" "1" "$rc"
check "#601 naming the group that did not finish" "Group 2 of 2" "$out"

# A group that answers in some other shape blocks too.
reset_state
PR_REVIEW_MAX_BYTES=$GCAP FAKE_GROUP_1_OUT='I could not review this.' FAKE_GROUP_2_OUT="$GF2" prr start --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE" >/dev/null
wait_final "$GRP_SHA" || bad "#601 the review with an unparsed group finished"
check_eq "#601 an unparsed group makes the branch's review unparsed" "unparsed" "$(meta "$(final_of "$GRP_SHA")" status)"
out="$(PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 and refuses the merge" "1" "$rc"
check "#601 naming that group" "Group 1 of 2" "$out"

# A file whose own diff is over what a group can hold cannot be split, so it is still too large.
reset_state
out="$(PR_REVIEW_MAX_BYTES=2000 prr start --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"
check "#601 a file too large for any group is still refused as too large" "too large" "$out"
check "#601 naming the file" "G1.swift" "$(meta "$(final_of "$GRP_SHA")" status; cat "$(final_of "$GRP_SHA")")"
check_eq "#601 and no reviewer ran" "0" "$(calls)"
# And a branch needing more groups than may run at once.
reset_state
out="$(PR_REVIEW_MAX_BYTES=$GCAP PR_REVIEW_MAX_GROUPS=1 prr start --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"
check "#601 a branch needing more groups than PR_REVIEW_MAX_GROUPS is still too large" "too large" "$out"
check "#601 saying how many groups it would need" "2 groups" "$(cat "$(final_of "$GRP_SHA")")"

# The check writes the branch's review itself when every group finished but the process that waits
# on them died before it could, and calls it abandoned when a group never finished.
reset_state
GP="$(grp_parts "$GRP_SHA")"; mkdir -p "$GP"
now="$(date +%s)"
printf 'repo=repo\nbranch=feat/groups\nsha=%s\nstarted=%s\nmodel=sonnet\ndeadline=600\nkind=pr\nbase=%s\ndir=%s\ngroups=2\n' "$GRP_SHA" "$now" "$GRP_BASE" "$REPO" > "$(final_of "$GRP_SHA").pending"
for g in 1 2; do
  printf 'repo=repo\nbranch=feat/groups\nsha=%s\nstarted=%s\nfinished=%s\nstatus=ok\nmodel=sonnet\ndeadline=600\nkind=pr\nbase=%s\nfindings=0\n\nNo issues found.\n' "$GRP_SHA" "$now" "$now" "$GRP_BASE" > "$GP/$KEY-pr-$GRP_SHA-g$g.txt"
done
out="$(PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 every group finished: the check writes the branch's review and allows" "0" "$rc"
check_eq "#601 as ok" "ok" "$(meta "$(final_of "$GRP_SHA")" status)"
reset_state
GP="$(grp_parts "$GRP_SHA")"; mkdir -p "$GP"
printf 'repo=repo\nbranch=feat/groups\nsha=%s\nstarted=1\nmodel=sonnet\ndeadline=1\nkind=pr\nbase=%s\ndir=%s\ngroups=2\n' "$GRP_SHA" "$GRP_BASE" "$REPO" > "$(final_of "$GRP_SHA").pending"
printf 'repo=repo\nsha=%s\nstarted=1\nfinished=2\nstatus=ok\nkind=pr\nfindings=0\n\nNo issues found.\n' "$GRP_SHA" > "$GP/$KEY-pr-$GRP_SHA-g1.txt"
out="$(PR_REVIEW_MAX_BYTES=$GCAP prr check --dir "$REPO" --sha "$GRP_SHA" --base-ref "$GRP_BASE")"; rc=$?
check_eq "#601 a group that never finished leaves the branch unreviewed" "1" "$rc"
check "#601 as abandoned" "never finished" "$out"
check "#601 naming the group" "group 2" "$(cat "$(final_of "$GRP_SHA")")"
[ ! -e "$GP" ] && ok || bad "#601 an abandoned grouped review's files are removed"
# Groups nothing ever wrote up (the waiting process died, no check came) are swept after 14 days.
reset_state
mkdir -p "$AI_REVIEW_STATE_DIR/parts/old-pr-dead"; touch -t 202601010000 "$AI_REVIEW_STATE_DIR/parts/old-pr-dead"
mkdir -p "$AI_REVIEW_STATE_DIR/parts/new-pr-live"
FAKE_CLAUDE_OUT='No issues found.' prr start --dir "$REPO" --sha "$HEAD_SHA" >/dev/null
wait_final "$HEAD_SHA" || bad "#601 the review beside the sweep finished"
[ ! -e "$AI_REVIEW_STATE_DIR/parts/old-pr-dead" ] && ok || bad "#601 a stale group folder is swept"
[ -e "$AI_REVIEW_STATE_DIR/parts/new-pr-live" ] && ok || bad "#601 and a recent one is left alone"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
